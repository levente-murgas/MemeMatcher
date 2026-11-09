import Foundation
import AVFoundation
import MediaPipeTasksVision
import os.log

/// One blendshape coefficient: a named facial movement and how strongly it's
/// active right now (0 = not at all, 1 = fully). E.g. `mouthSmileLeft: 0.85`.
struct Blendshape: Identifiable {
    let name: String
    let score: Float
    var id: String { name }
}

/// M2: turns camera frames into a 52-value expression vector using MediaPipe
/// Face Landmarker. This is "Route 2" from the plan — the same extractor will
/// later run over the meme library (via the Python build script), which is
/// what makes the user's face and the memes comparable.
///
/// Runs in `.liveStream` mode: we push frames in with `detectAsync`, and
/// MediaPipe calls the delegate back asynchronously with results. Frames are
/// dropped automatically if the model can't keep up — fine for live UI.
final class ExpressionExtractor: NSObject, ObservableObject {

    /// All 52 coefficients of the latest frame, sorted by score, descending.
    /// Empty when no face is in view (or the model isn't running).
    @Published private(set) var blendshapes: [Blendshape] = []

    /// Non-nil if the model failed to load — shown in the UI instead of
    /// failing silently.
    @Published private(set) var setupError: String?

    private var landmarker: FaceLandmarker?

    // Diagnostics: counts logged periodically so the console shows which
    // stage of the pipeline frames die at (if any).
    private static let log = Logger(subsystem: "com.leventemurgas.MemeMatcher", category: "expression")
    private var framesIn = 0
    private var framesSent = 0
    private var callbacks = 0

    /// Load the bundled model and configure live-stream detection.
    /// Call once, before feeding frames.
    func setUp() {
        // Idempotent: the extractor is shared and outlives the screen, so
        // re-entering must not rebuild the model and its GL context.
        guard landmarker == nil else { return }
        guard let modelPath = Bundle.main.path(forResource: "face_landmarker", ofType: "task") else {
            setupError = "face_landmarker.task missing from app bundle"
            Self.log.error("EXPR setup: model missing from bundle")
            return
        }
        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numFaces = 1
        options.outputFaceBlendshapes = true   // the whole point
        options.faceLandmarkerLiveStreamDelegate = self
        do {
            landmarker = try FaceLandmarker(options: options)
            Self.log.error("EXPR setup: FaceLandmarker created OK")
        } catch {
            setupError = "Model failed to load: \(error.localizedDescription)"
            Self.log.error("EXPR setup FAILED: \(error.localizedDescription)")
        }
    }

    /// Feed one camera frame. Safe to call at full camera rate.
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let landmarker else { return }
        framesIn += 1
        let image: MPImage
        do {
            image = try MPImage(sampleBuffer: sampleBuffer)
        } catch {
            if framesIn % 60 == 1 { Self.log.error("EXPR MPImage init failed: \(error.localizedDescription)") }
            return
        }
        // MediaPipe requires strictly increasing timestamps; the camera's
        // presentation timestamps are exactly that.
        let ms = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
        do {
            try landmarker.detectAsync(image: image, timestampInMilliseconds: ms)
            framesSent += 1
        } catch {
            if framesIn % 60 == 1 { Self.log.error("EXPR detectAsync failed: \(error.localizedDescription)") }
        }
        if framesIn % 60 == 1 {
            Self.log.error("EXPR pipeline: in=\(self.framesIn) sent=\(self.framesSent) callbacks=\(self.callbacks)")
        }
    }
}

// MARK: - MediaPipe result callback (arrives on a background thread)

extension ExpressionExtractor: FaceLandmarkerLiveStreamDelegate {
    func faceLandmarker(_ faceLandmarker: FaceLandmarker,
                        didFinishDetection result: FaceLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        callbacks += 1
        if let error, callbacks % 60 == 1 {
            Self.log.error("EXPR callback error: \(error.localizedDescription)")
        }
        if callbacks % 60 == 1 {
            let n = result?.faceBlendshapes.first?.categories.count ?? 0
            Self.log.error("EXPR callback: blendshapeCount=\(n)")
        }
        let shapes = (result?.faceBlendshapes.first?.categories ?? [])
            .map { Blendshape(name: $0.categoryName ?? "?", score: $0.score) }
            .sorted { $0.score > $1.score }
        DispatchQueue.main.async { self.blendshapes = shapes }
    }
}
