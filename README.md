# MemeMatcher

An iOS app and custom keyboard that reads your facial expression (and hand gestures) through the front camera and suggests the memes that match it, ready to paste into any chat.

Everything runs on-device. No server, no accounts, and your face never leaves the phone.

## How it works

iOS keyboard extensions can't use the camera, so the work is split between two targets that talk through a shared **App Group**:

```
┌──────────────────────┐   memematcher:// deep link   ┌──────────────────────┐
│  KEYBOARD EXTENSION  │ ───────────────────────────▶ │       MAIN APP       │
│ • "Memes" button     │                              │ • Front camera feed  │
│ • Shows the pick     │                              │ • MediaPipe face +   │
│ • Copies to paste    │                              │   hand extraction    │
└──────────┬───────────┘                              │ • Meme matching      │
           │                                          └──────────┬───────────┘
           └─────────────► APP GROUP (shared defaults) ◀─────────┘
```

1. In any app, tap the **Memes** button on the MemeMatcher keyboard. It opens the main app.
2. The app runs [MediaPipe](https://ai.google.dev/edge/mediapipe) on the camera feed:
   - **Face Landmarker** gives 52 blendshape coefficients (smile, jaw open, brow raise, ...).
   - **Gesture Recognizer** gives normalized hand landmarks plus gesture scores.
3. `MatchEngine` ranks the bundled memes by cosine similarity. The face is the primary channel; hands are a bonus channel that can only raise a score.
4. You pick a meme. The app writes it to the App Group, and the keyboard copies the image so you can paste it.

The meme vectors are computed ahead of time by `tools/build_manifest.py`, using the **same MediaPipe models** the app runs live. That keeps your live face and the memes in one comparable vector space.

## Project layout

| Path | What it is |
|---|---|
| `App/` | Main SwiftUI app: camera, MediaPipe extractors, matching, onboarding tutorial |
| `App/Resources/` | MediaPipe `.task` models and the bundled `MemePack/` (images + `manifest.json`) |
| `Keyboard/` | Keyboard extension (UIKit `UIInputViewController`, QWERTY layout + Memes button) |
| `Shared/` | Framework used by both targets: App Group access and the meme pack model |
| `Memes/` | Source meme images; `Memes/standins/` holds selfies mimicking memes whose face/hands can't be detected |
| `tools/build_manifest.py` | Builds `manifest.json` from `Memes/` |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) project spec |
| `plan.md` | Original design and build plan |

## Requirements

- macOS with Xcode (iOS 17.0+ deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [CocoaPods](https://cocoapods.org)
- A physical iPhone (the camera doesn't work in the Simulator)
- An Apple ID. A free Personal Team is enough for on-device builds, App Groups included.

## Building

```bash
xcodegen generate   # regenerate the .xcodeproj from project.yml
pod install         # always rerun after xcodegen; it patches in MediaPipe
open MemeMatcher.xcworkspace   # the workspace, not the .xcodeproj
```

In Xcode, set your development team on the **MemeMatcher**, **MemeKeyboard** and **Shared** targets. If you use a different bundle ID prefix, change the App Group identifier to match in both `.entitlements` files and in `Shared/AppGroup.swift`. Then run the `MemeMatcher` scheme on your device. It builds and embeds the keyboard too.

## Setting up the keyboard on your phone

The in-app tutorial walks through this on first launch:

1. Allow camera access.
2. **Settings → General → Keyboard → Keyboards → Add New Keyboard → MemeMatcher**.
3. Tap MemeMatcher there and turn on **Allow Full Access**. Without it, iOS silently blocks the keyboard from opening the app, so the Memes button does nothing.
4. Paste into an app that accepts images (Messages, WhatsApp, and so on).

## Adding memes

1. Drop images into `Memes/`.
2. If a meme has no detectable face or hands (cartoons, extreme angles), add a selfie of yourself mimicking it to `Memes/standins/`, using the same filename stem. Each channel falls back to the stand-in on its own, and the original image is still what gets shown and pasted.
3. Rebuild the manifest:

   ```bash
   python3 -m venv tools/.venv
   tools/.venv/bin/pip install mediapipe
   tools/.venv/bin/python tools/build_manifest.py
   ```

   This writes `App/Resources/MemePack/manifest.json` and copies the images into the app bundle.

> The hand-landmark normalization in `build_manifest.py` and `App/Camera/GestureExtractor.swift` must stay identical. If you change one, change the other.

## Note on meme images

The bundled meme images belong to their respective owners and are included for personal, non-commercial use. Clear the rights before distributing a build.
