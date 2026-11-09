import AVFoundation
import CoreGraphics
import os.log

/// Drives the front camera and hands frames to the MediaPipe extractors.
///
/// Getting the *lifecycle* right matters more than the setup here: iOS
/// interrupts the capture session whenever the app leaves the foreground, and
/// a session that fails to restart renders as a plain black preview with no
/// error anywhere. So this class verifies that the session actually started,
/// retries, and rebuilds it from scratch after a runtime error.
final class CameraManager: NSObject, ObservableObject {

    enum Status: Equatable {
        case idle          // not started yet, or starting
        case unauthorized  // user denied camera permission
        case unavailable   // no front camera (e.g. the Simulator)
        case running       // live, frames flowing
        case failed        // couldn't start; the UI offers a retry
    }

    @Published private(set) var status: Status = .idle

    /// The capture session. `CameraPreviewView` renders its video feed.
    let session = AVCaptureSession()

    /// Tap on the raw frame stream (called on the frame queue). The MediaPipe
    /// expression and gesture extractors both hang off this.
    var onFrame: ((CMSampleBuffer) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    // Serial queues: one for session start/stop, one for per-frame delivery.
    private let sessionQueue = DispatchQueue(label: "com.leventemurgas.MemeMatcher.session")
    private let frameQueue = DispatchQueue(label: "com.leventemurgas.MemeMatcher.frames")

    private var isConfigured = false
    private var startAttempts = 0
    private static let maxStartAttempts = 3

    private static let log = Logger(subsystem: "com.leventemurgas.MemeMatcher", category: "camera")

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Lifecycle

    /// Ask for camera permission if needed, then configure and start.
    /// Safe to call repeatedly (e.g. every time the app becomes active).
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startAttempts = 0
            configureAndStart()
        case .notDetermined:
            // First launch: iOS shows the permission alert (with our
            // NSCameraUsageDescription text) and calls back with the answer.
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                granted ? self.configureAndStart() : self.setStatus(.unauthorized)
            }
        default:
            setStatus(.unauthorized)
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            Self.log.error("CAM stopped")
        }
    }

    // MARK: - Session configuration

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if !self.isConfigured {
                guard self.configureSession() else { return }
                self.isConfigured = true
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }

            // Verify rather than assume. `startRunning()` returns void and can
            // silently fail (e.g. FigCaptureSourceRemote err=-17281 when the
            // app isn't foreground yet), which previously left the UI showing
            // a black preview while reporting "running".
            if self.session.isRunning {
                self.startAttempts = 0
                self.setStatus(.running)
                Self.log.error("CAM running")
            } else {
                self.startAttempts += 1
                Self.log.error("CAM startRunning failed (attempt \(self.startAttempts))")
                if self.startAttempts < Self.maxStartAttempts {
                    // Usually a transient foreground-transition race; a short
                    // retry clears it.
                    self.sessionQueue.asyncAfter(deadline: .now() + 0.4) {
                        self.configureAndStart()
                    }
                } else {
                    self.setStatus(.failed)
                }
            }
        }
    }

    /// Returns false (and sets a status) if the camera can't be set up at all.
    private func configureSession() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                 for: .video,
                                                 position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else {
            // Most common cause: running on the Simulator, which has no camera.
            setStatus(.unavailable)
            Self.log.error("CAM no front camera available")
            return false
        }
        session.addInput(input)

        // Deliver frames as BGRA: the camera's default is YUV, which MediaPipe
        // rejects ("Unsupported pixel format... Expected kCVPixelFormatType_32BGRA").
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        // Drop late frames instead of queueing up.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else {
            setStatus(.unavailable)
            Self.log.error("CAM could not add video output")
            return false
        }
        session.addOutput(videoOutput)

        // Rotate buffers to upright portrait so MediaPipe sees them the same
        // way the build-time script saw the meme images.
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        return true
    }

    /// Throw away the session's inputs/outputs so the next start rebuilds it.
    /// Needed after a runtime error, where the capture device connection is
    /// dead and simply calling `startRunning()` again does nothing.
    private func rebuild() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Self.log.error("CAM rebuilding session")
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            self.session.commitConfiguration()
            self.isConfigured = false
            self.startAttempts = 0
            self.configureAndStart()
        }
    }

    private func setStatus(_ newValue: Status) {
        DispatchQueue.main.async { self.status = newValue }
    }

    // MARK: - Interruption handling

    private func observeSessionNotifications() {
        let centre = NotificationCenter.default
        centre.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                           name: .AVCaptureSessionRuntimeError, object: session)
        centre.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                           name: .AVCaptureSessionWasInterrupted, object: session)
        centre.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                           name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    @objc private func sessionRuntimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        Self.log.error("CAM runtime error: \(error?.localizedDescription ?? "unknown") code=\(error?.code ?? 0)")
        rebuild()
    }

    @objc private func sessionWasInterrupted(_ notification: Notification) {
        let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
        Self.log.error("CAM interrupted, reason=\(reason ?? -1)")
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        Self.log.error("CAM interruption ended, restarting")
        startAttempts = 0
        configureAndStart()
    }
}

// MARK: - Frame delivery

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        onFrame?(sampleBuffer)
    }
}
