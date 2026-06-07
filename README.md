# Air-Canvas Flutter Desktop — Developer B Workspace

## Project Overview

This is the **UI Canvas & Automation Layer** for the Virtual Air-Canvas
Presentation Remote.  It receives gesture data from Developer A's Python
MediaPipe WebSocket server and renders a transparent drawing overlay on top
of the presenter's screen.  Swipe gestures synthesise Win32 arrow-key presses
to control PowerPoint remotely.

---

## Directory Structure

```
air_canvas_flutter_b/
├── pubspec.yaml                   ← Flutter project manifest & dependencies
├── lib/
│   ├── main.dart                  ← Entry point; transparent window setup
│   └── canvas_page.dart           ← WebSocket client + CustomPainter overlay
├── windows/
│   └── runner/
│       └── flutter_window.cpp     ← Win32 MethodChannel + SendInput handler
└── README.md
```

---

## Prerequisites

| Tool | Minimum version |
|------|----------------|
| Flutter SDK | 3.19 or later |
| Dart SDK | 3.3.0 or later |
| Visual Studio 2022 | With "Desktop development with C++" workload |
| Windows | 10 (build 1903+) or 11 |

---

## First-Time Setup

### 1 — Scaffold the full Flutter Windows project

The generated files only contain the *modified* source files.  You must
first scaffold a standard Flutter Windows project and then overwrite the
relevant files:

```bash
# Create the standard Flutter project (Windows target)
flutter create --platforms=windows air_canvas_runner
cd air_canvas_runner

# Copy the generated files into the scaffolded project
# (assuming both directories sit side-by-side)
copy ..\air_canvas_flutter_b\pubspec.yaml .
copy ..\air_canvas_flutter_b\lib\main.dart .\lib\
copy ..\air_canvas_flutter_b\lib\canvas_page.dart .\lib\
copy ..\air_canvas_flutter_b\windows\runner\flutter_window.cpp .\windows\runner\
```

### 2 — Fetch dependencies

```bash
flutter pub get
```

### 3 — Build & run

```bash
flutter run -d windows
```

---

## Data Contract (Developer A → Developer B)

Developer A's Python WebSocket server broadcasts JSON frames to
`ws://localhost:8765`:

```json
{
  "state": "HOVER" | "DRAW" | "CLEAR" | "SWIPE_L" | "SWIPE_R",
  "coords": [x_percentage, y_percentage]   // 0.0 – 1.0 normalised screen pos
}
```

| State | Flutter behaviour | Native action |
|-------|-------------------|---------------|
| `HOVER` | Green crosshair reticle | — |
| `DRAW` | Accumulate red stroke | — |
| `CLEAR` | Wipe all strokes | — |
| `SWIPE_L` | Clear canvas | `SendInput(VK_LEFT)` → previous slide |
| `SWIPE_R` | Clear canvas | `SendInput(VK_RIGHT)` → next slide |

---

## Architecture Notes

### Transparent click-through window
`window_manager.setIgnoreMouseEvents(true)` is called at startup so all
pointer events pass through the overlay to the presentation software beneath.
The overlay is purely visual.

### Smooth stroke rendering
Points are accumulated in fixed-size segments and rendered using midpoint
quadratic Bézier splines — significantly smoother than raw polylines,
especially at lower MediaPipe frame rates.

### Auto-reconnect
The WebSocket client retries every 2 seconds if the connection drops,
allowing Developer A to restart the Python server without requiring an app
restart.

### Win32 SendInput
The C++ handler injects a key-down + key-up `INPUT` pair at the OS level.
Events are dispatched to whichever window currently holds focus (the
presentation window), so no focus management is needed on the Dart side.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Waiting for CV…" badge stays red | Python server not running | Start Developer A's server before or after — the client auto-reconnects |
| Slides don't advance | Presentation window lost focus | Click the presentation window once to give it focus; overlay is click-through |
| `SendInput` fails | UIPI (UAC elevation mismatch) | Run Flutter app as Administrator, or ensure both apps share the same IL |
| Black window instead of transparent | GPU compositor issue | Ensure `windows/runner/main.cpp` uses `WS_EX_LAYERED` (default Flutter runner) |
