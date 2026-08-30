import re

with open('lib/providers/account_provider.dart', 'r', encoding='utf-8') as f:
    code = f.read()

# Remove GoogleSignIn imports
code = re.sub(r\"import 'package:google_sign_in/google_sign_in.dart';\n\", '', code)

# Remove youtubeScopes
code = re.sub(r'  static const List<String> youtubeScopes = \[.*?\];\n\n', '', code, flags=re.DOTALL)

# Remove serverClientId
code = re.sub(r'  static const String serverClientId.*?\n', '', code, flags=re.DOTALL)

# Change GoogleSignIn properties to a string for cookie
code = re.sub(r'  StreamSubscription<GoogleSignInAccount\?>\? _authSubscription;\n', '', code)
code = re.sub(r'  final GoogleSignIn _googleSignIn.*?\);\n', '', code, flags=re.DOTALL)
code = re.sub(r'  GoogleSignInAccount\? _user;\n', '  String? _cookieString;\n', code)

# Change user getters
code = code.replace('GoogleSignInAccount? get user => _user;', 'String? get cookieString => _cookieString;')
code = code.replace('bool get isSignedIn => _user != null || _mode == AccountMode.youtube;', 'bool get isSignedIn => _cookieString != null || _mode == AccountMode.youtube;')
code = code.replace('bool get hasLiveSession => _user != null;', 'bool get hasLiveSession => _cookieString != null;')
code = code.replace('bool get needsReconnect => _mode == AccountMode.youtube && _user == null;', 'bool get needsReconnect => _mode == AccountMode.youtube && _cookieString == null;')
code = code.replace('String? get email => _user?.email ?? _cachedEmail;', 'String? get email => _cachedEmail;')
code = code.replace('String? get photoUrl => _user?.photoUrl ?? _cachedPhotoUrl;', 'String? get photoUrl => _cachedPhotoUrl;')

# Fix displayName
code = code.replace('final name = _user?.displayName?.trim();', 'final name = _cachedDisplayName?.trim();')

# Fix _clearUser
code = code.replace('_user = null;', '_cookieString = null;')
code = code.replace('await prefs.remove(_cachedPhotoUrlKey);', 'await prefs.remove(_cachedPhotoUrlKey);\n    await prefs.remove(\\'sapisid_cookie\\');')

# We'll just replace the entire class to be safe and clean. It's complex to regex this correctly.
