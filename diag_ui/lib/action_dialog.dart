import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

enum DialogType { error, success }

/// Mind‑blowing glass‑morphic dialog with flawless typography and no unwanted underlines.
Future<void> showGlassMorphicDialog({
  required BuildContext context,
  required String message,
  required DialogType type,
}) {
  final title = type == DialogType.error ? 'Oops!' : 'Yay!';
  final icon =
      type == DialogType.error ? Icons.error_outline : Icons.check_circle;
  final accent =
      type == DialogType.error ? Colors.redAccent : Colors.greenAccent;

  return showGeneralDialog(
    context: context,
    barrierLabel: 'GlassDialog',
    barrierDismissible: true,
    transitionDuration: const Duration(milliseconds: 400),
    pageBuilder: (_, __, ___) => Center(
      child: GlassMorphicDialog(
        title: title,
        message: message,
        icon: icon,
        accentColor: accent,
      ),
    ),
    transitionBuilder: (_, anim, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: anim, curve: Curves.easeOut),
      child: ScaleTransition(
        scale: Tween(begin: 0.75, end: 1.0).animate(
          CurvedAnimation(parent: anim, curve: Curves.elasticOut),
        ),
        child: child,
      ),
    ),
  );
}

class GlassMorphicDialog extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;
  final Color accentColor;

  const GlassMorphicDialog({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(24),
      child: BackdropFilter(
        // Blur is applied immediately with no lag
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.8,
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Colors.white.withOpacity(0.2),
                Colors.white.withOpacity(0.05),
              ],
            ),
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: Colors.white.withOpacity(0.3), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 20,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedIconWidget(icon: icon, color: accentColor),
              const SizedBox(height: 16),
              Text(
                title,
                style: GoogleFonts.poppins(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: accentColor,
                  decoration: TextDecoration.none,
                  shadows: [
                    Shadow(
                      blurRadius: 8,
                      color: accentColor.withOpacity(0.6),
                      offset: const Offset(0, 0),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 18,
                  color: Colors.white.withOpacity(0.9),
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 24),
              GlassButton(
                text: 'Close',
                color: accentColor,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class GlassButton extends StatefulWidget {
  final String text;
  final Color color;
  final VoidCallback onPressed;

  const GlassButton({
    super.key,
    required this.text,
    required this.color,
    required this.onPressed,
  });

  @override
  _GlassButtonState createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapUp: (_) {
        widget.onPressed();
        setState(() => _pressed = false);
      },
      onTapCancel: () => setState(() => _pressed = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 28),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              widget.color.withOpacity(_pressed ? 0.6 : 0.4),
              widget.color.withOpacity(_pressed ? 0.4 : 0.2),
            ],
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withOpacity(0.5), width: 1),
        ),
        child: Text(
          widget.text,
          style: GoogleFonts.poppins(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
            letterSpacing: 1.1,
            decoration: TextDecoration.none,
          ),
        ),
      ),
    );
  }
}

class AnimatedIconWidget extends StatefulWidget {
  final IconData icon;
  final Color color;

  const AnimatedIconWidget({super.key, required this.icon, required this.color});

  @override
  _AnimatedIconWidgetState createState() => _AnimatedIconWidgetState();
}

class _AnimatedIconWidgetState extends State<AnimatedIconWidget>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 800),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: Tween(begin: 0.8, end: 1.2).animate(
        CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut),
      ),
      child: Icon(widget.icon, size: 70, color: widget.color, shadows: [
        Shadow(
          blurRadius: 12,
          color: widget.color.withOpacity(0.7),
          offset: const Offset(0, 0),
        ),
      ]),
    );
  }
}
