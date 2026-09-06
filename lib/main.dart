import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:audio_service/audio_service.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/account_provider.dart';
import 'providers/player_provider.dart';
import 'services/musico_audio_handler.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'screens/library_screen.dart';
import 'widgets/mini_player.dart';
import 'widgets/bottom_nav.dart';

// Entrypoint of the application.
// Initializes Flutter bindings, sets up system transparent status bars,
// initializes background AudioService, and boots the widget tree with Providers.
Future<void> main() async {
  // Catches and logs uncaught asynchronous errors in the application zone.
  runZonedGuarded(() async {
    // Ensures Flutter engine and native channel bindings are ready before plugins run.
    WidgetsFlutterBinding.ensureInitialized();

    // Sets transparent system status bar with light icons for dark mode aesthetic.
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    // Boots the background audio handler responsible for OS lock screen notifications and controls.
    final audioHandler = await AudioService.init<MusicoAudioHandler>(
      builder: MusicoAudioHandler.new,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.ryanheise.audioservice.AudioService',
        androidNotificationChannelName: 'Musico Playback Engine',
        androidNotificationOngoing: false,
        androidNotificationIcon: 'mipmap/ic_launcher',
        androidStopForegroundOnPause: false,
      ),
    );

    // Runs the root widget wrapped with multi-provider state management.
    runApp(
      MultiProvider(
        providers: [
          // Global account provider managing user session and YouTube Music authorization.
          ChangeNotifierProvider(create: (_) => AccountProvider()),
          // Global player provider managing audio playback engine, queue, and effects.
          ChangeNotifierProxyProvider<AccountProvider, PlayerProvider>(
            create: (_) => PlayerProvider(audioHandler: audioHandler),
            update: (_, account, player) => player!..updateAccount(account),
          ),
        ],
        child: const MusicoApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('GLOBAL ERROR: $error\n$stack');
  });
}

// Root application widget that configures the MaterialApp dark theme, fonts, and home route.
class MusicoApp extends StatelessWidget {
  // Const constructor for the root application widget.
  const MusicoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark();
    return MaterialApp(
      title: 'Musico',
      debugShowCheckedModeBanner: false,
      // Configure rich dark theme with accent purple and teal colors.
      theme: base.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFB06EF3), // Neon purple accent
          secondary: Color(0xFF6E9EF3), // Light blue secondary
          surface: Color(0xFF141420), // Dark surface container
        ),
        // Modern Space Grotesk font family across the entire application.
        textTheme: GoogleFonts.spaceGroteskTextTheme(base.textTheme),
        splashColor: const Color(0xFFB06EF3).withValues(alpha: 0.10),
        highlightColor: Colors.white.withValues(alpha: 0.04),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          titleTextStyle: GoogleFonts.spaceGrotesk(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.bold,
          ),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF141420),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
          ),
        ),
        // Customized seek sliders for music playback.
        sliderTheme: SliderThemeData(
          activeTrackColor: const Color(0xFFB06EF3),
          inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
          thumbColor: const Color(0xFFE0C4FF),
          overlayColor: const Color(0xFFB06EF3).withValues(alpha: 0.3),
          trackHeight: 2,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6, elevation: 8),
          overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
        ),
      ),
      // SplashGate renders a brief animated splash screen before loading the main shell.
      home: const SplashGate(),
    );
  }
}

// ============================================================================
// SplashGate: Initial splash screen gatekeeper
// ============================================================================
/// [SplashGate] acts as an introductory splash screen display on startup.
/// It displays the branding splash screen ([_MusicoSplash]) for approximately
/// 1.25 seconds before smoothly cross-fading into the main application ([MainShell]).
class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

/// State for [SplashGate] that manages the startup delay timer and cross-fade.
class _SplashGateState extends State<SplashGate> {
  /// Whether the initial splash delay has completed and the main app should show.
  bool _showApp = false;

  @override
  void initState() {
    super.initState();
    // Wait 1250 milliseconds (1.25s) before transitioning to the main shell.
    Future.delayed(const Duration(milliseconds: 1250), () {
      // Ensure the widget is still mounted in the tree before updating state.
      if (mounted) setState(() => _showApp = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    // AnimatedSwitcher provides a smooth fade transition between the splash screen and MainShell.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      child: _showApp ? const MainShell() : const _MusicoSplash(),
    );
  }
}

// ============================================================================
// _MusicoSplash: Branding Splash View
// ============================================================================
/// A lightweight branding splash screen displaying the Musico logo centered over
/// the app's signature multi-color dark gradient background.
class _MusicoSplash extends StatelessWidget {
  const _MusicoSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
        // Signature dark ambient gradient background: purple top-left to teal bottom-right.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2C1B4D), // Purple top left
              Color(0xFF0A0A0F), // Dark center
              Color(0xFF0A0A0F), // Dark center
              Color(0xFF143B33), // Green/Cyan bottom right
            ],
            stops: [0.0, 0.35, 0.65, 1.0],
          ),
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Musico brand logo image
              Image.asset(
                'assets/app_logo.png',
                width: 138,
                height: 35,
                fit: BoxFit.contain,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// MainShell: Core Application Container & Navigation Shell
// ============================================================================
/// [MainShell] is the primary scaffold holding the app's core user interface once loaded.
/// It contains:
/// 1. A slide-out side drawer ([_AboutDrawer]) for app info and account settings.
/// 2. An [IndexedStack] holding the 3 primary screens (Home, Search, Library) to preserve
///    their scroll positions and state when switching between tabs.
/// 3. A persistent [MiniPlayer] dock floating just above the bottom navigation bar.
/// 4. A custom [BottomNav] bar for switching between screens.
class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

/// State for [MainShell] managing active tab switching and drawer opening.
class _MainShellState extends State<MainShell> {
  /// GlobalKey to access ScaffoldState to programmatically open the drawer.
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Currently selected bottom navigation tab index (0: Home, 1: Search, 2: Library).
  int _currentIndex = 0;

  /// Helper method passed down to child screens allowing them to open the drawer.
  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  @override
  Widget build(BuildContext context) {
    // The three primary screen widgets indexed to match BottomNav tabs.
    final List<Widget> screens = [
      HomeScreen(onOpenMenu: _openDrawer),
      SearchScreen(onOpenMenu: _openDrawer),
      LibraryScreen(onOpenMenu: _openDrawer),
    ];

    // Listener captures user gestures anywhere on the screen.
    // This notifies PlayerProvider of active user interaction, which is necessary
    // on some platforms (like mobile web/iOS) to allow autoplaying audio streams.
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) =>
          context.read<PlayerProvider>().registerUserInteraction(),
      child: Container(
        // Ambient background gradient matching the Musico theme.
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF2C1B4D), // Purple top left
              Color(0xFF0A0A0F), // Dark center
              Color(0xFF0A0A0F), // Dark center
              Color(0xFF143B33), // Green/Cyan bottom right
            ],
            stops: [0.0, 0.35, 0.65, 1.0],
          ),
        ),
        child: Scaffold(
          key: _scaffoldKey,
          extendBody: true,
          backgroundColor: Colors.transparent,
          // Side drawer containing about information and account controls
          drawer: const _AboutDrawer(),
          // IndexedStack maintains state of each tab so switching doesn't reset scroll or data
          body: IndexedStack(index: _currentIndex, children: screens),
          // Bottom area combines the floating MiniPlayer and the navigation bar
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Persistent mini playback control widget
              const MiniPlayer(),
              // Custom tab bar for navigation
              BottomNav(
                currentIndex: _currentIndex,
                onTap: (i) => setState(() => _currentIndex = i),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// _AboutDrawer: Side Navigation Drawer for Info and Account
// ============================================================================
/// Side navigation drawer opened by tapping the menu button on any primary screen.
/// It displays:
/// - Musico branding logo and developer credits.
/// - Expandable accordions for "About" and "Tips".
/// - User account card ([_AccountPanel]) displaying sign-in status and session controls.
class _AboutDrawer extends StatefulWidget {
  const _AboutDrawer();

  @override
  State<_AboutDrawer> createState() => _AboutDrawerState();
}

/// State for [_AboutDrawer] tracking accordion expansion.
class _AboutDrawerState extends State<_AboutDrawer> {
  /// Stores which collapsible section is currently open ('about', 'tips', or null if closed).
  String? _openSection;

  @override
  Widget build(BuildContext context) {
    // Watch AccountProvider so the drawer reacts immediately when user signs in or out.
    final account = context.watch<AccountProvider>();

    return Drawer(
      backgroundColor: const Color(0xFF111118),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Musico text logo at top of drawer
              Padding(
                padding: const EdgeInsets.only(bottom: 12.0),
                child: Image.asset(
                  'assets/app_logo.png', // Logo 1 (Text side)
                  height: 28,
                  width: 110,
                  alignment: Alignment.centerLeft,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 4),
              // Creator attribution line
              Text(
                'Made by Om Kshirsagar',
                style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 22),
              // --- "About" Accordion Tile ---
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.info_outline_rounded,
                  color: Color(0xFFB06EF3),
                ),
                title: const Text(
                  'About',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                // Toggle 'about' section open or closed
                onTap: () => setState(() => _openSection = _openSection == 'about' ? null : 'about'),
              ),
              if (_openSection == 'about')
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    'Musico is a music player built for fast music search and playback, pitch, speed, bass and reverb controls, synced lyrics, a DJ-style vinyl disc, playlists, and downloads.',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.68),
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                ),
              // --- "Tips" Accordion Tile ---
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(
                  Icons.lightbulb_outline_rounded,
                  color: Color(0xFF6EF3E9),
                ),
                title: const Text(
                  'Tips',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                // Toggle 'tips' section open or closed
                onTap: () => setState(() => _openSection = _openSection == 'tips' ? null : 'tips'),
              ),
              if (_openSection == 'tips')
                Text(
                  'Long press a song to add it to a playlist. Download inside the player first, then use the save button to copy it to device Downloads. Use Applied Effects to export the current speed, bass, reverb, and pitch settings.',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.68),
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
              // Spacer pushes the account panel to the bottom of the drawer
              const Spacer(),
              // Account authentication & session management panel
              _AccountPanel(account: account),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================================
// _AccountPanel: User Profile & Authentication Status Panel
// ============================================================================
/// Renders the user's YouTube / Google account status card at the bottom of the drawer.
/// Features:
/// - User profile photo (or fallback icon) and display name.
/// - Live session indicators (connected, cached, or guest mode).
/// - Dynamic action buttons to sign in, reconnect session, link account, or sign out.
class _AccountPanel extends StatelessWidget {
  /// The account provider managing user state and authentication methods.
  final AccountProvider account;

  const _AccountPanel({required this.account});

  @override
  Widget build(BuildContext context) {
    final signedIn = account.isSignedIn;
    final liveSession = account.hasLiveSession;
    
    final error = account.errorMessage;
    final mode = account.mode;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Row containing user avatar and account identity text
          Row(
            children: [
              // User avatar image or fallback person icon
              CircleAvatar(
                radius: 18,
                backgroundColor: const Color(0xFF20202C),
                backgroundImage: account.photoUrl == null
                    ? null
                    : NetworkImage(account.photoUrl!),
                child: account.photoUrl == null
                    ? Icon(
                        signedIn
                            ? Icons.account_circle_rounded
                            : Icons.person_outline_rounded,
                        color: Colors.white70,
                        size: 22,
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              // User display name and active connection summary
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      account.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      liveSession
                          ? (account.email ?? 'YouTube connected')
                          : signedIn
                              ? (account.email ?? 'Cached YouTube library')
                              : 'Guest mode active',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.54),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Descriptive status message explaining current connectivity/sync state
          Text(
            account.statusText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 12,
              height: 1.35,
            ),
          ),
          // Error notification banner if any auth/sync error occurred
          if (error != null && error.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              error,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Color(0xFFFF9B9B),
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
          const SizedBox(height: 12),
          // Action buttons: Sign In, Reconnect, or Sign Out depending on state
          if (!signedIn) ...[
            // Guest mode: prompt to sign in with YouTube
            _modeButton(
              context,
              label: 'Sign in with YouTube',
              icon: Icons.subscriptions_rounded,
              onPressed: () { account.signIn(context); },
              color: const Color(0xFFB06EF3),
            ),
          ] else ...[
            // Expired live session: allow user to reconnect YouTube credentials
            if (!liveSession && account.youtubeAuthorized)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _modeButton(
                  context,
                  label: 'Reconnect YouTube',
                  icon: Icons.link_rounded,
                  onPressed: () { account.connectYoutube(context); },
                  color: const Color(0xFFB06EF3),
                ),
              )
            // Guest mode with partial features: option to link YouTube Music
            else if (mode == AccountMode.guest)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _modeButton(
                  context,
                  label: 'Link YouTube Music',
                  icon: Icons.link_rounded,
                  onPressed: () { account.connectYoutube(context); },
                  color: const Color(0xFFB06EF3),
                ),
              ),
            // Sign out button to clear local session and cached data
            _modeButton(
              context,
              label: 'Sign out',
              icon: Icons.logout_rounded,
              onPressed: account.signOut,
              color: Colors.white12,
              textColor: Colors.white70,
            ),
          ],
        ],
      ),
    );
  }

  /// Helper widget building a consistent full-width action button.
  /// Shows an indeterminate spinner if the account provider is currently busy.
  Widget _modeButton(
    BuildContext context, {
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
    required Color color,
    Color textColor = Colors.white,
  }) {
    return SizedBox(
      width: double.infinity,
      child: TextButton.icon(
        // Disable button click when an asynchronous account operation is in progress
        onPressed: account.isBusy ? null : onPressed,
        // Show progress spinner when busy, otherwise display the button icon
        icon: account.isBusy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon, size: 18),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: textColor,
          backgroundColor: color.withValues(alpha: 0.22),
          padding: const EdgeInsets.symmetric(vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }
}

