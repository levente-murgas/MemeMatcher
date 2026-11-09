import SwiftUI
import AVFoundation
import Shared

/// First-run walkthrough. Worth doing properly because MemeMatcher has three
/// setup gotchas that fail *silently* if missed: the keyboard must be added,
/// Full Access must be on (or the Memes button does nothing at all), and image
/// paste only works in apps that accept images.
///
/// Where iOS allows it, the tutorial asks for permission inline rather than
/// telling the user to go hunting — see `CameraPermissionPage`.
struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private static let pageCount = 5

    var body: some View {
        NavigationStack {
            TabView(selection: $page) {
                IntroPage().tag(0)
                CameraPermissionPage().tag(1)
                KeyboardSetupPage().tag(2)
                FullAccessPage().tag(3)
                PastePage().tag(4)
            }
            .tabViewStyle(.page)
            .indexViewStyle(.page(backgroundDisplayMode: .always))
            .safeAreaInset(edge: .bottom) {
                Button(page == Self.pageCount - 1 ? "Get started" : "Next") {
                    if page == Self.pageCount - 1 {
                        dismiss()
                    } else {
                        withAnimation { page += 1 }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 24)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Pages

/// Opening page: a stack of real memes from the pack that fans out like a
/// hand of cards.
private struct IntroPage: View {
    var body: some View {
        TutorialPage(
            title: "Memes that match your face",
            message: "Pull a face, and MemeMatcher finds the memes that look like you. Everything runs on your phone, so your face is never uploaded."
        ) {
            MemeFanView()
        }
    }
}

/// The one permission iOS lets us request inline, exactly like WhatsApp asking
/// for contacts.
private struct CameraPermissionPage: View {
    @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        TutorialPage(
            title: "Allow the camera",
            message: "MemeMatcher reads your expression to find matching memes. Nothing is recorded and nothing leaves your phone."
        ) {
            Image(systemName: status == .authorized ? "checkmark.circle.fill" : "camera.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(status == .authorized ? Color.green : Color.accentColor)
        } action: {
            switch status {
            case .notDetermined:
                Button("Allow camera") {
                    AVCaptureDevice.requestAccess(for: .video) { _ in
                        DispatchQueue.main.async {
                            status = AVCaptureDevice.authorizationStatus(for: .video)
                        }
                    }
                }
                .buttonStyle(.bordered)
            case .authorized:
                Label("Camera allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            default:
                Button("Open Settings") { openAppSettings() }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Adding a keyboard cannot be prompted for — iOS has no API for it — so the
/// best available is a direct jump to Settings plus live status.
private struct KeyboardSetupPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = AppGroup.readKeyboardStatus()

    var body: some View {
        TutorialPage(
            title: "Add the keyboard",
            message: "Settings → General → Keyboard → Keyboards → Add New Keyboard… → MemeMatcher.\n\niOS only lets you add keyboards from Settings, so this one needs a couple of taps."
        ) {
            Image(systemName: status != nil ? "checkmark.circle.fill" : "keyboard")
                .font(.system(size: 64))
                .foregroundStyle(status != nil ? Color.green : Color.accentColor)
        } action: {
            if status != nil {
                Label("Keyboard detected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Button("Open Settings") { openAppSettings() }
                    .buttonStyle(.bordered)
            }
        }
        // Re-check when returning from Settings.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = AppGroup.readKeyboardStatus() }
        }
    }
}

private struct FullAccessPage: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var status = AppGroup.readKeyboardStatus()

    var body: some View {
        TutorialPage(
            title: "Turn on Full Access",
            message: "Tap MemeMatcher in the keyboard list and enable Allow Full Access.\n\nThis is what lets the Memes button open the app. Without it the button silently does nothing. We don't log anything you type."
        ) {
            Image(systemName: (status?.hasFullAccess ?? false) ? "checkmark.circle.fill" : "lock.open")
                .font(.system(size: 64))
                .foregroundStyle((status?.hasFullAccess ?? false) ? Color.green : Color.accentColor)
        } action: {
            if status?.hasFullAccess == true {
                Label("Full Access on", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 8) {
                    Button("Open Settings") { openAppSettings() }
                        .buttonStyle(.bordered)
                    if status == nil {
                        Text("Status shows up once you've used the keyboard at least once.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { status = AppGroup.readKeyboardStatus() }
        }
    }
}

private struct PastePage: View {
    var body: some View {
        TutorialPage(
            title: "Pick, go back, paste",
            message: "Tap Memes in the keyboard, pull a face, and tap a match to copy it. Then tap ◀ at the top-left to go back and long-press the text box to Paste.\n\nMemes are images, so paste works in Messages, Notes, Mail and WhatsApp, but not in plain text boxes like search bars, which can't hold images."
        ) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)
        }
    }
}

// MARK: - Building blocks

/// Shared page chrome so every page lines up identically.
private struct TutorialPage<Art: View, Action: View>: View {
    let title: String
    let message: String
    @ViewBuilder var art: () -> Art
    @ViewBuilder var action: () -> Action

    init(title: String,
         message: String,
         @ViewBuilder art: @escaping () -> Art,
         @ViewBuilder action: @escaping () -> Action) {
        self.title = title
        self.message = message
        self.art = art
        self.action = action
    }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            art()
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            action()
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
    }
}

extension TutorialPage where Action == EmptyView {
    init(title: String, message: String, @ViewBuilder art: @escaping () -> Art) {
        self.init(title: title, message: message, art: art, action: { EmptyView() })
    }
}

/// Real memes from the bundled pack, stacked then fanned out like a hand of
/// cards. Falls back gracefully if a filename is ever removed from the pack.
private struct MemeFanView: View {
    @State private var spread = false

    private static let files = [
        "Surprised_Pikachu.jpg",
        "williamdafoe.jpeg",
        "gruGun.jpg",
        "Sad_Linus.jpg",
        "chadgirl.jpeg",
    ]

    private var images: [UIImage] {
        Self.files.compactMap { MatchEngine.image(named: $0) }
    }

    var body: some View {
        let cards = images
        let middle = Double(cards.count - 1) / 2

        ZStack {
            ForEach(Array(cards.enumerated()), id: \.offset) { index, image in
                let offsetFromCentre = Double(index) - middle
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(.background, lineWidth: 3)
                    )
                    .shadow(radius: 4, y: 2)
                    // Fan out from a single stacked pile.
                    .rotationEffect(.degrees(spread ? offsetFromCentre * 11 : 0))
                    .offset(x: spread ? offsetFromCentre * 46 : 0,
                            y: spread ? abs(offsetFromCentre) * 7 : 0)
                    .zIndex(Double(index))
            }
        }
        .frame(height: 150)
        .onAppear {
            // Brief beat on the stacked pile before it fans out.
            withAnimation(.spring(response: 0.75, dampingFraction: 0.68).delay(0.25)) {
                spread = true
            }
        }
    }
}

/// Opens this app's page in Settings — the deepest link iOS permits.
private func openAppSettings() {
    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
    UIApplication.shared.open(url)
}

#Preview {
    TutorialView()
}
