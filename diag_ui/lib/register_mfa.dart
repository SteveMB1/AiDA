import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';

import 'main.dart';

class RegisterMfaPage extends StatefulWidget {
  final String accessToken;

  const RegisterMfaPage({required this.accessToken, super.key});

  @override
  _RegisterMfaPageState createState() => _RegisterMfaPageState();
}

class _RegisterMfaPageState extends State<RegisterMfaPage> {
  final _codeCtrl = TextEditingController();
  final _storage = const FlutterSecureStorage();
  String? _uri;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _fetchMfaUri();
  }

  Future<void> _fetchMfaUri() async {
    setState(() => _loading = true);
    // 1) Get the new URI
    final resp = await http.get(
      Uri.parse('$urlEndPoint/register-token/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${widget.accessToken}',
      },
    );
    if (resp.statusCode == 200) {
      final body = jsonDecode(resp.body);
      // 2) Delete any old secret
      await _storage.delete(key: 'mfa_secret');
      setState(() => _uri = body['uri']);
    } else {
      // handle error…
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Failed to start MFA registration (${resp.statusCode})')),
      );
    }
    setState(() => _loading = false);
  }

  Future<void> _confirmCode() async {
    final code = _codeCtrl.text.trim();
    if (code.length != 6) return;
    setState(() => _loading = true);

    final resp = await http.post(
      Uri.parse('$urlEndPoint/register-token/'),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${widget.accessToken}',
      },
      body: jsonEncode({'code': code}),
    );
    setState(() => _loading = false);

    if (jsonDecode(resp.body)['result']) {
      const storage = FlutterSecureStorage();
      await storage.delete(key: 'access_token');
      Navigator.of(context).pushReplacementNamed('/');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid code, please try again.')),
      );
    }
  }
  String _currentCode = '';
  @override
  Widget build(BuildContext context) {

    return Scaffold(
      appBar: AppBar(title: const Text('Register MFA')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'Scan this QR code with your Authenticator app, then enter the 6-digit code below.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  if (_uri != null)
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // white background behind the code
                        Container(
                          width: 220,
                          height: 220,
                          color: Colors.white,
                        ),
                        // the QR code
                        QrImageView(
                          data: _uri!,
                          version: QrVersions.auto,
                          size: 200.0,
                          // optionally tune error-correction level:
                          errorCorrectionLevel: QrErrorCorrectLevel.M,
                        ),
                      ],
                    )
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _codeCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Enter 6-digit code',
                      border: OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    onChanged: (val) => setState(() {
                      _currentCode = val;
                    }),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _currentCode.length == 6 ? _confirmCode : null,
                      child: Text(_loading ? 'Verifying…' : 'Verify', style: const TextStyle(color: Colors.black),),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
