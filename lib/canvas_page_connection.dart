// lib/canvas_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

// ── Constants ─────────────────────────────────────────────────────────────────

// 🧪 TEST OVERRIDE: Swapped localhost for your live global Ngrok tunnel
const String _kWsUrl = 'wss://chafe-sake-stipulate.ngrok-free.dev';

const Duration _kReconnectDelay = Duration(seconds: 2);
const double _kReticleRadius = 14.0;
const double _kMinPointDistance = 2.0;
const int _kMaxSegmentLength = 512;

typedef Stroke = List<List<Offset>>;

class CanvasPage extends StatefulWidget {
  final String automationChannelName;
  const CanvasPage({super.key, required this.automationChannelName});

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

class _CanvasPageState extends State<CanvasPage> {
  late final MethodChannel _automationChannel;
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _isConnected = false;
  Timer? _reconnectTimer;

  final List<Stroke> _strokes = [];
  Stroke _activeStroke = [];
  Offset _cursorNorm = Offset.zero;
  String _currentState = 'HOVER';

  // 🧪 TEST OVERRIDE: Variable to hold your Python string message
  String _liveServerMessage = 'Waiting for Python data...';

  @override
  void initState() {
    super.initState();
    _automationChannel = MethodChannel(widget.automationChannelName);
    _connect();
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    _subscription?.cancel();
    _channel?.sink.close(ws_status.goingAway);
    super.dispose();
  }

  void _connect() {
    debugPrint('[AirCanvas] Connecting to $_kWsUrl …');
    try {
      _channel = WebSocketChannel.connect(Uri.parse(_kWsUrl));
      _subscription = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
        cancelOnError: false,
      );
      setState(() => _isConnected = true);
    } catch (e) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    setState(() => _isConnected = false);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_kReconnectDelay, _connect);
  }

  void _onError(Object error) => _scheduleReconnect();
  void _onDone() => _scheduleReconnect();

  void _onData(dynamic raw) {
    if (raw is! String) return;

    // 🧪 TEST OVERRIDE: Instantly save the raw string from Python to update the UI
    setState(() {
      _liveServerMessage = raw;
    });

    late Map<String, dynamic> packet;
    try {
      // This will fail silently because Python is sending plain text, not JSON yet.
      // That is completely fine for this test!
      packet = json.decode(raw) as Map<String, dynamic>;
    } catch (e) {
      return; // Skip drawing logic since we don't have valid coordinates yet
    }

    final String state = (packet['state'] as String? ?? 'HOVER').toUpperCase();
    final List<dynamic>? coordsRaw = packet['coords'] as List<dynamic>?;

    final Offset cursorNorm = coordsRaw != null && coordsRaw.length == 2
        ? Offset(
            (coordsRaw[0] as num).toDouble().clamp(0.0, 1.0),
            (coordsRaw[1] as num).toDouble().clamp(0.0, 1.0),
          )
        : _cursorNorm;

    switch (state) {
      case 'HOVER': _handleHover(cursorNorm); break;
      case 'DRAW': _handleDraw(cursorNorm); break;
      case 'CLEAR': _handleClear(); break;
      case 'SWIPE_L': _handleSwipe(left: true); break;
      case 'SWIPE_R': _handleSwipe(left: false); break;
    }
  }

  void _handleHover(Offset norm) {
    if (_currentState == 'DRAW' && _activeStroke.isNotEmpty) {
      _strokes.add(List.from(_activeStroke));
      _activeStroke = [];
    }
    setState(() { _cursorNorm = norm; _currentState = 'HOVER'; });
  }

  void _handleDraw(Offset norm) {
    setState(() {
      _cursorNorm = norm;
      _currentState = 'DRAW';
      if (_activeStroke.isEmpty) {
        _activeStroke = [[_toScreen(norm)]];
      } else {
        final List<Offset> currentSegment = _activeStroke.last;
        final Offset screenPt = _toScreen(norm);
        if (currentSegment.isEmpty || (screenPt - currentSegment.last).distance >= _kMinPointDistance) {
          if (currentSegment.length >= _kMaxSegmentLength) {
            _activeStroke.add([currentSegment.last, screenPt]);
          } else {
            currentSegment.add(screenPt);
          }
        }
      }
    });
  }

  void _handleClear() {
    setState(() { _strokes.clear(); _activeStroke = []; _currentState = 'HOVER'; });
  }

  Future<void> _handleSwipe({required bool left}) async {
    if (_activeStroke.isNotEmpty) {
      _strokes.add(List.from(_activeStroke));
      _activeStroke = [];
    }
    _handleClear();
  }

  Offset _toScreen(Offset norm) {
    final Size screen = _screenSize;
    return Offset(norm.dx * screen.width, norm.dy * screen.height);
  }

  Size get _screenSize {
    final FlutterView view = WidgetsBinding.instance.platformDispatcher.views.first;
    final Size physical = view.physicalSize;
    final double dpr = view.devicePixelRatio;
    return dpr > 0 ? physical / dpr : const Size(1920, 1080);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          RepaintBoundary(
            child: CustomPaint(
              painter: AirCanvasPainter(
                strokes: _strokes,
                activeStroke: _activeStroke,
                cursorNorm: _cursorNorm,
                currentState: _currentState,
                screenSize: _screenSize,
              ),
              size: Size.infinite,
            ),
          ),
          Positioned(
            top: 16,
            left: 16,
            child: _ConnectionBadge(isConnected: _isConnected),
          ),
          
          // 🧪 TEST OVERRIDE: A massive visual box in the bottom center to prove data is flowing
          if (_isConnected)
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 60.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.amber, width: 2),
                  ),
                  child: Text(
                    _liveServerMessage,
                    style: const TextStyle(
                      color: Colors.amber, 
                      fontSize: 20, 
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// (The rest of her code: AirCanvasPainter and _ConnectionBadge remain exactly the same!)

class AirCanvasPainter extends CustomPainter {
  final List<Stroke> strokes;
  final Stroke activeStroke;
  final Offset cursorNorm;
  final String currentState;
  final Size screenSize;

  const AirCanvasPainter({
    required this.strokes,
    required this.activeStroke,
    required this.cursorNorm,
    required this.currentState,
    required this.screenSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final Stroke stroke in strokes) {
      _drawStroke(canvas, stroke, committed: true);
    }
    if (activeStroke.isNotEmpty) {
      _drawStroke(canvas, activeStroke, committed: false);
    }
    final Offset cursor = Offset(
      cursorNorm.dx * size.width,
      cursorNorm.dy * size.height,
    );
    _drawReticle(canvas, cursor);
  }

  void _drawStroke(Canvas canvas, Stroke stroke, {required bool committed}) {
    final Paint strokePaint = Paint()
      ..color = committed ? const Color(0xCCFF4444) : const Color(0xFFFF4444)
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (final List<Offset> segment in stroke) {
      if (segment.length < 2) {
        if (segment.length == 1) {
          canvas.drawCircle(segment.first, strokePaint.strokeWidth / 2, strokePaint..style = PaintingStyle.fill);
          strokePaint.style = PaintingStyle.stroke;
        }
        continue;
      }
      final Path path = _buildSmoothPath(segment);
      canvas.drawPath(path, strokePaint);
    }
  }

  Path _buildSmoothPath(List<Offset> points) {
    final Path path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    if (points.length == 2) {
      path.lineTo(points[1].dx, points[1].dy);
      return path;
    }
    for (int i = 0; i < points.length - 1; i++) {
      final Offset p0 = points[i];
      final Offset p1 = points[i + 1];
      final Offset mid = Offset((p0.dx + p1.dx) / 2, (p0.dy + p1.dy) / 2);
      if (i == 0) {
        path.lineTo(mid.dx, mid.dy);
      } else {
        path.quadraticBezierTo(p0.dx, p0.dy, mid.dx, mid.dy);
      }
    }
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  void _drawReticle(Canvas canvas, Offset center) {
    final bool isDrawing = currentState == 'DRAW';
    final Paint ringPaint = Paint()
      ..color = isDrawing ? const Color(0xCCFF4444) : const Color(0xCC44FF88)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    canvas.drawCircle(center, _kReticleRadius, ringPaint);

    final Paint dotPaint = Paint()
      ..color = isDrawing ? const Color(0xFFFF4444) : const Color(0xFF44FF88)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    canvas.drawCircle(center, 3.0, dotPaint);

    final double arm = _kReticleRadius + 6.0;
    final Paint crossPaint = Paint()
      ..color = (isDrawing ? const Color(0xCCFF4444) : const Color(0xCC44FF88)).withOpacity(0.6)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    canvas.drawLine(Offset(center.dx - arm, center.dy), Offset(center.dx + arm, center.dy), crossPaint);
    canvas.drawLine(Offset(center.dx, center.dy - arm), Offset(center.dx, center.dy + arm), crossPaint);
  }

  @override
  bool shouldRepaint(AirCanvasPainter old) {
    return old.strokes != strokes || old.activeStroke != activeStroke || old.cursorNorm != cursorNorm || old.currentState != currentState;
  }
}

class _ConnectionBadge extends StatelessWidget {
  final bool isConnected;
  const _ConnectionBadge({required this.isConnected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isConnected ? const Color(0xFF44FF88) : const Color(0xFFFF5555),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'CV Connected' : 'Waiting for CV…',
            style: const TextStyle(color: Colors.white70, fontSize: 11, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }
}
