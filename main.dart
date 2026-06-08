import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'aircanvas.dart'; // Imports the canvas page below

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const WindowOptions windowOptions = WindowOptions(
    backgroundColor: Colors.transparent, // Glass background
    titleBarStyle: TitleBarStyle.hidden, // No top bar
    alwaysOnTop: true, // Stays above PowerPoint/Chrome
    skipTaskbar: false, // Allows her to right-click -> Quit from the taskbar
    windowButtonVisibility: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.maximize(); // Stretches across her Windows monitor
    await windowManager.setIgnoreMouseEvents(true); // Ghost mode (clicks pass through)
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const AirCanvasApp());
}

class AirCanvasApp extends StatelessWidget {
  const AirCanvasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Air Canvas',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.transparent,
          brightness: Brightness.dark,
        ),
      ),
      home: const AirCanvasPage(), 
    );
  }
}
