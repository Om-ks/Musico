import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LoginWebviewScreen extends StatefulWidget {
  const LoginWebviewScreen({super.key});

  @override
  State<LoginWebviewScreen> createState() => _LoginWebviewScreenState();
}

class _LoginWebviewScreenState extends State<LoginWebviewScreen> {
  late final WebViewController _controller;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent('Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36')
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
            await _checkForCookies();
          },
        ),
      )
      ..loadRequest(Uri.parse('https://accounts.google.com/ServiceLogin?service=youtube&passive=1209600&continue=https://music.youtube.com/'));
  }

  Future<void> _checkForCookies() async {
    try {
      final Object result = await _controller.runJavaScriptReturningResult('document.cookie');
      final String cookies = result.toString().replaceAll('"', ''); // Sometimes returned with quotes
      
      if (cookies.contains('SAPISID=')) {
        if (mounted) {
          Navigator.of(context).pop(cookies);
        }
      }
    } catch (e) {
      debugPrint('Error extracting cookies via JS: $e');
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
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
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
