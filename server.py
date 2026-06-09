import asyncio
import json
import os
import sys
import threading
import time
import urllib.request

import cv2
import mediapipe as mp
import websockets

# ── Model auto-download ───────────────────────────────────────────────────────
# MediaPipe Tasks API requires a .task model file (not bundled with the pip package).
MODEL_PATH = "hand_landmarker.task"
MODEL_URL  = (
    "https://storage.googleapis.com/mediapipe-models/"
    "hand_landmarker/hand_landmarker/float16/1/hand_landmarker.task"
)

def _ensure_model():
    if os.path.exists(MODEL_PATH):
        return
    print("📥  Downloading hand landmark model (~8 MB) — one-time setup …")
    urllib.request.urlretrieve(MODEL_URL, MODEL_PATH)
    print("    Done.\n")

# ── Global shared state ───────────────────────────────────────────────────────
# Camera thread writes; WebSocket thread reads. Simple enough that a lock is
# not required — worst case is one stale frame being sent.
ai_state = {"state": "HOVER", "coords": [0.5, 0.5]}

# ── Windows camera permission guard ──────────────────────────────────────────
def _check_camera_windows(cap):
    """
    On Windows, VideoCapture() reports success even when camera privacy blocks
    access — cap.read() just silently returns empty frames. Detect it early.
    """
    if sys.platform != "win32":
        return True
    ok, frame = cap.read()
    if not ok or frame is None:
        print("\n❌  CAMERA BLOCKED — Windows privacy is denying access.\n")
        print("    Fix:  Settings → Privacy & Security → Camera")
        print("          ✓  Allow apps to access your camera")
        print("          ✓  Allow desktop apps to access your camera\n")
        print("    Then re-run this script.\n")
        return False
    return True

# ==========================================
# 👁️  THREAD 1 — COMPUTER VISION ENGINE
# ==========================================
def vision_thread():
    global ai_state

    _ensure_model()

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("\n❌  Cannot open camera (index 0).")
        print("    Is another app (Teams, Zoom, OBS) using it?\n")
        sys.exit(1)
    if not _check_camera_windows(cap):
        cap.release()
        sys.exit(1)

    # ── New MediaPipe Tasks API ───────────────────────────────────────────────
    # mp.solutions was removed in MediaPipe 0.10. Use mp.tasks instead.
    BaseOptions        = mp.tasks.BaseOptions
    HandLandmarker     = mp.tasks.vision.HandLandmarker
    HandLandmarkerOpts = mp.tasks.vision.HandLandmarkerOptions
    RunningMode        = mp.tasks.vision.RunningMode

    options = HandLandmarkerOpts(
        base_options=BaseOptions(model_asset_path=MODEL_PATH),
        running_mode=RunningMode.VIDEO,   # VIDEO mode tracks between frames
        num_hands=1,
        min_hand_detection_confidence=0.7,
        min_hand_presence_confidence=0.7,
        min_tracking_confidence=0.7,
    )

    print("📷  Vision engine running. Show your hand to the camera.")
    print("    Gestures:")
    print("      ☝️   Index only  →  DRAW")
    print("      ✌️   Index + middle  →  HOVER (move cursor, no draw)")
    print("      🖐️   Open hand  →  CLEAR canvas")
    print("    Press ESC on the preview window to quit.\n")

    start_ms = int(time.time() * 1000)

    with HandLandmarker.create_from_options(options) as detector:
        while True:
            ok, frame = cap.read()
            if not ok:
                continue

            frame  = cv2.flip(frame, 1)
            rgb    = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            ts_ms  = int(time.time() * 1000) - start_ms

            mp_img = mp.Image(image_format=mp.ImageFormat.SRGB, data=rgb)
            result = detector.detect_for_video(mp_img, ts_ms)

            current_state  = "HOVER"
            current_coords = ai_state["coords"]

            if result.hand_landmarks:
                lm = result.hand_landmarks[0]   # first (only) hand

                # y-coords: smaller = higher on screen
                idx_tip_y   = lm[8].y;  idx_pip_y   = lm[6].y
                mid_tip_y   = lm[12].y; mid_pip_y   = lm[10].y
                pinky_tip_y = lm[20].y; pinky_pip_y = lm[18].y

                current_coords = [lm[8].x, lm[8].y]   # index fingertip = cursor

                # CLEAR  — open hand (pinky + middle + index all up)
                if (pinky_tip_y < pinky_pip_y
                        and mid_tip_y < mid_pip_y
                        and idx_tip_y < idx_pip_y):
                    current_state = "CLEAR"
                # HOVER  — peace sign (index + middle up)
                elif mid_tip_y < mid_pip_y and idx_tip_y < idx_pip_y:
                    current_state = "HOVER"
                # DRAW   — pointing (index only up)
                elif idx_tip_y < idx_pip_y and mid_tip_y > mid_pip_y:
                    current_state = "DRAW"

                # Draw landmark dots on the developer preview
                h, w = frame.shape[:2]
                for pt in lm:
                    cv2.circle(frame, (int(pt.x * w), int(pt.y * h)), 5, (0, 255, 0), -1)

                # Label current gesture on preview
                cv2.putText(frame, current_state, (20, 40),
                            cv2.FONT_HERSHEY_SIMPLEX, 1.2, (0, 200, 255), 2)

            ai_state["state"] = current_state
            if current_state != "CLEAR":
                ai_state["coords"] = current_coords

            cv2.imshow("Air Canvas  —  Developer Preview  (ESC to quit)", frame)
            if cv2.waitKey(1) & 0xFF == 27:
                break

    cap.release()
    cv2.destroyAllWindows()

# ==========================================
# 🌐  THREAD 2 — WEBSOCKET BROADCASTER
# ==========================================
async def handle_connection(websocket):
    print("🔥  Flutter client connected — streaming at ~30 fps …")
    try:
        while True:
            await websocket.send(json.dumps(ai_state.copy()))
            await asyncio.sleep(1 / 30)
    except websockets.exceptions.ConnectionClosed:
        print("❌  Flutter client disconnected.")

async def start_server():
    async with websockets.serve(handle_connection, "0.0.0.0", 8765):
        print("🚀  WebSocket server listening on ws://localhost:8765")
        await asyncio.Future()

def run_server():
    asyncio.run(start_server())

# ==========================================
# 🚀  LAUNCH
# ==========================================
if __name__ == "__main__":
    # WebSocket server in a daemon thread so it dies when the main thread exits.
    threading.Thread(target=run_server, daemon=True).start()

    # Camera + OpenCV preview on the main thread.
    # macOS requires GUI on the main thread; Windows works either way.
    vision_thread()
