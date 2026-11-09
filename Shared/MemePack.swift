import Foundation

/// The bundled meme library: images + pre-computed feature vectors, produced
/// at build time by `tools/build_manifest.py` (which runs the same MediaPipe
/// model the app uses live — that's what makes the vectors comparable).
///
/// Features are stored per meme as a *dictionary of named channels* rather
/// than a single vector, so new extractors (e.g. a future hand-gesture
/// channel) extend the pack without schema changes: each channel is matched
/// independently and the scores are combined.
public struct MemePack: Codable {

    public struct FeatureSchema: Codable {
        /// Component names in model order (e.g. the 52 blendshape names).
        public let names: [String]
    }

    public struct Meme: Codable {
        public let file: String
        /// channel id → vector. Empty when no extractor produced anything
        /// (e.g. no detectable face) — such memes are skipped by matching.
        public let features: [String: [Float]]
    }

    public let version: Int
    public let featureSchemas: [String: FeatureSchema]
    public let memes: [Meme]
}

/// Known feature channel identifiers (shared vocabulary between the Python
/// build script and the Swift code — keep in sync with build_manifest.py).
public enum FeatureChannel {
    public static let faceBlendshapes = "faceBlendshapes"
    /// 126 floats: two 63-float hand shape descriptors in fixed L/R slots.
    public static let handLandmarks = "handLandmarks"
    /// 16 floats: canned gesture scores in the same L/R slots. Display only.
    public static let handGesture = "handGesture"
}

public enum VectorMath {
    /// Cosine similarity in [-1, 1]; 0 when either vector is all zeros.
    /// The starting point for meme matching — simple, scale-invariant.
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices {
            dot += a[i] * b[i]
            na += a[i] * a[i]
            nb += b[i] * b[i]
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    /// Cosine similarity clamped to [0, 1]. Used for *bonus* channels, where a
    /// negative similarity must never subtract from a meme's primary score.
    public static func positiveSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        max(0, cosineSimilarity(a, b))
    }
}
