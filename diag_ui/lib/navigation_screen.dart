import 'dart:convert';
import 'dart:ui';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'main.dart';

class AidaPalette {
  static const Color primary = Color(0xFF00ACC1);
  static const Color surface = Color(0xFF2A2F38);
  static const Color onPrimary = Color(0xFFFFFFFF);
  static const Color onSurface = Color(0xFFEFEFEF);
  static const Color secondary = Color(0xFF80DEEA);
  static const Color error = Color(0xFFE53935);
}

/// Model for /me/ response
class UserProfile {
  final String name;
  final String email;

  UserProfile({required this.name, required this.email});

  factory UserProfile.fromJson(Map<String, dynamic> json) {
    // json['name'] is actually a Map, so pull out first/last:
    final nameMap = json['name'] as Map<String, dynamic>;
    final fullName = '${nameMap['first']} ${nameMap['last']}';

    // email comes back in “sub”
    final email = json['sub'] as String;

    return UserProfile(
      name: fullName,
      email: email,
    );
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  _DashboardPageState createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  late Future<UserProfile> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = _fetchProfile();
  }

  Future<UserProfile> _fetchProfile() async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null) throw Exception('No token');
    final resp = await http.get(
      Uri.parse('$urlEndPoint/me/'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json'
      },
    );
    final decoded = jsonDecode(resp.body) as Map<String, dynamic>;
    if (resp.statusCode == 200) return UserProfile.fromJson(decoded);
    await storage.delete(key: 'access_token');
    Future.microtask(() {
      if (mounted) {
        navigatorKey.currentState
            ?.pushNamedAndRemoveUntil('/login', (_) => false);
      }
    });
    throw Exception('Invalid token');
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      const _DashboardItem(
          'Monitoring Status', Icons.analytics_outlined, '/status'),
      const _DashboardItem(
          'Scale Recommendations', Icons.speed, '/scale-recommendations'),
      const _DashboardItem('AI Diagnostics', Icons.memory, '/diagnostics'),
      if (kIsWeb)
        const _DashboardItem('Chat', Icons.chat_bubble_outline, '/chat'),
      const _DashboardItem('Logout', Icons.logout, '/login', isLogout: true),
    ];
    String initials(String name) {
      final parts = name.split(' ');
      return parts.length > 1
          ? (parts.first[0] + parts.last[0]).toUpperCase()
          : parts.first[0].toUpperCase();
    }

    return Scaffold(
      body: Stack(
        children: [
          const AnimatedSpaceBackground(),
          const SatelliteOverlay(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: FutureBuilder<UserProfile>(
                future: _profileFuture,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snap.hasError) {
                    return Center(
                        child: Text(
                      'Error: ${snap.error}',
                      style: GoogleFonts.montserrat(color: Colors.redAccent),
                      textAlign: TextAlign.center, // already centered
                    ));
                  }
                  final profile = snap.data!;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Glass header
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                          child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.05),
                              border: Border.all(
                                  color: AidaColors.accent.withOpacity(0.3)),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                CircleAvatar(
                                  radius: 28,
                                  backgroundColor: AidaColors.accent,
                                  child: Text(
                                    initials(profile.name),
                                    style: GoogleFonts.montserrat(
                                      color: AidaColors.primaryText,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  'Hello, ${profile.name.split(' ').first}!',
                                  style: GoogleFonts.montserrat(
                                    color: AidaColors.primaryText,
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'What would you like to do today?',
                                  style: GoogleFonts.montserrat(
                                    color: AidaColors.secondaryText,
                                    fontSize: 16,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      // Glass cards grid
                      Expanded(
                        child: GridView.builder(
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            mainAxisSpacing: 20,
                            crossAxisSpacing: 20,
                            childAspectRatio: 1,
                          ),
                          itemCount: items.length,
                          itemBuilder: (_, i) => _GlassCard(item: items[i]),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardItem {
  final String label;
  final IconData icon;
  final String route;
  final bool isLogout;

  const _DashboardItem(this.label, this.icon, this.route,
      {this.isLogout = false});
}

class _GlassCard extends StatefulWidget {
  final _DashboardItem item;

  const _GlassCard({required this.item});

  @override
  __GlassCardState createState() => __GlassCardState();
}

class __GlassCardState extends State<_GlassCard>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 100));
  late final Animation<double> _scale =
      Tween(begin: 1.0, end: 0.96).animate(_ctrl);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _ctrl.forward(),
      onTapUp: (_) {
        _ctrl.reverse();
        if (widget.item.isLogout) {
          const FlutterSecureStorage().delete(key: 'access_token');
          navigatorKey.currentState
              ?.pushNamedAndRemoveUntil('/login', (_) => false);
        } else {
          navigatorKey.currentState?.pushNamed(widget.item.route);
        }
      },
      onTapCancel: () => _ctrl.reverse(),
      child: ScaleTransition(
        scale: _scale,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.04),
                border: Border.all(color: AidaColors.accent.withOpacity(0.2)),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(
                    widget.item.icon,
                    size: 42,
                    color: AidaColors.accent,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    widget.item.label,
                    style: GoogleFonts.montserrat(
                      color: AidaColors.primaryText,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
