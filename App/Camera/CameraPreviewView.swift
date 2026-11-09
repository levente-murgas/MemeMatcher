import SwiftUI
import AVFoundation

/// The live camera feed.
///
/// SwiftUI has no built-in camera view, so this wraps a UIKit view, which is
/// what `UIViewRepresentable` is for (a bridge, like calling a C extension
/// from Python). The UIKit view uses `AVCaptureVideoPreviewLayer`, which
/// renders the session's video directly.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {}

    /// UIKit view whose backing layer *is* the video preview layer.
    final class PreviewView: UIView {
        // Tells UIKit which CALayer subclass backs this view.
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
