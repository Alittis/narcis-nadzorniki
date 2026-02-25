import 'package:flutter/material.dart';
import 'package:narcis_nadzorniki/screens/home_screen.dart';
import 'package:narcis_nadzorniki/state/app_state.dart';
import 'package:provider/provider.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MotenjApp());
}

class MotenjApp extends StatelessWidget {
  const MotenjApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppState()..init(),
      child: MaterialApp(
        title: 'Narcis Nadzorniki',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2A6F97)),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
