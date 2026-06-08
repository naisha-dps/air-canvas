import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class CanvasPage extends StatefulWidget {
  const CanvasPage({super.key});

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

class _CanvasPageState extends State<CanvasPage> {
  // 1. WebSocket Setup
  // CHANGE THIS TO YOUR NGROK LINK IF TESTING OVER THE INTERNET!
  final String _wsUrl = 'ws://127.0.0.1:8765';
  late WebSocketChannel _channel;
  StreamSubscription? _subscription;

  // 2. Drawing State
  List<List<Offset>> _completedStrokes = [];
  List<Offset> _activeStroke = [];
  Offset _cursorNorm = const Offset(0.5, 0.5); // Default to center
  String _currentState = 'HOVER';

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  void _connectToServer() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
      _subscription = _channel.stream.listen(
        _onDataReceived,
        onError: (error) => print("❌ Connection Error: $error"),
        onDone: () => print("⚠️ Server disconnected."),
      );
    } catch (e) {
      print("❌ Failed to connect: $e");
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _channel.sink.close();
    super.dispose();
  }

  // 3. The JSON Parser & State Machine
  void _onDataReceived(dynamic rawData) {
    if (rawData is! String) return;

    try {
      // Decode the incoming JSON string from Python
      final Map<String, dynamic> packet = jsonDecode(rawData);
      
      final String newState = packet['state'] ?? 'HOVER';
      
      // The CLEAR command doesn't send coords, so we must check if they exist!
      if (packet.containsKey('coords')) {
        final List<dynamic> coords = packet['coords'];
        _cursorNorm = Offset(
          (coords[0] as num).toDouble().clamp(0.0, 1.0),
          (coords[1] as num).toDouble().clamp(0.0, 1.0),
        );
      }

      // Route the action based on the state
      switch (newState) {
        case 'DRAW':
          _handleDraw();
          break;
        case 'HOVER':
          _handleHover();
          break;
        case 'CLEAR':
          _handleClear();
          break;
      }

      // Update the UI
      setState(() {
        _currentState = newState;
      });

    } catch (e) {
      print("⚠️ Failed to parse JSON packet: $rawData\nError: $e");
    }
  }

  // 4. Action Handlers
  void _handleDraw() {
    // If we just started drawing, or are continuing a stroke, add the point
    _activeStroke.add(_cursorNorm);
  }

  void _handleHover() {
    // If we were drawing and just stopped, save the stroke to memory
    if (_activeStroke.isNotEmpty) {
      _completedStrokes.add(List.from(_activeStroke));
      _activeStroke.clear(); // Empty the active brush
    }
  }

  void _handleClear() {
    // Wipe everything
    _completedStrokes.clear();
    _activeStroke.clear();
    _currentState = 'HOVER';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent, // Keeps the desktop background visible
      body: Stack(
        children: [
          // The Drawing Canvas
          SizedBox.expand(
            child: CustomPaint(
              painter: AirCanvasPainter(
                completedStrokes: _completedStrokes,
                activeStroke: _activeStroke,
                cursorNorm: _cursorNorm,
                currentState: _currentState,
              ),
            ),
          ),
          
          // Debug UI (Optional: helps you see what the server is doing)
          Positioned(
            top: 20,
            left: 20,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black87,
              child: Text(
                "STATE: $_currentState\nCOORD: (${_cursorNorm.dx.toStringAsFixed(2)}, ${_cursorNorm.dy.toStringAsFixed(2)})",
                style: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontFamily: 'monospace'),
              ),
            ),
          )
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// The Canvas Rendering Engine
// ─────────────────────────────────────────────────────────────────────────────
class AirCanvasPainter extends CustomPainter {
  final List<List<Offset>> completedStrokes;
  final List<Offset> activeStroke;
  final Offset cursorNorm;
  final String currentState;

  AirCanvasPainter({
    required this.completedStrokes,
    required this.activeStroke,
    required this.cursorNorm,
    required this.currentState,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Pen Settings
    final Paint brush = Paint()
      ..color = Colors.redAccent
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    // Helper function to scale normalized coordinates (0.0 - 1.0) to screen pixels (e.g. 1920x1080)
    Offset toScreen(Offset norm) => Offset(norm.dx * size.width, norm.dy * size.height);

    // 1. Draw old memory strokes
    for (final stroke in completedStrokes) {
      _drawPath(canvas, stroke, brush, toScreen);
    }

    // 2. Draw the currently active stroke
    if (activeStroke.isNotEmpty) {
      _drawPath(canvas, activeStroke, brush, toScreen);
    }

    // 3. Draw the floating cursor reticle
    final Paint reticlePaint = Paint()
      ..color = currentState == 'DRAW' ? Colors.red : Colors.greenAccent
      ..style = PaintingStyle.fill;
      
    canvas.drawCircle(toScreen(cursorNorm), 8.0, reticlePaint);
  }

  void _drawPath(Canvas canvas, List<Offset> points, Paint paint, Offset Function(Offset) toScreen) {
    if (points.isEmpty) return;
    
    final path = Path();
    path.moveTo(toScreen(points.first).dx, toScreen(points.first).dy);
    
    for (int i = 1; i < points.length; i++) {
      path.lineTo(toScreen(points[i]).dx, toScreen(points[i]).dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant AirCanvasPainter oldDelegate) => true;
}