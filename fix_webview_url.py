with open('lib/screens/login_webview_screen.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace('Future<void> _checkForCookies() async {', 'Future<void> _checkForCookies(String url) async {\n    if (!url.contains(\'youtube.com\')) return;')

text = text.replace('await _checkForCookies();', 'await _checkForCookies(url);')

with open('lib/screens/login_webview_screen.dart', 'w', encoding='utf-8') as f:
    f.write(text)
