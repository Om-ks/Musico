import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LoginWebviewScreen extends StatefulWidget {
  const LoginWebviewScreen({super.key});

  @override
  State<LoginWebviewScreen> createState() => _LoginWebviewScreenState();
}

class _LoginWebviewScreenState extends State<LoginWebviewScreen> {
  late final WebViewController _controller;
  static const _cookieChannel = MethodChannel('musico/cookies');
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          onPageFinished: (String url) async {
            setState(() {
              _isLoading = false;
            });
            if (url.contains('youtube.com')) {
              await _checkForCookies();
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(
          'https://accounts.google.com/ServiceLogin'
          '?service=youtube&passive=1209600'
          '&continue=https://music.youtube.com/'));
  }

  Future<void> _checkForCookies() async {
    try {
      // Use native Android CookieManager to get ALL cookies
      // including HttpOnly ones that JavaScript cannot access
      final String? cookies = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': 'https://music.youtube.com'},
      );

      debugPrint('LoginWebview: Got cookies: ${cookies != null ? "${cookies.length} chars" : "null"}');

      if (cookies != null && cookies.contains('SAPISID=')) {
        debugPrint('LoginWebview: SAPISID found! Returning cookies to app.');
        if (mounted) {
          Navigator.of(context).pop(cookies);
        }
      }
    } catch (e) {
      debugPrint('Error extracting cookies: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login to YouTube Music'),
        backgroundColor: const Color(0xFF0A0A0F),
        actions: [
          if (_isLoading)
            const Padding(
              padding: EdgeInsets.all(16.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              ),
            )
        ],
      ),
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
