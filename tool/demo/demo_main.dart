// 演示用入口：仅供 README 截图。
//
// 用内存版 SharedPreferences 注入一份「演示账号 + 工作区标签」，让应用启动后
// 直接进入项目页；账号 baseUrl 指向本地 mock 服务（tool/demo/mock_jenkins.py），
// 不会连接任何真实 Jenkins，也不读写真实钥匙串 / 用户数据。
//
// 运行：
//   1. python3 tool/demo/mock_jenkins.py 8732
//   2. flutter run -d macos -t tool/demo/demo_main.dart \
//        --dart-define=DEMO_PORT=8732 --dart-define=DEMO_SCREEN=project \
//        --dart-define=DEMO_W=1380 --dart-define=DEMO_H=880
//
// DEMO_SCREEN: project（默认，自动触发一次构建以展示进度/日志）| settings
import 'dart:async';

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'package:deployment/app.dart';
import 'package:deployment/core/storage/preferences.dart';
import 'package:deployment/features/release/application/release_controller.dart';
import 'package:deployment/features/settings/data/jenkins_accounts_repository.dart';
import 'package:deployment/plug/network_proxy/application/network_proxy_application.dart';
import 'package:deployment/plug/network_proxy/network_proxy.dart';

const _port = int.fromEnvironment('DEMO_PORT', defaultValue: 8732);
const _screen = String.fromEnvironment('DEMO_SCREEN', defaultValue: 'project');
const _winW = int.fromEnvironment('DEMO_W', defaultValue: 1380);
const _winH = int.fromEnvironment('DEMO_H', defaultValue: 880);

String get _baseUrl => 'http://127.0.0.1:$_port';

const _prodId = 'demo-prod';
const _stagingId = 'demo-staging';
const _jobFullName = 'backend/order-service';
const _projectTabId = 'job:$_jobFullName';

Map<String, Object> _seedPrefs() {
  final accounts = [
    {
      'id': _prodId,
      'name': 'prod · jenkins.demo.internal',
      'baseUrl': _baseUrl,
      'username': 'demo',
      'authKind': 'token',
    },
    {
      'id': _stagingId,
      'name': 'staging · jenkins.staging.internal',
      'baseUrl': _baseUrl,
      'username': 'demo',
      'authKind': 'token',
    },
  ];

  final projectTab = {
    'id': _projectTabId,
    'kind': 'project',
    'title': 'order-service',
    'subtitle': _jobFullName,
    'projectFullName': _jobFullName,
    'projectKind': 'job',
  };
  const settingsTab = {
    'id': '__settings__',
    'kind': 'settings',
    'title': 'Jenkins 配置',
  };

  final isSettings = _screen == 'settings';
  final tabs = isSettings ? [projectTab, settingsTab] : [projectTab];
  final activeTabId = isSettings ? '__settings__' : _projectTabId;

  final tabsByAccount = {
    _prodId: {'tabs': tabs, 'activeId': activeTabId},
  };

  // 注意：legacy 版 SharedPreferences 的 mock 需要 'flutter.' 前缀。
  return {
    'flutter.jenkins.accounts.list_v1': jsonEncode(accounts),
    'flutter.jenkins.accounts.active_id': _prodId,
    'flutter.jenkins.accounts.secret_fallback.$_prodId': 'demo-api-token',
    'flutter.jenkins.accounts.secret_fallback.$_stagingId': 'demo-api-token',
    'flutter.workspace.opened_account_ids_v1': <String>[_prodId, _stagingId],
    'flutter.workspace.active_workspace_account_id_v1': _prodId,
    'flutter.workspace.tabs_by_account_v1': jsonEncode(tabsByAccount),
    'flutter.app.theme_mode': 'dark',
    'flutter.app.locale_code': 'zh',
  };
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await windowManager.ensureInitialized();
    final opts = WindowOptions(
      size: Size(_winW.toDouble(), _winH.toDouble()),
      center: true,
      backgroundColor: const Color(0xFF0F1115),
      titleBarStyle: TitleBarStyle.normal,
      title: 'Deployment · Demo',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      await windowManager.setSize(Size(_winW.toDouble(), _winH.toDouble()));
      await windowManager.show();
      await windowManager.center();
      await windowManager.focus();
    });
  } catch (_) {
    // 非桌面或初始化失败时忽略，仍以默认窗口启动。
  }

  SharedPreferences.setMockInitialValues(_seedPrefs());
  final prefs = await SharedPreferences.getInstance();

  final container = ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      networkProxySharedPreferencesProvider.overrideWithValue(prefs),
      networkProxyLoggerProvider.overrideWithValue((message, {error, stackTrace}) {}),
    ],
  );

  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const DeploymentApp(),
    ),
  );

  if (_screen != 'settings') {
    unawaited(_autoTriggerDemoBuild(container));
  }
}

/// 项目页是「点击立即构建后」才在右侧渲染进度 / 日志面板的，截图前先用同一套
/// provider 程序化触发一次（接的是本地 mock 的演示数据）。
Future<void> _autoTriggerDemoBuild(ProviderContainer container) async {
  try {
    await container.read(jenkinsAccountsProvider.future);
  } catch (_) {}
  // 等窗口与项目详情渲染完成。
  await Future<void>.delayed(const Duration(milliseconds: 2600));

  const key = (accountId: _prodId, fullName: _jobFullName);
  final handle =
      container.read(projectRunTabsProvider(key).notifier).addRun(_jobFullName);
  await container.read(releaseControllerProvider(handle).notifier).trigger(
    parameters: const {
      'BRANCH': 'origin/release/1.4.0',
      'ENV': 'staging',
      'VERSION': '1.4.0',
      'SKIP_TESTS': 'false',
      'RELEASE_NOTE': '修复优惠券引擎并发问题，补充订单超时重试',
    },
  );
}
