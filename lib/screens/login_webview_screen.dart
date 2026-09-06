import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

// LoginWebviewScreen renders an embedded web browser screen for Google / YouTube login.
// This allows users to sign into their YouTube Music account directly inside the app
// so the app can sync their playlists, liked songs, and personalized home feed.
class LoginWebviewScreen extends StatefulWidget {
  // If true, wipes stored webview cookies before displaying the login page (useful for logging out or switching accounts).
  final bool clearCookies;

  // Constructor with optional clearCookies flag defaulting to false.
  const LoginWebviewScreen({super.key, this.clearCookies = false});

  @override
  State<LoginWebviewScreen> createState() => _LoginWebviewScreenState();
}

// State class managing the WebViewController, tracking page loading state,
// and monitoring navigation to intercept authentication cookies once the user logs in.
class _LoginWebviewScreenState extends State<LoginWebviewScreen> {
  // Controller to command the in-app web browser (load URLs, configure settings).
  late final WebViewController _controller;

  // Platform channel to communicate with native Android code to access HttpOnly cookies.
  static const _cookieChannel = MethodChannel('musico/cookies');

  // True while a web page is actively loading, displaying a spinner in the top bar.
  bool _isLoading = true;

  // Initializes the webview controller, sets custom desktop/mobile user-agent,
  // configures navigation delegates, and loads the Google sign-in URL.
  @override
  void initState() {
    super.initState();
    // Clear cookies if requested by the caller
    if (widget.clearCookies) {
      WebViewCookieManager().clearCookies();
    }
    _controller = WebViewController()
      // Allow JavaScript so Google's dynamic login forms function properly
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // Custom User-Agent header to prevent Google from blocking embedded webviews
      ..setUserAgent(
          'Mozilla/5.0 (Linux; Android 10) AppleWebKit/537.36 '
          '(KHTML, like Gecko) Chrome/118.0.0.0 Mobile Safari/537.36')
      ..setNavigationDelegate(
        NavigationDelegate(
          // Show loading indicator when navigation starts
          onPageStarted: (String url) {
            setState(() {
              _isLoading = true;
            });
          },
          // Hide loading indicator when page finishes loading and check if we received auth cookies
          onPageFinished: (String url) async {
            setState(() {
              _isLoading = false;
            });
            // When user reaches YouTube domain after sign-in, check for session cookies
            if (url.contains('youtube.com')) {
              await _checkForCookies();
            }
          },
        ),
      )
      // Navigate directly to Google's YouTube login endpoint with return URL set to YouTube Music
      ..loadRequest(Uri.parse(
          'https://accounts.google.com/ServiceLogin'
          '?service=youtube&passive=1209600'
          '&continue=https://music.youtube.com/'));
  }

  // Checks whether the user has successfully signed in by inspecting browser cookies.
  // Uses the native Android CookieManager to access sensitive "HttpOnly" cookies (like SAPISID).
  // When valid cookies are found, closes the screen and returns them to the caller.
  Future<void> _checkForCookies() async {
    try {
      // Use native Android CookieManager to get ALL cookies
      // including HttpOnly ones that JavaScript cannot access
      final String? cookies = await _cookieChannel.invokeMethod<String>(
        'getCookies',
        {'url': 'https://music.youtube.com'},
      );

      debugPrint('LoginWebview: Got cookies: ${cookies != null ? "${cookies.length} chars" : "null"}');

      // "SAPISID" is the essential authentication cookie Google uses to verify identity
      if (cookies != null && cookies.contains('SAPISID=')) {
        debugPrint('LoginWebview: SAPISID found! Returning cookies to app.');
        if (mounted) {
          // Close the webview and return the cookie string to the login handler
          Navigator.of(context).pop(cookies);
        }
      }
    } catch (e) {
      debugPrint('Error extracting cookies: $e');
    }
  }

  // Builds the webview screen with a top app bar and the embedded web browser.
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Login to YouTube Music'),
        backgroundColor: const Color(0xFF0A0A0F),
        actions: [
          // Show a spinning activity indicator while the web page is loading
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
      // Displays the actual web browser rendering the Google login page
      body: SafeArea(
        child: WebViewWidget(controller: _controller),
      ),
    );
  }
}
