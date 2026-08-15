import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/config.dart';
import 'router.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseAnonKey,
    // Every visit starts at the sign-in screen.
    //
    // By default Supabase writes the session to browser storage and restores
    // it on load, so returning to the app dropped you straight onto whichever
    // dashboard you last used. Sensible for a product somebody uses daily;
    // wrong here, where the first thing anyone should meet is the sign-in
    // screen and its four roles.
    //
    // EmptyLocalStorage keeps the session in memory only: it survives
    // navigation within the app, and ends when the tab closes or reloads.
    authOptions: const FlutterAuthClientOptions(
      localStorage: EmptyLocalStorage(),
    ),
  );

  runApp(const ProviderScope(child: SmartSchoolApp()));
}

class SmartSchoolApp extends ConsumerWidget {
  const SmartSchoolApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);

    return MaterialApp.router(
      title: 'SchoolSync AI',
      debugShowCheckedModeBanner: false,
      routerConfig: router,
      // One theme, deliberately. A school administrator uses this in a bright
      // office and often on a projector, so the light palette is the design
      // rather than a mode — a dark variant would be a second design to keep
      // consistent for no benefit here.
      theme: buildAppTheme(),
      themeMode: ThemeMode.light,
    );
  }
}
