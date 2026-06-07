// lib/canvas_page.dart
// ─────────────────────────────────────────────────────────────────────────────
// Core overlay widget.  Responsibilities:
//   1. Establish and maintain a WebSocket connection to Developer A's Python
//      server at ws://localhost:8765 with auto-reconnect.
//   2. Parse the JSON data contract:
//          { "state": "HOVER"|"DRAW"|"CLEAR"|"SWIPE_L"|"SWIPE_R",
//            "coords": [x_pct, y_pct] }        // 0.0–1.0 normalised
//   3. Scale normalised coords to real screen pixels.
//   4. Delegate rendering to AirCanvasPainter (CustomPainter):
//          • HOVER  → small green tracking reticle (crosshair)
//          • DRAW   → accumulate points, draw smooth anti-aliased stroke(s)
//          • CLEAR  → wipe all stroke data
//   5. Forward SWIPE_L / SWIPE_R to the native Win32 layer via MethodChannel
//      so the C++ code can synthesise VK_LEFT / VK_RIGHT key presses.
// ─────────────────────────────────────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as ws_status;

// ── Constants ─────────────────────────────────────────────────────────────────

// WebSocket endpoint broadcast by Developer A's Python MediaPipe server.
const String _kWsUrl = 'ws://localhost:8765';

// How long to wait before trying to reconnect after a dropped connection.
const Duration _kReconnectDelay = Duration(seconds: 2);

// Reticle radius in logical pixels.
const double _kReticleRadius = 14.0;

// Minimum distance between successive draw points to avoid overdraw.
const double _kMinPointDistance = 2.0;

// Stroke smoothing: we store raw points and use quadratic bezier splines.
// Number of points to keep in a single "stroke segment" before starting fresh.
const int _kMaxSegmentLength = 512;

// ─────────────────────────────────────────────────────────────────────────────

/// A single continuous stroke composed of one or more segments.
/// Each inner list is a sequence of [Offset] points captured while the
/// hand was in the DRAW state without interruption.
typedef Stroke = List<List<Offset>>;

// ─────────────────────────────────────────────────────────────────────────────

class CanvasPage extends StatefulWidget {
  final String automationChannelName;

  const CanvasPage({super.key, required this.automationChannelName});

  @override
  State<CanvasPage> createState() => _CanvasPageState();
}

class _CanvasPageState extends State<CanvasPage> {
  // ── MethodChannel to Win32 native layer ──────────────────────────────────
  late final MethodChannel _automationChannel;

  // ── WebSocket state ───────────────────────────────────────────────────────
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  bool _isConnected = false;
  Timer? _reconnectTimer;

  // ── Canvas drawing state ──────────────────────────────────────────────────
  /// All completed strokes (each a list of segments).
  final List<Stroke> _strokes = [];

  /// The stroke currently being drawn.
  Stroke _activeStroke = [];

  /// The latest normalised cursor position.
  Offset _cursorNorm = Offset.zero;

  /// Current gesture state received from Developer A.
  String _currentState = 'HOVER';

  // ─────────────────────────────────────────────────────────────────────────

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

  // ── WebSocket connection management ───────────────────────────────────────

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
      debugPrint('[AirCanvas] WebSocket connected.');
    } catch (e) {
      debugPrint('[AirCanvas] Connection error: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    setState(() => _isConnected = false);
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_kReconnectDelay, _connect);
    debugPrint('[AirCanvas] Reconnecting in ${_kReconnectDelay.inSeconds}s …');
  }

  void _onError(Object error) {
    debugPrint('[AirCanvas] WebSocket error: $error');
    _scheduleReconnect();
  }

  void _onDone() {
    debugPrint('[AirCanvas] WebSocket closed by server.');
    _scheduleReconnect();
  }

  // ── Incoming data handler ─────────────────────────────────────────────────

  void _onData(dynamic raw) {
    // Guard: raw should be a String from a text WebSocket frame.
    if (raw is! String) return;

    late Map<String, dynamic> packet;
    try {
      packet = json.decode(raw) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[AirCanvas] JSON parse error: $e  |  raw: $raw');
      return;
    }

    final String state = (packet['state'] as String? ?? 'HOVER').toUpperCase();
    final List<dynamic>? coordsRaw = packet['coords'] as List<dynamic>?;

    // Normalised cursor (0.0–1.0); default to last known position on null.
    final Offset cursorNorm = coordsRaw != null && coordsRaw.length == 2
        ? Offset(
            (coordsRaw[0] as num).toDouble().clamp(0.0, 1.0),
            (coordsRaw[1] as num).toDouble().clamp(0.0, 1.0),
          )
        : _cursorNorm;

    // ── State machine ───────────────────────────────────────────────────────
    switch (state) {
      case 'HOVER':
        _handleHover(cursorNorm);
        break;
      case 'DRAW':
        _handleDraw(cursorNorm);
        break;
      case 'CLEAR':
        _handleClear();
        break;
      case 'SWIPE_L':
        _handleSwipe(left: true);
        break;
      case 'SWIPE_R':
        _handleSwipe(left: false);
        break;
      default:
        debugPrint('[AirCanvas] Unknown state: $state');
    }
  }

  // ── Individual state handlers ─────────────────────────────────────────────

  void _handleHover(Offset norm) {
    // If we were drawing, seal the active stroke.
    if (_currentState == 'DRAW' && _activeStroke.isNotEmpty) {
      _strokes.add(List.from(_activeStroke));
      _activeStroke = [];
    }
    setState(() {
      _cursorNorm = norm;
      _currentState = 'HOVER';
    });
  }

  void _handleDraw(Offset norm) {
    setState(() {
      _cursorNorm = norm;
      _currentState = 'DRAW';

      if (_activeStroke.isEmpty) {
        // Begin a fresh stroke segment list.
        _activeStroke = [
          [_toScreen(norm)]
        ];
      } else {
        final List<Offset> currentSegment = _activeStroke.last;
        final Offset screenPt = _toScreen(norm);

        // Skip point if too close to the last (avoids noise artefacts).
        if (currentSegment.isEmpty ||
            (screenPt - currentSegment.last).distance >= _kMinPointDistance) {
          if (currentSegment.length >= _kMaxSegmentLength) {
            // Start a new segment, seeding it with the last point for continuity.
            _activeStroke.add([currentSegment.last, screenPt]);
          } else {
            currentSegment.add(screenPt);
          }
        }
      }
    });
  }

  void _handleClear() {
    setState(() {
      _strokes.clear();
      _activeStroke = [];
      _currentState = 'HOVER';
    });
    debugPrint('[AirCanvas] Canvas cleared.');
  }

  Future<void> _handleSwipe({required bool left}) async {
    // Seal any active stroke before the slide transition.
    if (_activeStroke.isNotEmpty) {
      _strokes.add(List.from(_activeStroke));
      _activeStroke = [];
    }
    _handleClear(); // Clear canvas on slide change (common UX expectation).

    final String method = left ? 'swipeLeft' : 'swipeRight';
    debugPrint('[AirCanvas] Invoking native channel → $method');
    try {
      await _automationChannel.invokeMethod<void>(method);
    } on PlatformException catch (e) {
      debugPrint('[AirCanvas] MethodChannel error: ${e.message}');
    }
  }

  // ── Coordinate helper ─────────────────────────────────────────────────────

  /// Convert normalised [0, 1] coordinates to physical screen pixels.
  Offset _toScreen(Offset norm) {
    final Size screen = _screenSize;
    return Offset(norm.dx * screen.width, norm.dy * screen.height);
  }

  Size get _screenSize {
    // Prefer the physical display size; fall back to window size.
    final FlutterView view =
        WidgetsBinding.instance.platformDispatcher.views.first;
    final Size physical = view.physicalSize;
    final double dpr = view.devicePixelRatio;
    return dpr > 0 ? physical / dpr : const Size(1920, 1080);
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // ── Main drawing canvas ──────────────────────────────────────────
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

          // ── Connection status badge (top-left, semi-transparent) ─────────
          Positioned(
            top: 16,
            left: 16,
            child: _ConnectionBadge(isConnected: _isConnected),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// AirCanvasPainter
// ─────────────────────────────────────────────────────────────────────────────
/// Renders all completed strokes, the currently active stroke, and the
/// cursor reticle onto a transparent canvas layer.
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
    // ── Draw all committed strokes ──────────────────────────────────────────
    for (final Stroke stroke in strokes) {
      _drawStroke(canvas, stroke, committed: true);
    }

    // ── Draw the active (in-progress) stroke ────────────────────────────────
    if (activeStroke.isNotEmpty) {
      _drawStroke(canvas, activeStroke, committed: false);
    }

    // ── Draw the cursor reticle ──────────────────────────────────────────────
    final Offset cursor = Offset(
      cursorNorm.dx * size.width,
      cursorNorm.dy * size.height,
    );
    _drawReticle(canvas, cursor);
  }

  // ── Stroke rendering ───────────────────────────────────────────────────────

  void _drawStroke(Canvas canvas, Stroke stroke, {required bool committed}) {
    // Committed strokes are slightly faded; active is full opacity.
    final Paint strokePaint = Paint()
      ..color = committed
          ? const Color(0xCCFF4444) // soft red, slightly transparent
          : const Color(0xFFFF4444) // full red while drawing
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (final List<Offset> segment in stroke) {
      if (segment.length < 2) {
        // Single point – draw a dot.
        if (segment.length == 1) {
          canvas.drawCircle(segment.first, strokePaint.strokeWidth / 2,
              strokePaint..style = PaintingStyle.fill);
          strokePaint.style = PaintingStyle.stroke;
        }
        continue;
      }

      // Smooth the segment using quadratic Bézier splines.
      final Path path = _buildSmoothPath(segment);
      canvas.drawPath(path, strokePaint);
    }
  }

  /// Builds a smooth [Path] through [points] using midpoint quadratic Béziers.
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

    // Close to the last point.
    path.lineTo(points.last.dx, points.last.dy);
    return path;
  }

  // ── Reticle rendering ──────────────────────────────────────────────────────

  void _drawReticle(Canvas canvas, Offset center) {
    final bool isDrawing = currentState == 'DRAW';

    // ── Outer ring ──────────────────────────────────────────────────────────
    final Paint ringPaint = Paint()
      ..color = isDrawing
          ? const Color(0xCCFF4444) // red when drawing
          : const Color(0xCC44FF88) // green when hovering
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    canvas.drawCircle(center, _kReticleRadius, ringPaint);

    // ── Inner dot ───────────────────────────────────────────────────────────
    final Paint dotPaint = Paint()
      ..color = isDrawing
          ? const Color(0xFFFF4444)
          : const Color(0xFF44FF88)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    canvas.drawCircle(center, 3.0, dotPaint);

    // ── Crosshair lines ──────────────────────────────────────────────────────
    final double arm = _kReticleRadius + 6.0;
    final Paint crossPaint = Paint()
      ..color = (isDrawing
              ? const Color(0xCCFF4444)
              : const Color(0xCC44FF88))
          .withOpacity(0.6)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    // Horizontal
    canvas.drawLine(
        Offset(center.dx - arm, center.dy), Offset(center.dx + arm, center.dy), crossPaint);
    // Vertical
    canvas.drawLine(
        Offset(center.dx, center.dy - arm), Offset(center.dx, center.dy + arm), crossPaint);
  }

  @override
  bool shouldRepaint(AirCanvasPainter old) {
    // Repaint whenever any state changes.
    return old.strokes != strokes ||
        old.activeStroke != activeStroke ||
        old.cursorNorm != cursorNorm ||
        old.currentState != currentState;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// _ConnectionBadge
// ─────────────────────────────────────────────────────────────────────────────
/// Small always-visible badge showing WebSocket connection health.
/// Useful when debugging; it doesn't interfere with the presentation because
/// it's in the top-left corner and is semi-transparent.
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
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isConnected ? const Color(0xFF44FF88) : const Color(0xFFFF5555),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            isConnected ? 'CV Connected' : 'Waiting for CV…',
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 11,
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }
}
