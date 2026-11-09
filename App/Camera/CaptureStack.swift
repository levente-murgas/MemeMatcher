import Foundation

/// The app's single, long-lived capture stack.
///
/// `CameraScreen` used to create these itself, which meant a **new**
/// `AVCaptureSession` every time the screen appeared. Re-entering the screen
/// then raced the previous session's teardown: the new session grabbed the
/// front camera before the old one had released it, came up with a dead
/// capture source (`FigCaptureSourceRemote err=-17281`) and delivered blank
/// frames — a black preview with `blendshapeCount=0` despite frames flowing.
///
/// Keeping one instance also avoids rebuilding both MediaPipe graphs (model
/// load, GL context, XNNPACK setup) on every visit, which is slow and was a
/// likely contributor to the earlier out-of-memory termination.
@MainActor
final class CaptureStack {
    static let shared = CaptureStack()

    let camera = CameraManager()
    let expression = ExpressionExtractor()
    let gestures = GestureExtractor()
    let engine = MatchEngine()

    private init() {}
}
