import SwiftUI
import Shared

/// Camera screen: front-camera preview with a live face box (M1), the live
/// expression vector (M2), matched memes (M3) and the hand channel (M3.5).
struct CameraScreen: View {
    // Shared, app-lifetime instances. Creating these per-appearance spun up a
    // second AVCaptureSession that fought the old one for the camera (see
    // CaptureStack), and rebuilt both MediaPipe graphs every visit.
    @ObservedObject private var camera = CaptureStack.shared.camera
    @ObservedObject private var extractor = CaptureStack.shared.expression
    @ObservedObject private var gestures = CaptureStack.shared.gestures
    private let engine = CaptureStack.shared.engine
    @State private var matches: [MatchEngine.Match] = []
    /// iOS suspends the capture session when the app leaves the foreground and
    /// does NOT resume it on return — the preview layer then renders pure
    /// black. Watching the scene phase is what restarts it.
    @Environment(\.scenePhase) private var scenePhase
    /// Filename of the meme just copied, shown as confirmation.
    @State private var copied: String?
    @State private var clearCopiedTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            switch camera.status {
            case .running:
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 10) {
                            if !matches.isEmpty {
                                MatchStrip(matches: matches, onSelect: select)
                            }
                            if let copied {
                                CopiedBanner(file: copied)
                            } else {
                                Text(extractor.blendshapes.isEmpty
                                     ? "Looking for a face…"
                                     : (matches.isEmpty ? "Make an expression 🎭" : "Tap a meme to copy it"))
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }
                        }
                        .padding(.bottom, 24)
                    }

            case .idle:
                ProgressView("Starting camera…")

            case .unauthorized:
                explainer(icon: "video.slash",
                          title: "Camera access needed",
                          message: "MemeMatcher reads your expression on-device to suggest memes. Enable the camera in Settings → MemeMatcher.")

            case .unavailable:
                explainer(icon: "web.camera",
                          title: "No camera available",
                          message: "This device has no front camera. (The Simulator can't do this part, so run on a real iPhone.)")

            case .failed:
                VStack(spacing: 16) {
                    explainer(icon: "exclamationmark.triangle",
                              title: "Camera didn't start",
                              message: "Something else may be using the camera. Try again.")
                    Button("Try again") { camera.start() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            engine.load()
            extractor.setUp()
            gestures.setUp()
            // Route every camera frame into both MediaPipe graphs as well as
            // Vision. MPImage wraps the buffer without copying pixels, so the
            // second wrap per frame is cheap.
            camera.onFrame = { [weak extractor, weak gestures] buffer in
                extractor?.process(buffer)
                gestures?.process(buffer)
            }
            camera.start()
        }
        .onDisappear { camera.stop() }
        // Backgrounding suspends the session; restart it when we're active
        // again, otherwise the user comes back to a black preview.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:     camera.start()
            case .background: camera.stop()
            // .inactive fires transiently (system alerts, the app switcher);
            // stopping there would make the preview flicker.
            default:          break
            }
        }
        // Re-rank whenever a new expression vector arrives, reading the hand
        // channel's latest value at that moment (it's inherently a "latest
        // known" signal, so no Combine merging is needed). Uses the engine's
        // hysteresis-stabilized top-3 so the strip doesn't shuffle on minor
        // score jitter while a pose is held.
        .onReceive(extractor.$blendshapes) { shapes in
            matches = engine.stableTopMatches(
                named: [
                    FeatureChannel.faceBlendshapes: shapes,
                    FeatureChannel.handLandmarks: gestures.handComponents,
                ],
                count: 3
            )
        }
    }

    /// M4: the user picked a meme. Put it on the system pasteboard so it can be
    /// pasted into whatever app the keyboard was opened from, and record the
    /// choice in the App Group so the keyboard can confirm what's ready.
    ///
    /// The pasteboard is the only route for images: a keyboard extension can't
    /// insert an image via `textDocumentProxy` (text only), which is why every
    /// GIF/sticker keyboard on iOS works as "copy, then paste".
    private func select(_ match: MatchEngine.Match) {
        guard let image = MatchEngine.image(named: match.file) else { return }
        UIPasteboard.general.image = image
        // Hand the keyboard a small thumbnail — it can't read the app's bundle.
        AppGroup.writeSelection(file: match.file, thumbnailPNG: thumbnail(of: image))

        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = match.file

        // Keep the confirmation up long enough to read, then fall back to the
        // normal hint so the screen doesn't get stuck in a "done" state.
        clearCopiedTask?.cancel()
        clearCopiedTask = Task {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled { copied = nil }
        }
    }

    /// Downscale for the keyboard's toolbar. Keyboard extensions have a tight
    /// memory budget (historically ~30–70 MB), so never hand them full-res art.
    private func thumbnail(of image: UIImage, maxSide: CGFloat = 120) -> Data? {
        let scale = min(maxSide / max(image.size.width, image.size.height), 1)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.pngData()
    }

    private func explainer(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }
}

/// The closest-matching memes, re-ranked live as the user's expression
/// changes (M3). Tapping one copies it to the pasteboard (M4).
///
/// Centred rather than scrollable: the count is fixed and small, so a plain
/// centred row reads better than a left-aligned scroll view.
private struct MatchStrip: View {
    let matches: [MatchEngine.Match]
    let onSelect: (MatchEngine.Match) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(matches) { match in
                Button { onSelect(match) } label: {
                    if let image = MatchEngine.image(named: match.file) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 90, height: 90)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// M4 confirmation: the meme is on the clipboard and the user needs to get
/// back to the app they came from. iOS puts a "◀ AppName" chevron in the
/// status bar automatically when we were opened via URL — that's the return
/// path, since iOS has no App Store-safe way to switch apps programmatically.
private struct CopiedBanner: View {
    let file: String

    var body: some View {
        VStack(spacing: 4) {
            Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("Tap ◀ at the top-left to go back, then long-press the text field and choose Paste.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 24)
    }
}

#Preview {
    NavigationStack { CameraScreen() }
}
