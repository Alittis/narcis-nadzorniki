import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:narcis_nadzorniki/screens/home_screen.dart';
import 'package:narcis_nadzorniki/screens/login_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // flutter_foreground_task lives across app launches: configuration is
  // attached at startup so AppState.startWalk can call startService()
  // without re-passing channel/notification metadata.
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'narcis_obhod',
      channelName: 'Beleženje obhoda',
      channelDescription: 'Obvešča, da poteka beleženje obhoda na terenu.',
      // DEFAULT keeps the persistent "Snemanje obhoda" notification visible
      // on the lock screen and in the main shade so the user has a clear
      // confirmation that the recording is alive throughout the walk.
      // (LOW would hide it under Samsung's "Silent notifications" group.)
      channelImportance: NotificationChannelImportance.DEFAULT,
      priority: NotificationPriority.DEFAULT,
      iconData: const NotificationIconData(
        resType: ResourceType.mipmap,
        resPrefix: ResourcePrefix.ic,
        name: 'launcher',
      ),
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: false,
      playSound: false,
    ),
    foregroundTaskOptions: const ForegroundTaskOptions(
      interval: 3000,
      isOnceEvent: false,
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: false,
    ),
  );
  runApp(const MotenjApp());
}

class MotenjApp extends StatelessWidget {
  const MotenjApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: MaterialApp(
        title: 'Terenska beležnica',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF388E3C)),
          useMaterial3: true,
        ),
        home: Consumer<AppState>(
          builder: (context, state, _) {
            // While init() restores any persisted session, show a brief splash
            // instead of flashing the login screen on every cold start.
            if (state.isBootstrapping) return const _SplashScreen();
            return state.isAuthenticated
                ? const HomeScreen()
                : const LoginScreen();
          },
        ),
      ),
    );
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF2E7D32),
      body: Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );
  }
}
