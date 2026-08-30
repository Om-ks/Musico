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

Future<void> main() async {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

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

    runApp(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => AccountProvider()),
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

class MusicoApp extends StatelessWidget {
  const MusicoApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData.dark();
    return MaterialApp(
      title: 'Musico',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFB06EF3),
          secondary: Color(0xFF6E9EF3),
          surface: Color(0xFF141420),
        ),
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
      home: const SplashGate(),
    );
  }
}

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  bool _showApp = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(milliseconds: 1250), () {
      if (mounted) setState(() => _showApp = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 420),
      child: _showApp ? const MainShell() : const _MusicoSplash(),
    );
  }
}

class _MusicoSplash extends StatelessWidget {
  const _MusicoSplash();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Container(
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

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  int _currentIndex = 0;

  void _openDrawer() => _scaffoldKey.currentState?.openDrawer();

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      HomeScreen(onOpenMenu: _openDrawer),
      SearchScreen(onOpenMenu: _openDrawer),
      LibraryScreen(onOpenMenu: _openDrawer),
    ];

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) =>
          context.read<PlayerProvider>().registerUserInteraction(),
      child: Container(
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
          drawer: const _AboutDrawer(),
          body: IndexedStack(index: _currentIndex, children: screens),
          bottomNavigationBar: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const MiniPlayer(),
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

class _AboutDrawer extends StatefulWidget {
  const _AboutDrawer();

  @override
  State<_AboutDrawer> createState() => _AboutDrawerState();
}

class _AboutDrawerState extends State<_AboutDrawer> {
  String? _openSection;

  @override
  Widget build(BuildContext context) {
    final account = context.watch<AccountProvider>();

    return Drawer(
      backgroundColor: const Color(0xFF111118),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
              Text(
                'Made by Om Kshirsagar',
                style: GoogleFonts.spaceGrotesk(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 22),
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
                onTap: () => setState(() => _openSection = 'about'),
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
                onTap: () => setState(() => _openSection = 'tips'),
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
              const Spacer(),
              _AccountPanel(account: account),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountPanel extends StatelessWidget {
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
          Row(
            children: [
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
          Text(
            account.statusText,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.66),
              fontSize: 12,
              height: 1.35,
            ),
          ),
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
          if (!signedIn) ...[
            _modeButton(
              context,
              label: 'Sign in with YouTube',
              icon: Icons.subscriptions_rounded,
              onPressed: () { account.signIn(context); },
              color: const Color(0xFFB06EF3),
            ),
          ] else ...[
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
        onPressed: account.isBusy ? null : onPressed,
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

