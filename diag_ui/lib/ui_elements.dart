import 'dart:math' as math;
import 'dart:math';
import 'dart:ui' as ui;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// Six gear‑logo colours (sampled from the image you provided)
const List<Color> _logoColors = <Color>[
  Color(0xFF0A9ECD), // cyan‑blue
  Color(0xFF05B18D), // teal
  Color(0xFFBDD434), // lime‑green
  Color(0xFFF5573A), // red
  Color(0xFFF99418), // orange
  Color(0xFFFDA718), // yellow
];

/// A simple builder that just fades the new page in.
class FadePageTransitionsBuilder extends PageTransitionsBuilder {
  const FadePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return FadeTransition(
      opacity: animation,
      child: child,
    );
  }
}

/// Overlay of little satellites orbiting around screen center
class SatelliteOverlay extends StatefulWidget {
  const SatelliteOverlay({super.key});

  @override
  _SatelliteOverlayState createState() => _SatelliteOverlayState();
}

class _SatelliteOverlayState extends State<SatelliteOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final List<_Satellite> _sats;

  @override
  void initState() {
    super.initState();
    final rnd = Random();

    // create some random satellites
    _sats = List.generate(
      6,
      (_) => _Satellite(
        radiusNorm: 0.2 + rnd.nextDouble() * 0.3,
        // 20–50% of min(screenDim)
        speed: 0.3 + rnd.nextDouble() * 0.7,
        // 0.3–1.0 revs per cycle
        size: 2 + rnd.nextDouble() * 3, // 2–5 px
      ),
    );

    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _SatellitePainter(_ctrl.value, _sats),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _Satellite {
  final double radiusNorm; // fraction of min(width,height)
  final double speed; // revolutions per animation cycle
  final double size; // pixel radius

  _Satellite({
    required this.radiusNorm,
    required this.speed,
    required this.size,
  });
}

class _SatellitePainter extends CustomPainter {
  final double t; // 0–1 animation phase
  final List<_Satellite> sats;
  final Paint _orbitPaint = Paint()
    ..color = Colors.lightBlueAccent.withOpacity(0.1)
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  final Paint _satPaint = Paint()
    ..color = Colors.lightBlueAccent.withOpacity(0.8)
    ..style = PaintingStyle.fill;

  _SatellitePainter(this.t, this.sats);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final minDim = min(size.width, size.height);

    // draw faint orbit rings
    for (var sat in sats) {
      final r = sat.radiusNorm * minDim;
      canvas.drawCircle(center, r, _orbitPaint);
    }

    // draw satellites
    for (var sat in sats) {
      final angle = 2 * pi * (t * sat.speed);
      final r = sat.radiusNorm * minDim;
      final pos = Offset(
        center.dx + cos(angle) * r,
        center.dy + sin(angle) * r,
      );
      canvas.drawCircle(pos, sat.size, _satPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _SatellitePainter old) => true;
}

// ----------------------------------------------------------------------
// A colorfully animated background
// ----------------------------------------------------------------------
class AnimatedColorfulBackground extends StatefulWidget {
  const AnimatedColorfulBackground({super.key});

  @override
  State<AnimatedColorfulBackground> createState() =>
      _AnimatedColorfulBackgroundState();
}

class _AnimatedColorfulBackgroundState extends State<AnimatedColorfulBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  static const _bgColors = [
    Color(0xFFFF5F6D), // pinkish
    Color(0xFF3F5EFB), // bluish
    Color(0xFF00C9FF), // aqua
    Color(0xFF92FE9D), // light green
  ];

  @override
  void initState() {
    super.initState();
    // 12-second animation that reverses
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat(reverse: true);

    _animation = Tween<double>(begin: 0, end: 1).animate(_controller);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (ctx, child) {
        final middleStop1 = 0.3 + 0.2 * _animation.value;
        final middleStop2 = 0.6 + 0.2 * (1 - _animation.value);
        return Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _bgColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              stops: [
                0.0,
                middleStop1,
                middleStop2,
                1.0,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Animated space scene with drifting, twinkling stars + occasional shooting stars
class AnimatedSpaceBackground extends StatefulWidget {
  const AnimatedSpaceBackground({super.key});

  @override
  _AnimatedSpaceBackgroundState createState() =>
      _AnimatedSpaceBackgroundState();
}

class _AnimatedSpaceBackgroundState extends State<AnimatedSpaceBackground>
    with TickerProviderStateMixin {
  late final AnimationController _twinkleCtl;
  late final AnimationController _moveCtl;
  late final AnimationController _shootCtl;
  final List<_Star> _stars = List.generate(150, (_) => _Star.random());
  _ShootingStar? _shooting;

  @override
  void initState() {
    super.initState();

    // controls twinkle speed
    _twinkleCtl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);

    // controls star drift across screen
    _moveCtl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 15),
    )..repeat();

    // controls shooting star animation
    _shootCtl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );

    // periodically launch shooting stars
    _launchShootingStars();
  }

  Future<void> _launchShootingStars() async {
    final rnd = Random();
    while (mounted) {
      await Future.delayed(Duration(seconds: 5 + rnd.nextInt(5)));
      if (!mounted) break;
      _shooting = _ShootingStar.random();
      _shootCtl.forward(from: 0);
      await Future.delayed(_shootCtl.duration!);
    }
  }

  @override
  void dispose() {
    _twinkleCtl.dispose();
    _moveCtl.dispose();
    _shootCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // background image
        Positioned.fill(
          child: Image.asset(
            'assets/background.jpg',
            fit: BoxFit.cover,
          ),
        ),
        // dark overlay
        Positioned.fill(
          child: Container(color: Colors.black.withOpacity(0.5)),
        ),
        // stars + shooting star
        Positioned.fill(
          child: AnimatedBuilder(
            animation: Listenable.merge([_twinkleCtl, _moveCtl, _shootCtl]),
            builder: (_, __) {
              return CustomPaint(
                painter: _SpacePainter(
                  stars: _stars,
                  twinklePhase: _twinkleCtl.value,
                  movePhase: _moveCtl.value,
                  shooting: _shooting,
                  shootingPhase: _shootCtl.value,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Star {
  final Offset basePos;
  final Offset velocity;
  final double radius;
  final Color color;

  _Star(this.basePos, this.velocity, this.radius, this.color);

  factory _Star.random() {
    final rnd = Random();
    // random starting point
    final base = Offset(rnd.nextDouble(), rnd.nextDouble());
    // small random drift direction & speed
    final angle = rnd.nextDouble() * 2 * pi;
    final speed = 0.02 + rnd.nextDouble() * 0.03; // normalized per 60s
    final vel = Offset(cos(angle) * speed, sin(angle) * speed);
    return _Star(
      base,
      vel,
      0.5 + rnd.nextDouble() * 1.2,
      Colors.white.withOpacity(0.6 + rnd.nextDouble() * 0.4),
    );
  }
}

class _ShootingStar {
  final Offset start, end;

  _ShootingStar(this.start, this.end);

  factory _ShootingStar.random() {
    final rnd = Random();
    // start somewhere near top
    final sx = rnd.nextDouble();
    final sy = rnd.nextDouble() * 0.3;
    // end somewhere near bottom/right
    final ex = rnd.nextDouble();
    final ey = 0.7 + rnd.nextDouble() * 0.3;
    return _ShootingStar(Offset(sx, sy), Offset(ex, ey));
  }
}

class _SpacePainter extends CustomPainter {
  final List<_Star> stars;
  final double twinklePhase;
  final double movePhase;
  final _ShootingStar? shooting;
  final double shootingPhase;

  _SpacePainter({
    required this.stars,
    required this.twinklePhase,
    required this.movePhase,
    this.shooting,
    required this.shootingPhase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    // draw drifting, twinkling stars
    for (final star in stars) {
      // compute wrapped position
      var dx = (star.basePos.dx + star.velocity.dx * movePhase) % 1.0;
      var dy = (star.basePos.dy + star.velocity.dy * movePhase) % 1.0;
      if (dx < 0) dx += 1.0;
      if (dy < 0) dy += 1.0;

      // twinkle scale
      final scale = 0.7 + 0.3 * sin(twinklePhase * 2 * pi + star.radius);
      paint.color = star.color;
      canvas.drawCircle(
        Offset(dx * size.width, dy * size.height),
        star.radius * scale,
        paint,
      );
    }

    // draw shooting star
    if (shooting != null && shootingPhase < 1.0) {
      final p = shootingPhase;
      final x =
          lerpDouble(shooting!.start.dx, shooting!.end.dx, p)! * size.width;
      final y =
          lerpDouble(shooting!.start.dy, shooting!.end.dy, p)! * size.height;
      paint.shader = const RadialGradient(
        colors: [Colors.white, Colors.transparent],
      ).createShader(Rect.fromCircle(center: Offset(x, y), radius: 8));
      canvas.drawCircle(Offset(x, y), 4 + 6 * (1 - p), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SpacePainter old) => true;
}

// Reusable glass‑morphic dropdown
class GlassDropdown<T> extends StatefulWidget {
  final String label;
  final IconData icon;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  const GlassDropdown({
    super.key,
    required this.label,
    required this.icon,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  @override
  State<GlassDropdown<T>> createState() => _GlassDropdownState<T>();
}

class _GlassDropdownState<T> extends State<GlassDropdown<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              colors: [
                Colors.white.withOpacity(_hover ? 0.15 : 0.10),
                Colors.white.withOpacity(_hover ? 0.05 : 0.03),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(_hover ? 0.3 : 0.15),
                blurRadius: _hover ? 12 : 6,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: DropdownButtonFormField<T>(
                dropdownColor: Colors.black.withOpacity(0.8),
                icon: const Icon(Icons.arrow_drop_down, color: Colors.white70),
                isExpanded: true,
                value: widget.value,
                items: widget.items,
                onChanged: widget.onChanged,
                decoration: InputDecoration(
                  prefixIcon: Icon(widget.icon, color: Colors.white70),
                  labelText: widget.label,
                  labelStyle: GoogleFonts.lato(color: Colors.white70),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 8),
                ),
                style: GoogleFonts.lato(color: Colors.white),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// 1) Add this FadeInPage widget anywhere above your AidaApp:
class FadeInPage extends StatefulWidget {
  final Widget child;
  final Duration duration;

  const FadeInPage({
    super.key,
    required this.child,
    this.duration = const Duration(milliseconds: 800),
  });

  @override
  _FadeInPageState createState() => _FadeInPageState();
}

class _FadeInPageState extends State<FadeInPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: widget.duration,
    );
    _anim = CurvedAnimation(parent: _ctrl, curve: Curves.easeIn);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(opacity: _anim, child: widget.child);
  }
}

class LogoLinearProgressIndicator extends StatelessWidget {
  /// If [value] is non-null, draws a determinate bar; otherwise indeterminate.
  final double? value;

  const LogoLinearProgressIndicator({super.key, this.value});

  @override
  Widget build(BuildContext context) {
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return const LinearGradient(
          colors: _logoColors,
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
        ).createShader(bounds);
      },
      // we paint the gradient into the filled portion of a white progress bar
      child: LinearProgressIndicator(
        value: value,
        backgroundColor: Colors.white12,
        // the `ShaderMask` will recolor whatever the child draws,
        // so here we force it to draw in white…
        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
      ),
    );
  }
}

class LogoCircularProgressIndicator extends StatefulWidget {
  /// If non-null, draws a determinate indicator [0..1]. Otherwise spins indefinitely.
  final double? value;

  /// Diameter of the widget.
  final double size;

  /// Thickness of the progress stroke.
  final double strokeWidth;

  const LogoCircularProgressIndicator({
    super.key,
    this.value,
    this.size = 40.0,
    this.strokeWidth = 4.0,
  });

  @override
  _LogoCircularProgressIndicatorState createState() =>
      _LogoCircularProgressIndicatorState();
}

class _LogoCircularProgressIndicatorState
    extends State<LogoCircularProgressIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    // Only animate rotation when indeterminate
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    );
    if (widget.value == null) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant LogoCircularProgressIndicator old) {
    super.didUpdateWidget(old);
    // start/stop animation if switching between determinate & indeterminate
    if (widget.value == null && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.value != null && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          // rotation from 0 to 2π
          final rotation = _controller.value * 2 * math.pi;
          return CustomPaint(
            painter: _LogoCirclePainter(
              progress: widget.value,
              rotation: rotation,
              strokeWidth: widget.strokeWidth,
            ),
          );
        },
      ),
    );
  }
}

class _LogoCirclePainter extends CustomPainter {
  final double? progress;
  final double rotation;
  final double strokeWidth;

  _LogoCirclePainter({
    required this.progress,
    required this.rotation,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (size.shortestSide - strokeWidth) / 2;

    // Draw background circle
    final bgPaint = Paint()
      ..color = Colors.white12
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth;
    canvas.drawCircle(center, radius, bgPaint);

    // Sweep gradient shader with rotation
    final rect = Rect.fromCircle(center: center, radius: radius);
    final gradient = SweepGradient(
      startAngle: 0.0,
      endAngle: math.pi * 2,
      colors: _logoColors,
      transform: GradientRotation(rotation),
    ).createShader(rect);

    final fgPaint = Paint()
      ..shader = gradient
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = strokeWidth;

    // Determine sweep angle: full circle for indeterminate, or fraction for determinate
    final sweep = (progress != null)
        ? (progress!.clamp(0.0, 1.0) * 2 * math.pi)
        : 2 * math.pi;

    // Start at top (-π/2)
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      fgPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _LogoCirclePainter old) {
    return old.progress != progress ||
        old.rotation != rotation ||
        old.strokeWidth != strokeWidth;
  }
}
