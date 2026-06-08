import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

class AirCanvasPage extends StatefulWidget {
  const AirCanvasPage({super.key});

  @override
  State<AirCanvasPage> createState() => _AirCanvasPageState();
}

class _AirCanvasPageState extends State<AirCanvasPage> {
  // 🚀 SHE MUST PUT YOUR NGROK WSS:// LINK HERE
  final String _wsUrl = 'wss://YOUR_CURRENT_NGROK_LINK.ngrok-free.dev';
  
  late WebSocketChannel _channel;
  
  List<List<Offset>> _completedStrokes = [];
  List<Offset> _activeStroke = [];
  Offset _cursorNorm = const Offset(0.5, 0.5);
  String _currentState = 'HOVER';

  @override
  void initState() {
    super.initState();
    _connectToServer();
  }

  void _connectToServer() {
    _channel = WebSocketChannel.connect(Uri.parse(_wsUrl));
    _channel.stream.listen((message) {
      final data = jsonDecode(message);
      
      setState(() {
        _currentState = data['state'];
        
        // Convert the [x, y] array from Python into a Flutter Offset
        if (data['coords'] != null) {
          double x = (data['coords'][0] as num).toDouble();
          double y = (data['coords'][1] as num).toDouble();
          _cursorNorm = Offset(x, y);
        }

        // Gesture Logic
        if (_currentState == 'CLEAR') {
          _completedStrokes.clear();
          _activeStroke.clear();
        } 
        else if (_currentState == 'DRAW') {
          _activeStroke.add(_cursorNorm);
        } 
        else if (_currentState == 'HOVER') {
          if (_activeStroke.isNotEmpty) {
            _completedStrokes.add(List.from(_activeStroke));
            _activeStroke.clear();
          }
        }
      });
    }, 
    onError: (error) => print("WebSocket Error: $error"),
    onDone: () => print("WebSocket Disconnected"));
  }

  @override
  void dispose() {
    _channel.sink.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    
    // Scale normalized coordinates (0.0 to 1.0) to her actual screen pixels
    Offset actualCursor = Offset(
      _cursorNorm.dx * screenSize.width,
      _cursorNorm.dy * screenSize.height,
    );

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // The Paint Canvas
          CustomPaint(
            size: screenSize,
            painter: CanvasPainter(_completedStrokes, _activeStroke),
          ),
          // The Tracking Reticle (Red for drawing, Green for hovering)
          if (_currentState != 'CLEAR')
            Positioned(
              left: actualCursor.dx - 10,
              top: actualCursor.dy - 10,
              child: Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(
                  color: _currentState == 'DRAW' ? Colors.red : Colors.greenAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _currentState == 'DRAW' ? Colors.redAccent : Colors.green,
                      blurRadius: 10,
                      spreadRadius: 2,
                    )
                  ]
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// 🎨 The Custom Painter that actually draws the lines
class CanvasPainter extends CustomPainter {
  final List<List<Offset>> completedStrokes;
  final List<Offset> activeStroke;

  CanvasPainter(this.completedStrokes, this.activeStroke);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.red
      ..strokeCap = StrokeCap.round
      ..strokeWidth = 6.0
      ..style = PaintingStyle.stroke;

    // Helper function to scale normalized points to screen size
    Offset scalePoint(Offset norm) => Offset(norm.dx * size.width, norm.dy * size.height);

    // Draw all finished lines
    for (var stroke in completedStrokes) {
      for (int i = 0; i < stroke.length - 1; i++) {
        canvas.drawLine(scalePoint(stroke[i]), scalePoint(stroke[i + 1]), paint);
      }
    }

    // Draw the line currently being drawn
    for (int i = 0; i < activeStroke.length - 1; i++) {
      canvas.drawLine(scalePoint(activeStroke[i]), scalePoint(activeStroke[i + 1]), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
