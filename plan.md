# Expression → Meme Keyboard — Build Plan (Option A)

*An iOS app + custom keyboard that reads your facial expression and suggests matching memes to paste.*

---

## 1. The core idea, and the constraint that shapes everything

You want: tap a button in the keyboard → front camera reads your face → matching memes appear in the keyboard → tap one to paste it.

The hard rule on iOS: **keyboard extensions cannot use the camera.** They run in a locked-down sandbox with no camera, mic, photo library, or Face ID access — even with "Full Access" turned on (that only unlocks networking). Only the *main app* can open the camera.

**Option A works around this** by splitting the job between two pieces that ship in the same project:

- **The main app** — has full camera access. It does the face capture, expression detection, and meme matching.
- **The keyboard extension** — the thing that appears above your keys. It shows the matched memes and pastes the one you pick.

They talk to each other through a shared storage box called an **App Group**. The only visible seam for the user is a quick jump from the keyboard into the app and back — everything else feels continuous.

```
┌─────────────────────┐        deep link (URL)        ┌──────────────────────┐
│  KEYBOARD EXTENSION  │ ────────────────────────────▶ │      MAIN APP        │
│                      │                                │                      │
│ • "Meme Face" button │                                │ • Front camera feed  │
│ • Shows meme results │                                │ • Detect expression  │
│ • Taps → paste       │                                │ • Match to memes     │
└──────────┬───────────┘                                └──────────┬───────────┘
           │                                                       │
           │          ◀── writes matches / reads matches ──▶        │
           │                                                       │
           └──────────────► APP GROUP (shared container) ◀─────────┘
                     (shared folder + shared settings both can read/write)
```

---

## 2. What an "App Group" actually is (key iOS concept)

Because you're new to iOS, this is the one concept to internalize, since it's the backbone of Option A.

An **App Group** is a shared sandbox that multiple targets in the same project (your app + your keyboard) are allowed to read and write. Without it, the app and the keyboard are walled off from each other. With it, they share:

- A **shared folder on disk** (via `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`) — this is where you'll drop the memes the app matched, so the keyboard can display them.
- **Shared small settings** (via `UserDefaults(suiteName:)`) — good for flags like "a fresh batch of matches is ready" or the list of matched meme filenames.

You enable it in Xcode under *Signing & Capabilities → App Groups* on **both** targets, using the same identifier (e.g. `group.com.yourname.memekeyboard`).

---

## 3. Tech stack

| Layer | Choice | Why |
|---|---|---|
| Language | **Swift** | The default for iOS; all the camera/ML APIs are Swift-first. |
| UI | **SwiftUI** for the main app, **UIKit** for the keyboard | Keyboards are built on `UIInputViewController` (UIKit); SwiftUI can be embedded inside it if you want. |
| Camera | **AVFoundation** (`AVCaptureSession`) | Standard front-camera capture. |
| Face + landmarks | **Vision framework** (`VNDetectFaceLandmarksRequest`) | Built into iOS, free, on-device, finds the face and its features. |
| Expression → label (Route 1) | **Core ML emotion model** (see §5) | Turns the face into an emotion label. |
| Expression → vector (Route 2) | **MediaPipe Face Landmarker** (see §5) | Produces 52 ARKit-style blendshape coefficients from *any* RGB frame **or static image** — so the same extractor works on both the live face and the memes. |
| Meme matching | Nearest-neighbor over stored vectors | Simple math, runs instantly on-device. |
| Storage | **App Group** shared container | The hand-off channel between app and keyboard. |
| Tooling | **Xcode** (free), an Apple Developer account ($99/yr to ship) | Required to build and submit. |

Everything runs **on-device** — no server, no accounts, and user faces never leave the phone. That's a strong privacy story and simplifies App Store review.

---

## 4. Project shape in Xcode

One Xcode project, three targets:

1. **MemeKeyboard** (main app) — camera, detection, matching, plus a normal app UI (onboarding, permissions, meme browser, settings).
2. **MemeKeyboardExtension** (keyboard) — the custom keyboard.
3. **Shared** (a small framework or shared files) — the expression model wrapper, the matching code, and the App Group paths, so both targets reuse the same logic instead of duplicating it.

---

## 5. Component 1 — Expression detection (in the main app)

**Goal:** turn a camera frame into something you can match against memes.

Pipeline:

1. **Capture** a frame from the front camera with `AVCaptureSession`.
2. **Find the face** with Vision's `VNDetectFaceLandmarksRequest`. This gives you a bounding box and 60-plus landmark points (eyes, brows, mouth, jaw).
3. **Classify the expression.** Two routes:
   - **Route 1 — Emotion label (simpler).** Add a small Core ML emotion model that outputs categories like happy / sad / angry / surprised / neutral. A good, mobile-friendly candidate is **HSEmotion**, convertible to Core ML; or train/convert a compact CNN on a public FER dataset (FERPlus, AffectNet). You then match memes tagged with the same category.
   - **Route 2 — Expression vector (better matches).** Instead of one label, produce a short numeric vector describing the face — **52 blendshape coefficients** (`mouthSmile`, `jawOpen`, `browDownLeft`…). This captures *degree* and *blend* of expression, so "slight smirk" and "huge grin" match different memes. **Use MediaPipe Face Landmarker to produce these — not ARKit's `ARFaceAnchor`.** See the note below.

**Why MediaPipe and not `ARFaceAnchor` for Route 2:** `ARFaceAnchor` blendshapes come from a *live* `ARFaceTrackingConfiguration` session driven by the TrueDepth camera on a real 3D face. It has no way to analyze a static 2D image, so it **cannot generate vectors for the meme library** — and Route 2 requires both the user's face and the memes to live in the *same* vector space. **MediaPipe Face Landmarker** solves this: it outputs 52 blendshape coefficients aligned to the ARKit category set from *any* single RGB image, so you run the **same extractor** on the live camera frame *and* on each meme. Bonus: MediaPipe doesn't need a TrueDepth sensor, so Route 2 isn't limited to Face ID devices. (Avoid mixing extractors — e.g. ARKit for the face and MediaPipe for memes — because the two models aren't calibrated to each other even though the category names match, which makes nearest-neighbor distances noisy.)

**Recommendation:** start with **Route 1** to get an end-to-end app working fast, then upgrade to **Route 2 (MediaPipe on both sides)** for quality once the plumbing is proven.

---

## 6. Component 2 — The curated meme library (built once, at build time)

Since you chose a **curated built-in pack**, the memes ship inside the app, and you pre-compute their expressions so matching is instant on the phone.

Build-time prep (a one-off script you run on your Mac, *not* on the phone):

1. Collect your meme images and **clear the rights** to use them (see §10 — this is the real gotcha with a built-in pack).
2. Run the *same* face/expression model over each meme to get its label or vector. For Route 2 this means running **MediaPipe Face Landmarker** over each meme image to extract its 52-blendshape vector — the identical extractor you'll use on the live face, which is what keeps them comparable. Memes without a clear/detectable face get tagged by hand.
3. Save a small **manifest** (JSON) alongside the images: `filename → expression label/vector → optional tags`.
4. Bundle the images + manifest into the app.

At runtime the app just loads this manifest once — no per-image processing on the phone.

---

## 7. Component 3 — Matching

- **Route 1 (labels):** filter memes whose label equals your detected emotion, optionally rank by a confidence score, return the top N (say 12).
- **Route 2 (vectors):** compute distance (cosine or Euclidean) between your live expression vector and every meme vector, return the closest N. With a few hundred memes this is instantaneous; no fancy vector database needed.

The app writes the chosen N meme files (or just their filenames, since they're bundled) into the **App Group** shared container and flips a "results ready" flag in shared `UserDefaults`.

---

## 8. Component 4 — The keyboard extension

The keyboard is a `UIInputViewController` subclass. Your custom row/button sits in the menu strip, mirroring how the GIF button looks.

Flow inside the keyboard:

1. **Show a "Meme Face" button** in the keyboard's top row.
2. **On tap, open the main app** via a custom URL scheme (e.g. `memekeyboard://capture`). Keyboards are allowed to open a URL through the responder chain — this is the standard trick to launch the container app from a keyboard. The app opens straight to the camera.
3. The user captures their face in the app; the app matches memes, writes results to the App Group, and (optionally) auto-returns to the previous app.
4. **Back in the keyboard, read the results** from the App Group and lay them out as a scrollable grid of thumbnails.
5. **On tapping a meme**, paste it. For a plain caption/text meme this is `textDocumentProxy.insertText(...)`. For an *image* meme, you copy the image to the pasteboard (`UIPasteboard.general.image = ...`) and the user pastes it — because most text fields can't receive an inline image directly, image "insertion" on iOS almost always goes through the pasteboard. Full Access is required for pasteboard writes from a keyboard, so you'll request it.

**Reality checks specific to keyboards:**
- Keyboard extensions have a **tight memory budget** (historically ~30–70 MB). Show *downscaled thumbnails*, not full-res images, and load lazily.
- Requiring "Full Access" and an app-switch adds friction — plan clear one-time onboarding in the main app that explains why.

---

## 9. Milestones (suggested order)

Each milestone is a thing you can actually run, which keeps momentum and de-risks the scary parts early.

1. **M0 — Hello, two targets.** Create the project with a main app + keyboard extension + App Group. Prove the keyboard can open the app via a URL, and that both can read/write one test string in the App Group. *(This validates the whole Option A spine before any ML.)*
2. **M1 — Camera + face box.** Main app opens the front camera and draws a box around your face with Vision. No expression yet.
3. **M2 — Expression label.** Add the Core ML emotion model; show the detected label on screen live.
4. **M3 — Meme library + matching.** Build the curated pack + manifest, and in the app show the top matches for your current expression.
5. **M4 — Full loop.** Keyboard button → app captures + matches → writes to App Group → keyboard displays the grid → tap pastes. This is your first true end-to-end demo.
6. **M5 — Polish.** Thumbnails/memory tuning, onboarding + permission flows, auto-return to prior app, empty/no-face states, settings.
7. **M6 — Upgrade matching (optional).** Move from labels to expression vectors (Route 2) for noticeably better matches.
8. **M7 — Ship.** App icon, privacy policy, App Store listing, TestFlight beta, submission.

A realistic first playable end-to-end (through M4) is the milestone worth aiming at before investing in polish.

---

## 10. App Store & legal considerations (don't skip)

- **Memes = copyright.** A built-in pack means *you* are distributing those images. Popular meme templates and especially screenshots from movies/TV can be someone's IP. Safest paths: use images under permissive licenses (Creative Commons, public domain), commission/original art, or license a set. Budget real time for clearing this — it's the most likely thing to cause a rejection or a takedown, not the tech.
- **Camera privacy.** You'll need an `NSCameraUsageDescription` string explaining why. Keeping all processing on-device ("your face never leaves your phone, nothing is uploaded") is both true and a great review/marketing point.
- **Keyboard Full Access disclosure.** Apple scrutinizes keyboards that request Full Access. Be explicit that it's only for pasting images, and that you don't log keystrokes.
- **Apple Developer Program:** $99/year to ship to the App Store or even to TestFlight beta testers.

---

## 11. Known risks / open decisions

- **Expression accuracy on real, non-ideal faces** (lighting, angles, glasses) — mitigate with a confidence threshold and a graceful "no clear expression, here are popular memes" fallback.
- **The app-switch seam** — Option A's one unavoidable UX cost. Auto-returning the user to their previous app after capture softens it a lot; test how smooth that feels early.
- **Model size vs. keyboard memory** — keep the model in the *app* (which has more memory), not the keyboard, and only pass results across the App Group.
- **Route 2 extractor is settled: MediaPipe on both sides.** `ARFaceAnchor`/ARKit blendshapes are ruled out because they can't process the static meme images, only a live TrueDepth feed. MediaPipe Face Landmarker generates the same 52-blendshape vector from any RGB image, works on non–Face ID devices too, and keeps the user face and memes in one comparable space. The remaining decision is minor: how many of the 52 coefficients to keep and how to normalize them before nearest-neighbor matching. Integrating MediaPipe on iOS does add a third-party dependency (its iOS task library) rather than a purely Apple-native stack — worth noting for build size and maintenance.

---

## 12. What I'd tackle first

Build **M0** and **M1** before anything else. M0 proves the app↔keyboard hand-off (the part unique to iOS and most likely to surprise you), and M1 proves camera + face detection. If those two feel good, the rest is mostly assembling known pieces. Everything downstream — which emotion model, labels vs. vectors, how big the meme pack is — can be swapped without changing this architecture.