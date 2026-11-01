import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app_state.dart';
import 'ui/home_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ChangeNotifierProvider(
    create: (_) => AppState()..init(),
    child: const IslamicShortsApp(),
  ));
}

class IslamicShortsApp extends StatelessWidget {
  const IslamicShortsApp({super.key});

  @override
  Widget build(BuildContext context) {
    final mode = context.select<AppState, ThemeMode>((s) => s.themeMode);
    const seed = Color(0xFF0F766E);
    return MaterialApp(
      title: 'Islamic Shorts Generator',
      debugShowCheckedModeBanner: false,
      themeMode: mode,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.light),
      darkTheme: ThemeData(useMaterial3: true, colorSchemeSeed: seed, brightness: Brightness.dark),
      home: const HomeScreen(),
    );
  }
}
