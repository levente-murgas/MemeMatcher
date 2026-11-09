#!/usr/bin/env python3
"""Build the meme pack manifest for MemeMatcher.

Runs MediaPipe over every image in Memes/ using the SAME model files the iOS app
uses live — that's what keeps the user's live capture and the memes in one
comparable vector space — and writes:

    App/Resources/MemePack/manifest.json   (feature channels per meme)
    App/Resources/MemePack/<images>        (copies of the source images)

Feature channels are stored per meme as a dict, so extractors can be added
without changing the schema:

    "faceBlendshapes": [52 floats]   MediaPipe Face Landmarker
    "handLandmarks":   [126 floats]  normalized hand shape, L+R slots (see below)
    "handGesture":     [16 floats]   canned gesture scores, L+R slots

Hand normalization (MUST stay in sync with GestureExtractor.swift):
  per hand, from the 21 *world* landmarks (metric, ~centered on the hand)
    1. subtract the centroid
    2. divide by the Frobenius norm  -> unit-norm shape descriptor
    3. flatten to 63 floats in canonical landmark order
  then place each hand into a fixed slot by MediaPipe's handedness
  ("Left" -> slot 0, "Right" -> slot 1), zeros for an absent hand.
Slots (rather than mirroring left onto right) are what let one- and two-handed
poses share a single representation. Deliberately NOT rotation-invariant:
orientation is part of a gesture (Thumb_Up vs Thumb_Down are the same shape
rotated).

Standins: some curated memes have no cleanly detectable face and/or hands
(stylized/cartoon art, extreme angles). Drop a selfie of yourself mimicking
that meme into Memes/standins/, named with the same filename stem as the meme
(extension may differ). Each channel falls back to the standin *independently*,
so a meme can take its face from the original and its hands from the standin.
The original meme image is always what gets displayed and pasted. Provenance is
recorded per channel under "vectorSources".

Usage:  tools/.venv/bin/python tools/build_manifest.py
"""

import json
import math
import shutil
import sys
from pathlib import Path

import mediapipe as mp
from mediapipe.tasks import python as mp_tasks
from mediapipe.tasks.python import vision

REPO = Path(__file__).resolve().parent.parent
SOURCE_DIR = REPO / "Memes"
STANDIN_DIR = SOURCE_DIR / "standins"
FACE_MODEL_PATH = REPO / "App" / "Resources" / "face_landmarker.task"
GESTURE_MODEL_PATH = REPO / "App" / "Resources" / "gesture_recognizer.task"
OUT_DIR = REPO / "App" / "Resources" / "MemePack"
IMAGE_SUFFIXES = {".jpg", ".jpeg", ".png"}

MANIFEST_VERSION = 2

# Channel ids — keep in sync with `FeatureChannel` in Shared/MemePack.swift.
CHANNEL_FACE = "faceBlendshapes"
CHANNEL_HAND_LANDMARKS = "handLandmarks"
CHANNEL_HAND_GESTURE = "handGesture"

# Canonical MediaPipe hand landmark order (21 points).
HAND_LANDMARK_NAMES = [
    "WRIST",
    "THUMB_CMC", "THUMB_MCP", "THUMB_IP", "THUMB_TIP",
    "INDEX_MCP", "INDEX_PIP", "INDEX_DIP", "INDEX_TIP",
    "MIDDLE_MCP", "MIDDLE_PIP", "MIDDLE_DIP", "MIDDLE_TIP",
    "RING_MCP", "RING_PIP", "RING_DIP", "RING_TIP",
    "PINKY_MCP", "PINKY_PIP", "PINKY_DIP", "PINKY_TIP",
]
# Canned gesture categories produced by gesture_recognizer.task.
GESTURE_NAMES = [
    "None", "Closed_Fist", "Open_Palm", "Pointing_Up",
    "Thumb_Down", "Thumb_Up", "Victory", "ILoveYou",
]
HAND_SLOTS = ("L", "R")  # index 0 = Left, index 1 = Right

LANDMARKS_PER_HAND = len(HAND_LANDMARK_NAMES) * 3   # 63
GESTURES_PER_HAND = len(GESTURE_NAMES)              # 8

HAND_LANDMARK_COMPONENT_NAMES = [
    f"{slot}_{name}_{axis}"
    for slot in HAND_SLOTS
    for name in HAND_LANDMARK_NAMES
    for axis in ("x", "y", "z")
]
HAND_GESTURE_COMPONENT_NAMES = [
    f"{slot}_{gesture}" for slot in HAND_SLOTS for gesture in GESTURE_NAMES
]


def build_face_landmarker():
    options = vision.FaceLandmarkerOptions(
        base_options=mp_tasks.BaseOptions(model_asset_path=str(FACE_MODEL_PATH)),
        running_mode=vision.RunningMode.IMAGE,
        num_faces=1,
        output_face_blendshapes=True,
    )
    return vision.FaceLandmarker.create_from_options(options)


def build_gesture_recognizer():
    options = vision.GestureRecognizerOptions(
        base_options=mp_tasks.BaseOptions(model_asset_path=str(GESTURE_MODEL_PATH)),
        running_mode=vision.RunningMode.IMAGE,
        num_hands=2,
    )
    return vision.GestureRecognizer.create_from_options(options)


def normalize_hand(world_landmarks) -> list[float]:
    """21 world landmarks -> 63 floats: centered, unit-norm, flattened."""
    points = [(lm.x, lm.y, lm.z) for lm in world_landmarks]
    n = len(points)
    cx = sum(p[0] for p in points) / n
    cy = sum(p[1] for p in points) / n
    cz = sum(p[2] for p in points) / n
    centered = [(x - cx, y - cy, z - cz) for x, y, z in points]
    norm = math.sqrt(sum(x * x + y * y + z * z for x, y, z in centered))
    if norm == 0:
        return [0.0] * LANDMARKS_PER_HAND
    return [c / norm for point in centered for c in point]


def detect_face(landmarker, path: Path):
    """Returns (52 floats, category names) or (None, [])."""
    result = landmarker.detect(mp.Image.create_from_file(str(path)))
    if not result.face_blendshapes:
        return None, []
    categories = result.face_blendshapes[0]
    return [round(c.score, 6) for c in categories], [c.category_name for c in categories]


def detect_hands(recognizer, path: Path):
    """Returns (126-float landmark vector, 16-float gesture vector), or None.

    Hands are placed into fixed L/R slots by MediaPipe's handedness. If both
    hands report the same handedness (possible on ambiguous images), the
    higher-confidence one keeps its preferred slot and the other takes the
    remaining slot, so no hand is ever silently dropped.
    """
    result = recognizer.recognize(mp.Image.create_from_file(str(path)))
    if not result.hand_world_landmarks:
        return None

    landmark_vector = [0.0] * (LANDMARKS_PER_HAND * len(HAND_SLOTS))
    gesture_vector = [0.0] * (GESTURES_PER_HAND * len(HAND_SLOTS))

    hands = []
    for i, world_landmarks in enumerate(result.hand_world_landmarks):
        handedness = result.handedness[i][0]
        preferred = 0 if handedness.category_name == "Left" else 1
        hands.append((handedness.score, preferred, i, world_landmarks))
    hands.sort(key=lambda h: -h[0])  # most confident handedness first

    used_slots: set[int] = set()
    for _, preferred, i, world_landmarks in hands:
        slot = preferred if preferred not in used_slots else 1 - preferred
        if slot in used_slots:
            continue  # more hands than slots; ignore extras
        used_slots.add(slot)

        offset = slot * LANDMARKS_PER_HAND
        landmark_vector[offset:offset + LANDMARKS_PER_HAND] = [
            round(v, 6) for v in normalize_hand(world_landmarks)
        ]

        # Only the top-scoring gesture is returned by the task, so this vector
        # is sparse by design. It is display/tuning material, not used for
        # matching today.
        if result.gestures and i < len(result.gestures) and result.gestures[i]:
            top = result.gestures[i][0]
            if top.category_name in GESTURE_NAMES:
                gesture_index = GESTURE_NAMES.index(top.category_name)
                gesture_vector[slot * GESTURES_PER_HAND + gesture_index] = round(top.score, 6)

    return landmark_vector, gesture_vector


def main() -> int:
    images = sorted(
        p for p in SOURCE_DIR.iterdir()
        if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES and not p.name.startswith(".")
    )
    if not images:
        print(f"No images found in {SOURCE_DIR}", file=sys.stderr)
        return 1

    standins_by_stem = {}
    if STANDIN_DIR.is_dir():
        for p in STANDIN_DIR.iterdir():
            if p.is_file() and p.suffix.lower() in IMAGE_SUFFIXES and not p.name.startswith("."):
                standins_by_stem[p.stem] = p

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    face_landmarker = build_face_landmarker()
    gesture_recognizer = build_gesture_recognizer()

    blendshape_names: list[str] = []
    memes = []
    stats = {
        CHANNEL_FACE: {"original": [], "standin": [], "missing": []},
        CHANNEL_HAND_LANDMARKS: {"original": [], "standin": [], "missing": []},
    }

    for path in images:
        standin = standins_by_stem.get(path.stem)
        features: dict[str, list[float]] = {}
        sources: dict[str, str] = {}

        # --- Face channel (falls back to the standin independently) ---
        face_vector, names = detect_face(face_landmarker, path)
        face_source = "original"
        if face_vector is None and standin is not None:
            face_vector, names = detect_face(face_landmarker, standin)
            face_source = "standin"
        if face_vector is not None:
            if not blendshape_names:
                blendshape_names = names
            features[CHANNEL_FACE] = face_vector
            sources[CHANNEL_FACE] = face_source
            stats[CHANNEL_FACE][face_source].append(path.name)
        else:
            stats[CHANNEL_FACE]["missing"].append(path.name)

        # --- Hand channels (also fall back independently) ---
        hands = detect_hands(gesture_recognizer, path)
        hand_source = "original"
        if hands is None and standin is not None:
            hands = detect_hands(gesture_recognizer, standin)
            hand_source = "standin"
        if hands is not None:
            hand_vector, gesture_vector = hands
            features[CHANNEL_HAND_LANDMARKS] = hand_vector
            features[CHANNEL_HAND_GESTURE] = gesture_vector
            sources[CHANNEL_HAND_LANDMARKS] = hand_source
            sources[CHANNEL_HAND_GESTURE] = hand_source
            stats[CHANNEL_HAND_LANDMARKS][hand_source].append(path.name)
        else:
            stats[CHANNEL_HAND_LANDMARKS]["missing"].append(path.name)

        shutil.copy2(path, OUT_DIR / path.name)
        entry: dict = {"file": path.name, "features": features}
        if any(source == "standin" for source in sources.values()):
            entry["vectorSources"] = sources
        memes.append(entry)

    manifest = {
        "version": MANIFEST_VERSION,
        # Component names in model order, stored once per channel. The app
        # aligns its live vectors to these by NAME, so ordering bugs can't
        # creep in between the two implementations.
        "featureSchemas": {
            CHANNEL_FACE: {"names": blendshape_names},
            CHANNEL_HAND_LANDMARKS: {"names": HAND_LANDMARK_COMPONENT_NAMES},
            CHANNEL_HAND_GESTURE: {"names": HAND_GESTURE_COMPONENT_NAMES},
        },
        "memes": memes,
    }
    (OUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))

    print(f"Manifest v{MANIFEST_VERSION} written: {OUT_DIR / 'manifest.json'}  ({len(memes)} memes)")
    for channel, label in ((CHANNEL_FACE, "face"), (CHANNEL_HAND_LANDMARKS, "hand")):
        counts = stats[channel]
        print(f"\n  [{label}] from original ({len(counts['original'])}): {', '.join(counts['original']) or '-'}")
        if counts["standin"]:
            print(f"  [{label}] via standin  ({len(counts['standin'])}): {', '.join(counts['standin'])}")
        print(f"  [{label}] not detected ({len(counts['missing'])}): {', '.join(counts['missing']) or '-'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
