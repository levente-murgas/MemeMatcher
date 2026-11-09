import SwiftUI
import Shared

/// The app's home screen. Mostly a launchpad: the real work happens in
/// `CameraScreen`. When the keyboard opens `memematcher://capture` we jump
/// straight there, so the hand-off feels like one continuous action.
struct ContentView: View {
    @State private var showCamera = false
    @State private var lastSelection = AppGroup.readSelection()
    @State private var showTutorial = false
    /// Persisted so the walkthrough only interrupts the very first launch.
    @AppStorage("hasSeenTutorial") private var hasSeenTutorial = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        CameraScreen()
                    } label: {
                        Label("Find memes for my face", systemImage: "camera.viewfinder")
                    }
                } footer: {
                    Text("Make an expression, then tap a matching meme to copy it.")
                }

                if let selection = lastSelection,
                   let image = MatchEngine.image(named: selection.file) {
                    Section {
                        HStack {
                            Spacer()
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(maxHeight: 140)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            Spacer()
                        }
                    } header: {
                        Text("Last copied")
                    } footer: {
                        Text("Still on your clipboard. Long-press a text box in Messages or Notes and choose Paste.")
                    }
                }

                Section {
                    Button {
                        showTutorial = true
                    } label: {
                        Label("How it works", systemImage: "questionmark.circle")
                    }
                }
            }
            .navigationTitle("MemeMatcher")
            .navigationDestination(isPresented: $showCamera) {
                CameraScreen()
            }
        }
        // The keyboard opens memematcher://capture — go straight to the camera.
        .onOpenURL { url in
            guard url.scheme == "memematcher" else { return }
            showCamera = true
        }
        .onAppear {
            lastSelection = AppGroup.readSelection()
            if !hasSeenTutorial {
                showTutorial = true
                hasSeenTutorial = true
            }
        }
        .sheet(isPresented: $showTutorial) {
            TutorialView()
        }
    }
}

#Preview {
    ContentView()
}
