import 'package:deployment/core/http/jenkins_http_client.dart';
import 'package:deployment/core/storage/preferences.dart';
import 'package:deployment/features/settings/data/jenkins_accounts_repository.dart';
import 'package:deployment/features/settings/domain/jenkins_account.dart';
import 'package:deployment/features/settings/domain/jenkins_config.dart';
import 'package:deployment/features/workspace/application/workspace_controller.dart';
import 'package:deployment/features/workspace/domain/workspace_tab.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

JenkinsAccount _makeAccount(String id, {String? name}) {
  return JenkinsAccount(
    id: id,
    name: name ?? 'acct-$id',
    config: JenkinsConfig(
      baseUrl: 'https://jenkins.$id.example.com',
      username: 'user-$id',
      secret: 'secret-$id',
      authKind: JenkinsAuthKind.token,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('multi-account workspace', () {
    late ProviderContainer container;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
        ],
      );
    });

    tearDown(() => container.dispose());

    test('seeds an empty workspace per account on add and switch', () async {
      await container.read(jenkinsAccountsProvider.future);
      container.read(workspaceProvider);

      final accounts = container.read(jenkinsAccountsProvider.notifier);
      await accounts.upsert(_makeAccount('a'));
      await accounts.upsert(_makeAccount('b'));

      final wsCtrl = container.read(workspaceProvider.notifier);
      await wsCtrl.openAccountInStrip('a');
      await wsCtrl.openAccountInStrip('b');
      await wsCtrl.activateAccountInStrip('a');

      var ws = container.read(workspaceProvider);
      expect(ws.activeAccountId, 'a');
      expect(ws.byAccount.containsKey('a'), isTrue);
      expect(ws.byAccount.containsKey('b'), isTrue);
      expect(ws.tabs, isEmpty, reason: '新账号默认没有任何 tab，等待用户主动打开');
      expect(ws.activeTab, isNull);

      wsCtrl.openTab(WorkspaceTab.project(
        fullName: 'group/order-service',
        displayName: 'order-service',
        multibranch: false,
      ));
      ws = container.read(workspaceProvider);
      expect(ws.tabs.length, 1);
      expect(ws.tabs.last.projectFullName, 'group/order-service');

      await wsCtrl.activateAccountInStrip('b');
      ws = container.read(workspaceProvider);
      expect(ws.activeAccountId, 'b');
      expect(ws.tabs, isEmpty);
      expect(ws.activeTab, isNull);

      await wsCtrl.activateAccountInStrip('a');
      ws = container.read(workspaceProvider);
      expect(ws.tabs.length, 1);
      expect(ws.tabs.last.projectFullName, 'group/order-service');
    });

    test('removing an account discards its workspace', () async {
      await container.read(jenkinsAccountsProvider.future);
      container.read(workspaceProvider);

      final accounts = container.read(jenkinsAccountsProvider.notifier);
      await accounts.upsert(_makeAccount('a'));
      await accounts.upsert(_makeAccount('b'));

      final wsCtrl = container.read(workspaceProvider.notifier);
      await wsCtrl.openAccountInStrip('a');
      await wsCtrl.openAccountInStrip('b');
      await wsCtrl.activateAccountInStrip('b');

      wsCtrl.openTab(WorkspaceTab.project(
        fullName: 'team/svc',
        displayName: 'svc',
        multibranch: true,
      ));

      await accounts.remove('b');

      final ws = container.read(workspaceProvider);
      expect(ws.byAccount.containsKey('b'), isFalse,
          reason: '已删除账号的 workspace 必须从 map 中清除');
      expect(ws.activeAccountId, 'a');
      expect(ws.tabs.every((t) => t.kind != WorkspaceTabKind.project), isTrue,
          reason: '账号 a 自己的 workspace 没有项目 tab');
    });
  });
}
