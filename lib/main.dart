// lib/main.dart
// ─────────────────────────────────────────────────────────────────────────────
// Entry point for the Air-Canvas Flutter Desktop application.
//
// Window configuration goals:
//   • Fullscreen, borderless, transparent
//   • Always on top (overlays PowerPoint / any presentation software)
//   • Mouse events ignored so the presenter can click THROUGH the canvas
//
// The MethodChannel declared here is the bridge between the Dart UI layer and
// the native Win32 C++ automation layer inside flutter_window.cpp.
// ─────────────────────────────────────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'canvas_page.dart';

// The channel name must match exactly what is registered in flutter_window.cpp.
const kAutomationChannel = 'com.aircanvas.automation/slides';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── window_manager bootstrap ──────────────────────────────────────────────
  await windowManager.ensureInitialized();

  const WindowOptions windowOptions = WindowOptions(
    // Let Flutter determine the size; we force fullscreen below.
    size: Size(1920, 1080),
    // Transparent background – required so only the drawn strokes are visible.
    backgroundColor: Colors.transparent,
    // No title bar, resize handles, or drop shadow.
    titleBarStyle: TitleBarStyle.hidden,
    // Always render on top of every other application.
    alwaysOnTop: true,
    // Removes the window frame entirely.
    skipTaskbar: true,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // ── Make the window truly fullscreen ──────────────────────────────────
    await windowManager.setFullScreen(true);

    // ── CRITICAL: Pass all mouse / pointer events through to the layer below.
    // This allows the presenter to interact normally with PowerPoint while
    // our canvas overlay is active.
    await windowManager.setIgnoreMouseEvents(true);

    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AirCanvasApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Root widget – keeps the app shell minimal and transparent.
// ─────────────────────────────────────────────────────────────────────────────
class AirCanvasApp extends StatelessWidget {
  const AirCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Air Canvas – Overlay',
      debugShowCheckedModeBanner: false,
      // Transparent theme so the window background shows through.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.transparent,
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.transparent,
      ),
      home: const CanvasPage(automationChannelName: kAutomationChannel),
    );
  }
}
