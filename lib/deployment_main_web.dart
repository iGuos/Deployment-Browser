import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'core/storage/preferences.dart';
import 'core/utils/provider_boot_observer.dart';

Future<void> deploymentMain(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();

  runApp(
    ProviderScope(
      observers: [ProviderBootObserver()],
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const DeploymentApp(),
    ),
  );
}
