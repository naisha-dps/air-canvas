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

  // No explicit size — main.cpp already starts the window at SM_CXSCREEN ×
  // SM_CYSCREEN so it fills the primary monitor from the first frame.
  const WindowOptions windowOptions = WindowOptions(
    backgroundColor: Colors.transparent,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
    skipTaskbar: true,
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // setAsFrameless() removes the title bar and border for an overlay window.
    // Prefer this over setFullScreen(true), which uses exclusive fullscreen
    // mode and can prevent other windows from rendering on top.
    await windowManager.setAsFrameless();
    await windowManager.setAlwaysOnTop(true);
    // Click-through is handled via WM_NCHITTEST in win32_window.cpp and
    // flutter_window.cpp — we do NOT call setIgnoreMouseEvents(true) because
    // it adds WS_EX_LAYERED without SetLayeredWindowAttributes, which makes
    // the entire Flutter rendering surface invisible on Windows 10/11.

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
