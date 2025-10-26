import 'dart:async';
import 'dart:ui';

import 'package:advanced_ai_diagnostics/ui_elements.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'main.dart';
import 'navigation_screen.dart';

export 'chat_interface_stub.dart'
    if (dart.library.html) 'chat_interface_web.dart';

/// Glass‑morphic MFA entry dialog
class OtpEntryDialog extends StatefulWidget {
  const OtpEntryDialog({super.key});

  @override
  State<OtpEntryDialog> createState() => _OtpEntryDialogState();
}

class _OtpEntryDialogState extends State<OtpEntryDialog> {
  final List<TextEditingController> _cts =
      List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _fns = List.generate(6, (_) => FocusNode());
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fns.first.requestFocus();
    });

    _cts[0].addListener(() {
      final text = _cts[0].text;
      if (text.length == 6 && RegExp(r'^\d{6}$').hasMatch(text)) {
        // Defer population to avoid mid-update reentrancy issues
        Future.microtask(() {
          for (int i = 0; i < 6; i++) {
            _cts[i].text = text[i];
          }
          _fns[5].requestFocus();
          setState(() {});
        });
      }
    });
  }

  @override
  void dispose() {
    for (var c in _cts) {
      c.dispose();
    }
    for (var f in _fns) {
      f.dispose();
    }
    super.dispose();
  }

  String get _code => _cts.map((c) => c.text).join();

  bool get _isComplete =>
      _code.length == 6 && RegExp(r'^\d{6}$').hasMatch(_code);

  void _onDigitChanged(int i, String v) {
    if (v.length > 1) v = v.substring(v.length - 1);
    _cts[i].text = v;
    if (v.isNotEmpty && i < 5) {
      _fns[i + 1].requestFocus();
    }
    if (v.isEmpty && i > 0) {
      _fns[i - 1].requestFocus();
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    const accent = AidaPalette.secondary;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Container(
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: accent.withOpacity(0.4), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.2),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Verify with MFA',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AidaPalette.onSurface),
                ),
                const SizedBox(height: 12),
                Text(
                  'Enter the 6-digit code from your authenticator app.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: AidaPalette.onSurface.withOpacity(0.9)),
                ),
                const SizedBox(height: 24),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(6, (i) {
                    return SizedBox(
                      width: 48,
                      height: 64,
                      child: TextField(
                        controller: _cts[i],
                        focusNode: _fns[i],
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            fontSize: 24, color: AidaPalette.onSurface),
                        maxLength: i == 0 ? 6 : 1,
                        decoration: InputDecoration(
                          counterText: '',
                          isDense: true,
                          contentPadding: EdgeInsets.zero,
                          filled: true,
                          fillColor: Colors.white.withOpacity(0.25),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: accent.withOpacity(0.6), width: 1),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide(
                                color: accent.withOpacity(0.8), width: 2),
                          ),
                        ),
                        onChanged: (v) => _onDigitChanged(i, v),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 32),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(
                          backgroundColor: Colors.white.withOpacity(0.1),
                          side: BorderSide(color: accent.withOpacity(0.6)),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: _submitting
                            ? null
                            : () => Navigator.of(context).pop<String?>(null),
                        child: const Text(
                          'Cancel',
                          style: TextStyle(color: AidaPalette.onSurface),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: accent.withOpacity(0.7),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        onPressed: !_isComplete || _submitting
                            ? null
                            : () async {
                                setState(() => _submitting = true);
                                await Future.delayed(
                                    const Duration(milliseconds: 200));
                                Navigator.of(context).pop<String>(_code);
                              },
                        child: _submitting
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: LogoCircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : const Text(
                                'Submit',
                                style: TextStyle(color: AidaPalette.onSurface),
                              ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Auth gate that redirects based on token validity
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  Future<bool> _isTokenValid() async {
    const storage = FlutterSecureStorage();
    final token = await storage.read(key: 'access_token');
    if (token == null || token.isEmpty) return false;
    final resp = await http.get(
      Uri.parse('$urlEndPoint/me/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
    );
    if (resp.statusCode == 200) {
      return true;
    } else {
      await storage.delete(key: 'access_token');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _isTokenValid(),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: LogoCircularProgressIndicator()),
          );
        }
        if (snap.data == true) {
          return const DashboardPage();
        }
        return const LoginPage();
      },
    );
  }
}
