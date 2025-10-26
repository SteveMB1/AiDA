import 'dart:convert';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'action_dialog.dart';
import 'ai_diagnostic.dart';
import 'all_scale_recommendation.dart';
import 'login_mfa.dart';
import 'monitoring_status.dart';
import 'navigation_screen.dart';
import 'register_mfa.dart';

export 'chat_interface_stub.dart'
    if (dart.library.html) 'chat_interface_web.dart';

const urlEndPoint =
    kDebugMode ? "http://localhost:8000" : "https://aida.radforge.io";

void main() => runApp(const AidaApp());

/// Global navigator key so our API client can redirect on 401
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Color palette for AiDA
// class AidaColors {
//   static const background = Color(0xFF1F232A);
//   static const surface = Color(0xFF2A2F38);
//   static const accent = Color(0xFF70DB96);
//   static const primaryText = Color(0xFFEFEFEF);
//   static const secondaryText = Color(0xFF759BEB);
// }

class AidaColors {
  static const background = Colors.transparent;
  static const surface = Color(0xCC1F232A); // semi‑opaque panel
  static const accent = Color(0xFF00E5FF); // neon horizon blue
  static const primaryText = Color(0xFFF0F8FF); // AliceBlue for readability
  static const secondaryText = Color(0xFFB3E5FC); // light sky blue
}

class GradientLogo extends StatelessWidget {
  const GradientLogo({super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      height: 40,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Image.asset(
            "assets/logo.png",
            fit: BoxFit.contain,
          ),
        ],
      ),
    );
  }
}

class AidaApp extends StatelessWidget {
  const AidaApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'AiDA Diagnostics',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: FadePageTransitionsBuilder(),
            TargetPlatform.iOS: FadePageTransitionsBuilder(),
            TargetPlatform.fuchsia: FadePageTransitionsBuilder(),
            TargetPlatform.linux: FadePageTransitionsBuilder(),
            TargetPlatform.macOS: FadePageTransitionsBuilder(),
            TargetPlatform.windows: FadePageTransitionsBuilder(),
          },
        ),
        brightness: Brightness.dark,
        // scaffoldBackgroundColor: AidaPalette.background,
        canvasColor: AidaPalette.surface,
        textTheme: GoogleFonts.montserratTextTheme().apply(
            bodyColor: AidaPalette.onSurface,
            displayColor: AidaPalette.onSurface),
        colorScheme: const ColorScheme.dark(
          primary: AidaPalette.primary,
          secondary: AidaPalette.secondary,
          error: AidaPalette.error,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white12,
          contentPadding:
              const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: AidaPalette.secondary,
            foregroundColor: AidaPalette.onPrimary,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            padding: const EdgeInsets.symmetric(vertical: 16),
          ),
        ),
      ),
      home: const FadeInPage(child: AuthGate()),
      routes: {
        '/login': (_) => const LoginPage(),
        '/navigation': (_) => const DashboardPage(),
        if (kIsWeb) '/chat': (_) => const ChatInterface(), // ✅ Safe on web only
        '/diagnostics': (_) => const CreativeColorDiagnosticsApp(),
        '/status': (_) => const MonitoringStatus(),
        '/scale-recommendations': (_) => const RecommendationsPage()
      },
    );
  }
}

class FancyTextField extends StatefulWidget {
  final IconData icon;
  final String hint;
  final bool isPassword;
  final TextEditingController controller;

  const FancyTextField({
    super.key,
    required this.icon,
    required this.hint,
    required this.controller,
    this.isPassword = false,
  });

  @override
  State<FancyTextField> createState() => _FancyTextFieldState();
}

class _FancyTextFieldState extends State<FancyTextField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _focusController;
  late final Animation<double> _glow;

  @override
  void initState() {
    super.initState();
    _focusController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _glow = Tween<double>(begin: 0, end: 8).animate(
      CurvedAnimation(parent: _focusController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _focusController.dispose();
    super.dispose();
  }

  void _handleFocus(bool hasFocus) {
    if (hasFocus) {
      _focusController.repeat(reverse: true);
    } else {
      _focusController.reset();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: _handleFocus,
      child: AnimatedBuilder(
        animation: _glow,
        builder: (_, __) => TextFormField(
          controller: widget.controller,
          obscureText: widget.isPassword,
          style: GoogleFonts.montserrat(color: AidaColors.primaryText),
          validator: (v) => v == null || v.isEmpty ? 'Required' : null,
          decoration: InputDecoration(
            hintText: widget.hint,
            hintStyle: GoogleFonts.montserrat(
              color: AidaColors.primaryText.withOpacity(0.6),
            ),
            prefixIcon: Icon(widget.icon)
                .withShadow(blur: _glow.value, color: AidaColors.accent),
            filled: true,
            fillColor: Colors.white12,
            contentPadding:
                const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(16),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }
}

extension on Widget {
  Widget withShadow({double blur = 0, Color color = Colors.transparent}) {
    return Container(
      decoration:
          BoxDecoration(boxShadow: [BoxShadow(color: color, blurRadius: blur)]),
      child: this,
    );
  }
}

class AnimatedLoginButton extends StatefulWidget {
  final VoidCallback onPressed;
  final bool isLoading;

  const AnimatedLoginButton({
    super.key,
    required this.onPressed,
    this.isLoading = false,
  });

  @override
  State<AnimatedLoginButton> createState() => _AnimatedLoginButtonState();
}

class _AnimatedLoginButtonState extends State<AnimatedLoginButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rippleController;

  @override
  void initState() {
    super.initState();
    _rippleController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
  }

  @override
  void dispose() {
    _rippleController.dispose();
    super.dispose();
  }

  void _onTap() {
    _rippleController.forward(from: 0);
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.isLoading ? null : _onTap,
      child: SizedBox(
        width: double.infinity,
        height: 56,
        child: Stack(
          alignment: Alignment.center,
          children: [
            AnimatedBuilder(
              animation: _rippleController,
              builder: (_, __) {
                final p = _rippleController.value;
                return Container(
                  width: 200 + 80 * p,
                  height: 56 + 56 * p,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AidaColors.accent.withOpacity(1 - p),
                  ),
                );
              },
            ),
            Container(
              decoration: BoxDecoration(
                color: AidaColors.accent,
                borderRadius: BorderRadius.circular(16),
              ),
              alignment: Alignment.center,
              child: widget.isLoading
                  ? const LogoCircularProgressIndicator()
                  : Text(
                      'Log In',
                      style: GoogleFonts.montserrat(
                          color: Colors.black,
                          fontSize: 18,
                          fontWeight: FontWeight.bold),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// LoginPage with full credentials + MFA and navigation logic
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _storage = const FlutterSecureStorage();
  bool _loading = false;

  Future<bool> _requiresMfa(String token) async {
    final resp = await http.get(
      Uri.parse('$urlEndPoint/requires-mfa/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );
    if (resp.statusCode == 200) {
      return jsonDecode(resp.body)['result'] == true;
    }
    return false;
  }

  Future<http.Response> _loginRequest({
    required String username,
    required String password,
    String? mfaToken,
  }) {
    return http.post(
      Uri.parse('$urlEndPoint/login/'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'username': username,
        'password': password,
        'token': mfaToken,
      }),
    );
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _loading = true);
    try {
      final resp1 = await _loginRequest(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        mfaToken: null,
      );
      if (resp1.statusCode != 200) {
        showGlassMorphicDialog(
          context: context,
          message: jsonDecode(resp1.body)['detail'],
          type: DialogType.error,
        );
        setState(() => _loading = false);
        return;
      }
      final interimToken = jsonDecode(resp1.body)['access_token'];
      final hasDevice = await _requiresMfa(interimToken);
      if (!hasDevice) {
        await _storage.write(key: 'access_token', value: interimToken);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RegisterMfaPage(accessToken: interimToken),
          ),
        );
        return;
      }
      final otp = await showDialog<String>(
        context: context,
        builder: (_) => const OtpEntryDialog(),
      );
      if (otp == null || otp.isEmpty) {
        showGlassMorphicDialog(
          context: context,
          message: 'MFA code is required.',
          type: DialogType.error,
        );
        setState(() => _loading = false);
        return;
      }
      final resp2 = await _loginRequest(
        username: _usernameCtrl.text.trim(),
        password: _passwordCtrl.text,
        mfaToken: otp,
      );
      if (resp2.statusCode == 200) {
        final token = jsonDecode(resp2.body)['access_token'];
        await _storage.write(key: 'access_token', value: token);
        Navigator.of(context).pushReplacementNamed('/navigation');
      } else {
        showGlassMorphicDialog(
          context: context,
          message: jsonDecode(resp2.body)['detail'],
          type: DialogType.error,
        );
      }
    } catch (e) {
      showGlassMorphicDialog(
        context: context,
        message: 'Network error: $e',
        type: DialogType.error,
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const AnimatedSpaceBackground(),
          const SatelliteOverlay(),
          Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const GradientLogo(),
                    const SizedBox(height: 8),
                    Text(
                      'Welcome to AiDA',
                      style: GoogleFonts.pacifico(
                        fontSize: 36,
                        color: AidaColors.primaryText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'AI Diagnostics & Systems Performance Monitoring',
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall!
                          .copyWith(color: Colors.white),
                    ),
                    const SizedBox(height: 32),
                    FancyTextField(
                      icon: Icons.person,
                      hint: 'Email Address',
                      controller: _usernameCtrl,
                    ),
                    const SizedBox(height: 16),
                    FancyTextField(
                      icon: Icons.lock,
                      hint: 'Password',
                      controller: _passwordCtrl,
                      isPassword: true,
                    ),
                    const SizedBox(height: 32),
                    AnimatedLoginButton(
                      isLoading: _loading,
                      onPressed: _login,
                    ),
                    const SizedBox(height: 16),
                    TextButton(
                      onPressed: () =>
                          Navigator.of(context).pushNamed('/register'),
                      child: Text(
                        'Create an account',
                        style: GoogleFonts.montserrat(
                            color: AidaColors.accent,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
