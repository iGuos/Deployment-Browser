import 'package:deployment/app.dart';
import 'package:deployment/core/storage/preferences.dart';
import 'package:deployment/plug/network_proxy/application/network_proxy_application.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('App boots without throwing', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          networkProxySharedPreferencesProvider.overrideWithValue(prefs),
          networkProxyLoggerProvider.overrideWithValue(
            (message, {error, stackTrace}) {},
          ),
        ],
        child: const DeploymentApp(),
      ),
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
