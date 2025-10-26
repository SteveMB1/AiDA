import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'main.dart';

class AnimatedSavingsCounter extends StatefulWidget {
  const AnimatedSavingsCounter({super.key});

  @override
  State<AnimatedSavingsCounter> createState() => _AnimatedSavingsCounterState();
}

class _AnimatedSavingsCounterState extends State<AnimatedSavingsCounter> {
  double _savings = 0.0;
  double _displayed = 0.0;
  String? _tooltipDescription;
  Timer? _timer;

  final _storage = const FlutterSecureStorage();

  @override
  void initState() {
    super.initState();
    _fetchSavings();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _fetchSavings());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _fetchSavings() async {
    final token = await _storage.read(key: 'access_token');
    if (token == null) return;

    final response = await http.get(
      Uri.parse('$urlEndPoint/savings/total/'),
      headers: {'Authorization': 'Bearer $token'},
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final newVal = (data['savings'] as num).toDouble();
      final description = data['description'] as String?;

      if (mounted) {
        setState(() {
          _tooltipDescription = description;
          _animateTo(newVal);
        });
      }
    }
  }

  void _animateTo(double target) {
    const duration = Duration(seconds: 1);
    const steps = 30;
    final stepDuration = duration ~/ steps;
    final delta = (target - _displayed) / steps;

    Timer.periodic(stepDuration, (t) {
      setState(() {
        _displayed += delta;
        if ((delta > 0 && _displayed >= target) ||
            (delta < 0 && _displayed <= target)) {
          _displayed = target;
          t.cancel();
        }
      });
    });

    _savings = target;
  }

  @override
  Widget build(BuildContext context) {
    final valueText = '\$${_displayed.toStringAsFixed(2)}';

    final cardContent = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: Colors.greenAccent.withOpacity(0.3), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.greenAccent.withOpacity(0.15),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: _tooltipDescription ??
                'Monthly savings based on instance cost changes.',
            child:
                const Icon(Icons.savings, color: Colors.greenAccent, size: 20),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Current\nYearly\nSavings',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white60,
                  fontWeight: FontWeight.w500,
                ),
              ),
              ShaderMask(
                shaderCallback: (bounds) => const LinearGradient(
                  colors: [Colors.greenAccent, Colors.lightGreenAccent],
                ).createShader(bounds),
                child: Text(
                  valueText,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                    shadows: [
                      Shadow(
                          color: Colors.black45,
                          blurRadius: 2,
                          offset: Offset(0, 1)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
        child: cardContent,
      ),
    );
  }
}
