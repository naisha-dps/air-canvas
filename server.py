import asyncio
import websockets
import json
import cv2
import mediapipe as mp
import threading

# 🌍 GLOBAL SHARED STATE
# This dictionary acts as the bridge. The Camera thread constantly updates it, 
# and the Server thread constantly reads it to send to Flutter.
ai_state = {
    "state": "HOVER",
    "coords": [0.5, 0.5]
}

# ==========================================
# 👁️ THREAD 1: THE COMPUTER VISION ENGINE
# ==========================================
def vision_thread():
    global ai_state
    
    cap = cv2.VideoCapture(0)
    mp_hands = mp.solutions.hands
    # min_tracking_confidence keeps the line smooth so it doesn't jitter
    hands = mp_hands.Hands(max_num_hands=1, min_detection_confidence=0.7, min_tracking_confidence=0.7)
    mp_draw = mp.solutions.drawing_utils

    print("📷 AI Vision Engine Started! Camera is warm.")

    while True:
        success, frame = cap.read()
        if not success:
            continue

        # Flip the frame so it acts like a mirror
        frame = cv2.flip(frame, 1)
        rgb_frame = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        result = hands.process(rgb_frame)

        # Default fallback states
        current_state = "HOVER"
        current_coords = ai_state["coords"]

        if result.multi_hand_landmarks:
            for hand_landmarks in result.multi_hand_landmarks:
                mp_draw.draw_landmarks(frame, hand_landmarks, mp_hands.HAND_CONNECTIONS)

                # -- LANDMARK EXTRACTION --
                # y-coordinates: Smaller numbers mean the finger is HIGHER up on the screen
                idx_tip_y = hand_landmarks.landmark[8].y
                idx_pip_y = hand_landmarks.landmark[6].y   # Index joint
                
                mid_tip_y = hand_landmarks.landmark[12].y
                mid_pip_y = hand_landmarks.landmark[10].y  # Middle joint
                
                pinky_tip_y = hand_landmarks.landmark[20].y
                pinky_pip_y = hand_landmarks.landmark[18].y # Pinky joint

                # The X and Y of the index finger tip is our cursor
                idx_x = hand_landmarks.landmark[8].x
                idx_y = hand_landmarks.landmark[8].y
                current_coords = [idx_x, idx_y]

                # -- GESTURE LOGIC --
                # 1. CLEAR: If pinky, middle, and index are all up (Open Hand)
                if pinky_tip_y < pinky_pip_y and mid_tip_y < mid_pip_y and idx_tip_y < idx_pip_y:
                    current_state = "CLEAR"
                
                # 2. HOVER: If Middle finger is up AND Index is up (Peace Sign)
                elif mid_tip_y < mid_pip_y and idx_tip_y < idx_pip_y:
                    current_state = "HOVER"
                
                # 3. DRAW: If ONLY Index finger is up (Pointing)
                elif idx_tip_y < idx_pip_y and mid_tip_y > mid_pip_y:
                    current_state = "DRAW"

        # Safely update the global dictionary
        ai_state["state"] = current_state
        if current_state != "CLEAR":
            ai_state["coords"] = current_coords

        # Show the developer preview window
        cv2.imshow("Air Canvas - Developer View", frame)
        
        # Press 'ESC' on the video window to cleanly kill the camera
        if cv2.waitKey(1) & 0xFF == 27:
            break

    cap.release()
    cv2.destroyAllWindows()

# ==========================================
# 🌐 THREAD 2: THE INTERNET BROADCASTER
# ==========================================
async def handle_connection(websocket):
    print("\n🔥 Frontend Connected! Streaming Live AI Data...")
    try:
        while True:
            # Package the global dictionary into a JSON string
            packet = ai_state.copy()
            
            # Fire it to the Flutter app
            await websocket.send(json.dumps(packet))
            
            # Lock the server to roughly 30 Frames Per Second
            await asyncio.sleep(0.03)
            
    except websockets.exceptions.ConnectionClosed:
        print("\n❌ Frontend Disconnected.")

async def start_server():
    async with websockets.serve(handle_connection, "0.0.0.0", 8765):
        print("🚀 Server Running on Port 8765")
        await asyncio.Future()

# ==========================================
# 🚀 LAUNCH SEQUENCE (MAC-SAFE)
# ==========================================
def run_server():
    # asyncio needs its own loop when running in a background thread
    asyncio.run(start_server())

if __name__ == "__main__":
    # 1. Put the Internet Server in the background worker thread
    server = threading.Thread(target=run_server, daemon=True)
    server.start()
    
    # 2. Run the Camera engine on the MAIN thread so macOS allows the window!
    vision_thread()