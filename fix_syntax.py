with open('lib/screens/login_webview_screen.dart', 'r', encoding='utf-8') as f:
    text = f.read()

text = text.replace(r'final cookieString = cookies.map((c) => \'\\=\\\').join(\'; \');', r'final cookieString = cookies.map((c) => \'=\').join(\'; \');')
text = text.replace(r'debugPrint(\'Error extracting cookies: \\\');', r'debugPrint(\'Error extracting cookies: \');')

with open('lib/screens/login_webview_screen.dart', 'w', encoding='utf-8') as f:
    f.write(text)
