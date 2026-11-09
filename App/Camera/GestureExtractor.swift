import Foundation
import AVFoundation
import MediaPipeTasksVision
import os.log

/// M3.5: turns camera frames into a hand-shape vector using MediaPipe's
/// Gesture Recognizer — the second feature channel alongside face blendshapes.
///
/// Mirrors `ExpressionExtractor` in structure: live-stream mode, frames pushed
/// in with `recognizeAsync`, results delivered asynchronously to the delegate.
///
/// The normalization below MUST stay byte-for-byte equivalent to
/// `normalize_hand()` / `detect_hands()` in `tools/build_manifest.py`, since
/// the meme vectors are produced there and compared against these. Verified by
/// the cross-implementation check in the milestone plan.
final class GestureExtractor: NSObject, ObservableObject {

    /// The hand shape descriptor as 126 *named* components (`L_WRIST_x` …
    /// `R_PINKY_TIP_z`), so `MatchEngine` aligns it by name exactly like face
    /// blendshapes. Empty means no hand at all, which suppresses the bonus.
    @Published private(set) var handComponents: [Blendshape] = []

    /// Top canned gesture per detected hand, for the on-screen readout.
    @Published private(set) var gestures: [Blendshape] = []

    /// How many hands are currently detected (0, 1 or 2) — also the quickest
    /// signal when diagnosing handedness/slot problems.
    @Published private(set) var handCount: Int = 0

    @Published private(set) var setupError: String?

    private var recognizer: GestureRecognizer?

    // Must match tools/build_manifest.py exactly.
    private static let slotNames = ["L", "R"]      // index 0 = Left, 1 = Right
    private static let slotCount = slotNames.count
    private static let landmarkNames = [
        "WRIST",
        "THUMB_CMC", "THUMB_MCP", "THUMB_IP", "THUMB_TIP",
        "INDEX_MCP", "INDEX_PIP", "INDEX_DIP", "INDEX_TIP",
        "MIDDLE_MCP", "MIDDLE_PIP", "MIDDLE_DIP", "MIDDLE_TIP",
        "RING_MCP", "RING_PIP", "RING_DIP", "RING_TIP",
        "PINKY_MCP", "PINKY_PIP", "PINKY_DIP", "PINKY_TIP",
    ]
    private static let landmarksPerHand = landmarkNames.count * 3   // 63

    /// `L_WRIST_x` … `R_PINKY_TIP_z`, in the same order the manifest uses.
    private static let componentNames: [String] = slotNames.flatMap { slot in
        landmarkNames.flatMap { name in
            ["x", "y", "z"].map { axis in "\(slot)_\(name)_\(axis)" }
        }
    }

    private static let log = Logger(subsystem: "com.leventemurgas.MemeMatcher", category: "gesture")
    private var framesIn = 0
    private var framesSent = 0
    private var callbacks = 0

    /// Load the bundled model and configure live-stream recognition.
    func setUp() {
        // Idempotent: shared and long-lived, so don't rebuild the graph.
        guard recognizer == nil else { return }
        guard let modelPath = Bundle.main.path(forResource: "gesture_recognizer", ofType: "task") else {
            setupError = "gesture_recognizer.task missing from app bundle"
            Self.log.error("GEST setup: model missing from bundle")
            return
        }
        let options = GestureRecognizerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .liveStream
        options.numHands = Self.slotCount
        options.gestureRecognizerLiveStreamDelegate = self
        do {
            recognizer = try GestureRecognizer(options: options)
            Self.log.error("GEST setup: GestureRecognizer created OK")
        } catch {
            setupError = "Gesture model failed to load: \(error.localizedDescription)"
            Self.log.error("GEST setup FAILED: \(error.localizedDescription)")
        }
    }

    /// Feed one camera frame. Safe to call at full camera rate.
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard let recognizer else { return }
        framesIn += 1
        let image: MPImage
        do {
            image = try MPImage(sampleBuffer: sampleBuffer)
        } catch {
            if framesIn % 60 == 1 { Self.log.error("GEST MPImage init failed: \(error.localizedDescription)") }
            return
        }
        let ms = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
        do {
            try recognizer.recognizeAsync(image: image, timestampInMilliseconds: ms)
            framesSent += 1
        } catch {
            if framesIn % 60 == 1 { Self.log.error("GEST recognizeAsync failed: \(error.localizedDescription)") }
        }
        if framesIn % 60 == 1 {
            Self.log.error("GEST pipeline: in=\(self.framesIn) sent=\(self.framesSent) callbacks=\(self.callbacks)")
        }
    }

    // MARK: - Normalization (keep in sync with build_manifest.py)

    /// One hand's 21 world landmarks → 63 floats: centered, unit-norm, flat.
    private static func normalize(_ landmarks: [Landmark]) -> [Float] {
        guard !landmarks.isEmpty else { return [Float](repeating: 0, count: landmarksPerHand) }
        let n = Float(landmarks.count)
        let cx = landmarks.reduce(0) { $0 + $1.x } / n
        let cy = landmarks.reduce(0) { $0 + $1.y } / n
        let cz = landmarks.reduce(0) { $0 + $1.z } / n

        var centered: [Float] = []
        centered.reserveCapacity(landmarksPerHand)
        for landmark in landmarks {
            centered.append(landmark.x - cx)
            centered.append(landmark.y - cy)
            centered.append(landmark.z - cz)
        }
        let norm = centered.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0 else { return [Float](repeating: 0, count: landmarksPerHand) }
        return centered.map { $0 / norm }
    }
}

// MARK: - MediaPipe result callback (arrives on a background thread)

extension GestureExtractor: GestureRecognizerLiveStreamDelegate {
    func gestureRecognizer(_ gestureRecognizer: GestureRecognizer,
                           didFinishGestureRecognition result: GestureRecognizerResult?,
                           timestampInMilliseconds: Int,
                           error: Error?) {
        callbacks += 1
        if let error, callbacks % 60 == 1 {
            Self.log.error("GEST callback error: \(error.localizedDescription)")
        }

        let worldLandmarks = result?.worldLandmarks ?? []
        guard !worldLandmarks.isEmpty else {
            if callbacks % 60 == 1 { Self.log.error("GEST callback: no hands") }
            DispatchQueue.main.async {
                self.handComponents = []
                self.gestures = []
                self.handCount = 0
            }
            return
        }

        var vector = [Float](repeating: 0, count: Self.landmarksPerHand * Self.slotCount)
        var readout: [Blendshape] = []

        // Assign each hand to its handedness slot, most confident first, so a
        // duplicate handedness can't silently drop a hand (matches Python).
        let ordered = worldLandmarks.indices
            .map { index -> (index: Int, score: Float, preferred: Int) in
                let handedness = result?.handedness[safe: index]?.first
                let isLeft = handedness?.categoryName == "Left"
                return (index, handedness?.score ?? 0, isLeft ? 0 : 1)
            }
            .sorted { $0.score > $1.score }

        var usedSlots = Set<Int>()
        for hand in ordered {
            let slot = usedSlots.contains(hand.preferred) ? 1 - hand.preferred : hand.preferred
            guard !usedSlots.contains(slot) else { continue }
            usedSlots.insert(slot)

            let normalized = Self.normalize(worldLandmarks[hand.index])
            let offset = slot * Self.landmarksPerHand
            vector.replaceSubrange(offset..<(offset + Self.landmarksPerHand), with: normalized)

            let slotName = slot == 0 ? "L" : "R"
            if let top = result?.gestures[safe: hand.index]?.first {
                readout.append(Blendshape(name: "\(slotName)_\(top.categoryName ?? "?")", score: top.score))
            }
        }

        if callbacks % 60 == 1 {
            Self.log.error("GEST callback: hands=\(worldLandmarks.count) slots=\(usedSlots.sorted().map(String.init).joined(separator: ","))")
        }

        let named = zip(Self.componentNames, vector).map { Blendshape(name: $0, score: $1) }
        DispatchQueue.main.async {
            self.handComponents = named
            self.gestures = readout
            self.handCount = worldLandmarks.count
        }
    }
}

private extension Array {
    /// Bounds-checked access — MediaPipe's parallel result arrays are not
    /// guaranteed to be the same length as the landmark array.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
