import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

// Import the canvas page we just built!
import 'aircanvas.dart'; 

Future<void> main() async {
  // Required for Flutter desktop apps interacting with the native OS
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the window manager
  await windowManager.ensureInitialized();

  const WindowOptions windowOptions = WindowOptions(
    size: Size(1920, 1080), // Fallback size
    backgroundColor: Colors.transparent, // Make the window invisible!
    titleBarStyle: TitleBarStyle.hidden, // Remove the top drag bar (X, minimize, etc.)
    alwaysOnTop: true, // Never let another app cover this canvas
    skipTaskbar: true, // Don't show an icon in the bottom taskbar
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    // Force the transparent window to fill the entire monitor
    await windowManager.setFullScreen(true);

    // 🚀 THE SECRET SAUCE: 
    // This tells the OS to pass all mouse clicks straight through our app to the desktop below.
    await windowManager.setIgnoreMouseEvents(true);

    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AirCanvasApp());
}

// ─────────────────────────────────────────────────────────────────────────────
// Root Application Widget
// ─────────────────────────────────────────────────────────────────────────────
class AirCanvasApp extends StatelessWidget {
  const AirCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Air Canvas Test Build',
      debugShowCheckedModeBanner: false,
      // We must explicitly set the scaffold background to transparent here too
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.transparent,
          brightness: Brightness.dark,
        ),
      ),
      home: const CanvasPage(), 
    );
  }
}