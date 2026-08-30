import re

with open('lib/providers/account_provider.dart', 'r', encoding='utf-8') as f:
    text = f.read()

# 1. Imports
text = re.sub(r\"import 'package:google_sign_in/google_sign_in\.dart';\", \"import 'package:flutter/material.dart';\\nimport '../screens/login_webview_screen.dart';\", text)

# 2. Scopes and client id
text = re.sub(r'  static const List<String> youtubeScopes = \[.*?\];\n', '', text, flags=re.DOTALL)
text = re.sub(r'  static const String serverClientId =.*?\n', '', text, flags=re.DOTALL)

# 3. Fields
text = re.sub(r'  StreamSubscription<GoogleSignInAccount\?>\? _authSubscription;\n', '', text)
text = re.sub(r'  final GoogleSignIn _googleSignIn = GoogleSignIn\([\s\S]*?\);\n', '', text)
text = re.sub(r'  GoogleSignInAccount\? _user;\n', '  String? _cookieString;\n', text)

# 4. Getters
text = text.replace('GoogleSignInAccount? get user => _user;', 'String? get cookieString => _cookieString;')
text = text.replace('bool get isSignedIn => _user != null || _mode == AccountMode.youtube;', 'bool get isSignedIn => _cookieString != null || _mode == AccountMode.youtube;')
text = text.replace('bool get hasLiveSession => _user != null;', 'bool get hasLiveSession => _cookieString != null;')
text = text.replace('bool get needsReconnect => _mode == AccountMode.youtube && _user == null;', 'bool get needsReconnect => _mode == AccountMode.youtube && _cookieString == null;')
text = text.replace('String? get email => _user?.email ?? _cachedEmail;', 'String? get email => _cachedEmail;')
text = text.replace('String? get photoUrl => _user?.photoUrl ?? _cachedPhotoUrl;', 'String? get photoUrl => _cachedPhotoUrl;')
text = text.replace('if (_mode == AccountMode.guest && _user == null) return \\'Guest User\\';', 'if (_mode == AccountMode.guest && _cookieString == null) return \\'Guest User\\';')
text = text.replace('final name = _user?.displayName?.trim();', 'final name = _cachedDisplayName?.trim();')
text = text.replace('final session = _user == null ? \\'cached\\' : \\'connected\\';', 'final session = _cookieString == null ? \\'cached\\' : \\'connected\\';')

# 5. signIn
old_sign_in = '''  Future<void> signIn() async {
    await _ready;
    await _runBusy(() async {
      try {
        _errorMessage = null;
        final account = await _googleSignIn.signIn();
        if (account != null) {
          await _setUser(
            account,
            fetchIfAuthorized: true,
            promptForScopes: true,
            forceRefresh: true,
          );
        }
      } catch (e) {
        _errorMessage = e.toString();
        notifyListeners();
      }
    });
  }'''

new_sign_in = '''  Future<void> signIn(BuildContext context) async {
    await _ready;
    await _runBusy(() async {
      try {
        _errorMessage = null;
        final cookie = await Navigator.of(context).push<String?>(
          MaterialPageRoute(builder: (_) => const LoginWebviewScreen()),
        );
        if (cookie != null && cookie.isNotEmpty) {
          await _setUser(
            cookie,
            fetchIfAuthorized: true,
            forceRefresh: true,
          );
        }
      } catch (e) {
        _errorMessage = e.toString();
        notifyListeners();
      }
    });
  }'''
text = text.replace(old_sign_in, new_sign_in)

old_connect = '''  Future<void> connectYoutube() async {
    await signIn();
  }'''
new_connect = '''  Future<void> connectYoutube(BuildContext context) async {
    await signIn(context);
  }'''
text = text.replace(old_connect, new_connect)

# 6. _clearUser
text = text.replace('_user = null;', '_cookieString = null;')
text = text.replace('await prefs.remove(_cachedPhotoUrlKey);', 'await prefs.remove(_cachedPhotoUrlKey);\\n    await prefs.remove(\\'sapisid_cookie\\');')

# 7. _setUser
old_set_user = '''  Future<void> _setUser(
    GoogleSignInAccount account, {
    bool fetchIfAuthorized = false,
    bool promptForScopes = false,
    bool forceRefresh = false,
  }) async {
    _user = account;
    final prefs = await SharedPreferences.getInstance();
    final previousCachedEmail = prefs.getString(_cachedEmailKey);
    await _cacheProfile(account, prefs);

    if (previousCachedEmail != null &&
        previousCachedEmail.isNotEmpty &&
        previousCachedEmail != account.email) {
      _library = AccountLibrary.empty;
      _playlistMappings.clear();
      await prefs.remove(_cachedLibraryKey);
      await prefs.remove(_playlistMappingsKey);
    } else if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) {
      _restoreCachedLibrary(prefs);
    }

    bool hasScopes = false;
    if (promptForScopes) {
      try {
        hasScopes = await _googleSignIn.requestScopes(youtubeScopes);
      } catch (e) {
        hasScopes = false;
        _errorMessage = 'YouTube access not granted.';
      }
    } else {
      // If we didn't prompt, we assume we have them if we're authorized
      hasScopes = _youtubeAuthorized;
    }

    if (hasScopes) {
      _youtubeAuthorized = true;
      _mode = AccountMode.youtube;
      await prefs.setBool(_authorizedKey, true);
      if (fetchIfAuthorized && (forceRefresh || await _shouldSync())) {
        await refreshLibrary(force: forceRefresh);
      }
    } else if (_youtubeAuthorized && _hasCachedYoutubeState) {
      _mode = AccountMode.youtube;
    } else {
      _mode = AccountMode.guest;
    }
    notifyListeners();
  }'''

new_set_user = '''  Future<void> _setUser(
    String cookie, {
    bool fetchIfAuthorized = false,
    bool forceRefresh = false,
  }) async {
    _cookieString = cookie;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('sapisid_cookie', cookie);

    if (_library.likedSongs.isEmpty && _library.playlists.isEmpty) {
      _restoreCachedLibrary(prefs);
    }

    _youtubeAuthorized = true;
    _mode = AccountMode.youtube;
    await prefs.setBool(_authorizedKey, true);
    if (fetchIfAuthorized && (forceRefresh || await _shouldSync())) {
      await refreshLibrary(force: forceRefresh);
    }
    notifyListeners();
  }'''
text = text.replace(old_set_user, new_set_user)

# 8. signOut
old_sign_out = '''      _explicitSignOut = true;
      try {
        await _googleSignIn.signOut();
      } finally {
        _explicitSignOut = false;
      }
      _clearUser();'''
new_sign_out = '''      _explicitSignOut = true;
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove('sapisid_cookie');
      } finally {
        _explicitSignOut = false;
      }
      await _clearUser();'''
text = text.replace(old_sign_out, new_sign_out)

# 9. _init
old_init = '''      // No explicit initialization needed in v6.x
      _authSubscription =
          _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
        debugPrint('AccountProvider: Auth event received: ');
        if (account != null) {
          unawaited(_setUser(
            account,
            fetchIfAuthorized: _youtubeAuthorized,
            promptForScopes: false,
          ));
        } else {
          if (_explicitSignOut) {
            _clearUser();
          } else {
            _user = null;
            if (_youtubeAuthorized) {
              _mode = AccountMode.youtube;
            } else {
              _clearUser();
            }
          }
        }
        notifyListeners();
      });

      GoogleSignInAccount? account;
      if (_youtubeAuthorized) {
        debugPrint('AccountProvider: Attempting silent restoration at startup to restore session...');
        try {
          final signInFuture = _googleSignIn.signInSilently();
          account = await signInFuture.timeout(const Duration(seconds: 8),
                  onTimeout: () => null);
        } catch (e) {
          debugPrint('AccountProvider: signInSilently failed: ');
        }
      }

      if (account != null) {
        await _setUser(
          account,
          fetchIfAuthorized: _youtubeAuthorized,
          promptForScopes: false,
        );
      } else if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
        notifyListeners();
      }'''

new_init = '''      final savedCookie = prefs.getString('sapisid_cookie');
      if (savedCookie != null && savedCookie.isNotEmpty) {
        await _setUser(
          savedCookie,
          fetchIfAuthorized: _youtubeAuthorized,
          forceRefresh: false,
        );
      } else if (_youtubeAuthorized) {
        _mode = AccountMode.youtube;
        notifyListeners();
      }'''
text = text.replace(old_init, new_init)

# 10. getAuthHeaders
old_headers = '''  Future<Map<String, String>?> getAuthHeaders() async {
    final account = _user;
    if (account == null) return null;
    try {
      final authHeaders = await account.authHeaders;
      if (authHeaders.isNotEmpty) {
        return authHeaders;
      }
    } catch (e) {
      debugPrint('Error getting auth headers: ');
    }
    return null;
  }'''
new_headers = '''  Future<Map<String, String>?> getAuthHeaders() async {
    final cookie = _cookieString;
    if (cookie == null || cookie.isEmpty) return null;
    return {'Cookie': cookie};
  }'''
text = text.replace(old_headers, new_headers)

# 11. refreshLibrary inal account = _user;
text = text.replace('final account = _user;', 'final account = _cookieString;')

# 12. dispose
text = text.replace('    unawaited(_authSubscription?.cancel());\\n', '')

# 13. _cacheProfile
text = re.sub(r'  Future<void> _cacheProfile\(GoogleSignInAccount account, SharedPreferences prefs\) async \{[\s\S]*?  \}\n', '', text)

with open('lib/providers/account_provider.dart', 'w', encoding='utf-8') as f:
    f.write(text)
