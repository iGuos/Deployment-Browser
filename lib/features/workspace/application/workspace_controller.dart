import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/storage/preferences.dart';
import '../../jenkins/data/jenkins_repository.dart';
import '../../jenkins/data/project_detail_provider.dart';
import '../../release/application/release_controller.dart';
import '../../settings/data/jenkins_accounts_repository.dart';
import '../domain/workspace_tab.dart';

const _kOpenedAccountIds = 'workspace.opened_account_ids_v1';
const _kWorkspaceActiveAccountId = 'workspace.active_workspace_account_id_v1';
const _kWorkspaceTabsByAccount = 'workspace.tabs_by_account_v1';

/// [WorkspaceState.copyWith] 未传入 [WorkspaceState.activeAccountId] 时使用。
const Object _unsetActiveAccountId = Object();

/// 单个账号下的工作区：tabs + activeId。
@immutable
class AccountWorkspace {
  const AccountWorkspace({required this.tabs, required this.activeId});

  final List<WorkspaceTab> tabs;

  /// 当前激活的 tab id；当 [tabs] 为空时为空字符串。
  final String activeId;

  WorkspaceTab? get activeTab {
    if (tabs.isEmpty) return null;
    for (final t in tabs) {
      if (t.id == activeId) return t;
    }
    return tabs.first;
  }

  AccountWorkspace copyWith({List<WorkspaceTab>? tabs, String? activeId}) {
    return AccountWorkspace(
      tabs: tabs ?? this.tabs,
      activeId: activeId ?? this.activeId,
    );
  }

  /// 一个账号刚被加入时的初始工作区：没有任何 tab。
  /// 用户可以从左侧项目树或顶部入口主动打开 tab。
  static AccountWorkspace seed() {
    return const AccountWorkspace(tabs: [], activeId: '');
  }
}

/// 多账号工作区状态。每个账号 id 对应一份独立的 [AccountWorkspace]。
///
/// 一级标签栏只展示 [openedAccountIds]（用户通过「+」打开）；与 Jenkins 里「已配置的账号列表」解耦。
///
/// 兼容旧的 `tabs` / `activeId` / `activeTab` getter，访问的都是当前激活账号对应的工作区。
@immutable
class WorkspaceState {
  const WorkspaceState({
    required this.byAccount,
    required this.openedAccountIds,
    required this.activeAccountId,
  });

  final Map<String, AccountWorkspace> byAccount;

  /// 一级栏已打开的 Jenkins 账号 id（顺序即标签顺序）。
  final List<String> openedAccountIds;

  /// 当前选中的一级标签对应账号 id；无打开标签时为 null。
  final String? activeAccountId;

  AccountWorkspace? get active {
    final id = activeAccountId;
    if (id == null) return null;
    return byAccount[id];
  }

  /// 当前激活账号下的 tabs（无激活账号时为空）。
  List<WorkspaceTab> get tabs => active?.tabs ?? const [];

  String get activeId => active?.activeId ?? '';

  WorkspaceTab? get activeTab => active?.activeTab;

  /// 是否已打开至少一个 Jenkins 工作区标签。
  bool get hasOpenWorkspace =>
      activeAccountId != null &&
      openedAccountIds.isNotEmpty &&
      openedAccountIds.contains(activeAccountId);

  WorkspaceState copyWith({
    Map<String, AccountWorkspace>? byAccount,
    List<String>? openedAccountIds,
    Object? activeAccountId = _unsetActiveAccountId,
  }) {
    return WorkspaceState(
      byAccount: byAccount ?? this.byAccount,
      openedAccountIds: openedAccountIds ?? this.openedAccountIds,
      activeAccountId: identical(activeAccountId, _unsetActiveAccountId)
          ? this.activeAccountId
          : activeAccountId as String?,
    );
  }
}

class WorkspaceController extends Notifier<WorkspaceState> {
  /// 是否已从本地恢复过一级栏（避免账号异步就绪后重复覆盖）。
  bool _workspaceStripRestored = false;

  /// 移动端主壳：一级栏始终展示全部已配置账号（与设置里列表一致），无需再「打开工作区」。
  bool _mobileStripMirrorsAllAccounts = false;

  Map<String, AccountWorkspace> _readTabsFromPrefs() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_kWorkspaceTabsByAccount);
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      final out = <String, AccountWorkspace>{};
      for (final e in decoded.entries) {
        final id = e.key;
        if (id is! String || id.isEmpty) continue;
        final aw = _deserializeAccountWorkspace(e.value);
        if (aw != null && aw.tabs.isNotEmpty) out[id] = aw;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  void _persistWorkspaceTabs() {
    final prefs = ref.read(sharedPreferencesProvider);
    final map = <String, dynamic>{};
    for (final e in state.byAccount.entries) {
      if (e.value.tabs.isNotEmpty) {
        map[e.key] = _serializeAccountWorkspace(e.value);
      }
    }
    if (map.isEmpty) {
      prefs.remove(_kWorkspaceTabsByAccount);
    } else {
      prefs.setString(_kWorkspaceTabsByAccount, jsonEncode(map));
    }
  }

  Map<String, dynamic> _serializeAccountWorkspace(AccountWorkspace aw) => {
    'tabs': aw.tabs.map(_serializeTab).toList(),
    'activeId': aw.activeId,
  };

  Map<String, dynamic> _serializeTab(WorkspaceTab t) => {
    'id': t.id,
    'kind': t.kind.name,
    'title': t.title,
    if (t.subtitle != null) 'subtitle': t.subtitle,
    if (t.projectFullName != null) 'projectFullName': t.projectFullName,
    if (t.projectKind != null) 'projectKind': t.projectKind,
  };

  AccountWorkspace? _deserializeAccountWorkspace(dynamic raw) {
    if (raw is! Map) return null;
    final map = Map<String, dynamic>.from(raw);
    final tabsRaw = map['tabs'];
    final activeId = map['activeId'] as String? ?? '';
    if (tabsRaw is! List) return null;
    final tabs = <WorkspaceTab>[];
    for (final item in tabsRaw) {
      if (item is Map) {
        final t = _deserializeTab(Map<String, dynamic>.from(item));
        if (t != null) tabs.add(t);
      }
    }
    return _sanitizeRestored(AccountWorkspace(tabs: tabs, activeId: activeId));
  }

  WorkspaceTab? _deserializeTab(Map<String, dynamic> m) {
    final kindStr = m['kind'] as String?;
    final kind = switch (kindStr) {
      'project' => WorkspaceTabKind.project,
      'settings' => WorkspaceTabKind.settings,
      _ => null,
    };
    if (kind == null) return null;
    final id = m['id'] as String?;
    if (id == null || id.isEmpty) return null;
    final title = m['title'] as String? ?? '';
    if (kind == WorkspaceTabKind.project) {
      final fn = m['projectFullName'] as String?;
      if (fn == null || fn.isEmpty) return null;
    }
    return WorkspaceTab(
      id: id,
      kind: kind,
      title: title,
      subtitle: m['subtitle'] as String?,
      projectFullName: m['projectFullName'] as String?,
      projectKind: m['projectKind'] as String?,
    );
  }

  AccountWorkspace _sanitizeRestored(AccountWorkspace aw) {
    if (aw.tabs.isEmpty) return AccountWorkspace.seed();
    final ids = aw.tabs.map((t) => t.id).toSet();
    var aid = aw.activeId;
    if (aid.isEmpty || !ids.contains(aid)) {
      aid = aw.tabs.first.id;
    }
    return AccountWorkspace(tabs: aw.tabs, activeId: aid);
  }

  void _persistWorkspaceStrip() {
    final prefs = ref.read(sharedPreferencesProvider);
    final opened = state.openedAccountIds;
    final active = state.activeAccountId;
    if (opened.isEmpty) {
      prefs.remove(_kOpenedAccountIds);
      prefs.remove(_kWorkspaceActiveAccountId);
      return;
    }
    prefs.setStringList(_kOpenedAccountIds, opened);
    if (active != null && opened.contains(active)) {
      prefs.setString(_kWorkspaceActiveAccountId, active);
    } else if (opened.isNotEmpty) {
      prefs.setString(_kWorkspaceActiveAccountId, opened.first);
    }
  }

  /// 由移动端 [WorkspaceShell] 在挂载/卸载时切换。
  void setMobileStripMirrorsAllAccounts(bool enabled) {
    if (_mobileStripMirrorsAllAccounts == enabled) return;
    _mobileStripMirrorsAllAccounts = enabled;
    final accounts = ref.read(jenkinsAccountsProvider).value;
    if (accounts != null) _syncAccounts(accounts);
  }

  @override
  WorkspaceState build() {
    // 监听后续账号变化（不开 fireImmediately —— 那会在 state 尚未赋值时回调）。
    ref.listen<AsyncValue<JenkinsAccountsState>>(jenkinsAccountsProvider, (
      prev,
      next,
    ) {
      final value = next.value;
      if (value == null) return;
      _syncAccounts(value);
    });
    // 初次构建：直接用账号 provider 当前 value（可能尚未 ready）派生。
    final accounts = ref.read(jenkinsAccountsProvider).value;
    if (accounts == null) {
      return const WorkspaceState(
        byAccount: {},
        openedAccountIds: [],
        activeAccountId: null,
      );
    }
    return _seedFromAccounts(accounts);
  }

  ({List<String> opened, String? active}) _readStripFromPrefs(
    Set<String> validIds,
  ) {
    final prefs = ref.read(sharedPreferencesProvider);
    final savedOpened = prefs.getStringList(_kOpenedAccountIds) ?? const [];
    final savedActive = prefs.getString(_kWorkspaceActiveAccountId);
    var opened = savedOpened.where(validIds.contains).toList();
    String? active = savedActive != null && validIds.contains(savedActive)
        ? savedActive
        : null;
    if (opened.isEmpty) {
      active = null;
    } else if (active == null || !opened.contains(active)) {
      active = opened.first;
    }
    return (opened: opened, active: active);
  }

  WorkspaceState _seedFromAccounts(JenkinsAccountsState accounts) {
    final loadedTabs = _readTabsFromPrefs();
    final byAccount = <String, AccountWorkspace>{};
    for (final a in accounts.accounts) {
      byAccount[a.id] = loadedTabs[a.id] ?? AccountWorkspace.seed();
    }
    final validIds = accounts.accounts.map((a) => a.id).toSet();
    final restored = _readStripFromPrefs(validIds);
    _workspaceStripRestored = true;

    if (restored.active != null && accounts.activeId != restored.active) {
      unawaited(
        ref.read(jenkinsAccountsProvider.notifier).setActive(restored.active!),
      );
    }

    return WorkspaceState(
      byAccount: byAccount,
      openedAccountIds: restored.opened,
      activeAccountId: restored.active,
    );
  }

  void _syncAccounts(JenkinsAccountsState accounts) {
    final validIds = accounts.accounts.map((a) => a.id).toSet();
    final orderedAllIds = accounts.accounts.map((a) => a.id).toList();
    final loadedTabs = _readTabsFromPrefs();
    final nextByAccount = <String, AccountWorkspace>{};
    for (final entry in state.byAccount.entries) {
      if (validIds.contains(entry.key)) nextByAccount[entry.key] = entry.value;
    }
    for (final id in validIds) {
      nextByAccount.putIfAbsent(
        id,
        () => loadedTabs[id] ?? AccountWorkspace.seed(),
      );
    }

    final prevOpenedSet = state.openedAccountIds.toSet();

    late List<String> opened;
    late String? active;

    if (!_workspaceStripRestored && state.openedAccountIds.isEmpty) {
      _workspaceStripRestored = true;
      if (_mobileStripMirrorsAllAccounts && orderedAllIds.isNotEmpty) {
        opened = orderedAllIds;
        active =
            accounts.activeId != null &&
                orderedAllIds.contains(accounts.activeId)
            ? accounts.activeId
            : orderedAllIds.first;
      } else {
        final restored = _readStripFromPrefs(validIds);
        opened = restored.opened;
        active = restored.active;
      }
    } else {
      _workspaceStripRestored = true;
      if (_mobileStripMirrorsAllAccounts) {
        opened = orderedAllIds;
        active = state.activeAccountId;
        if (active == null || !opened.contains(active)) {
          active =
              accounts.activeId != null && opened.contains(accounts.activeId)
              ? accounts.activeId
              : (opened.isNotEmpty ? opened.first : null);
        }
      } else {
        opened = state.openedAccountIds.where(validIds.contains).toList();
        active = state.activeAccountId;
        if (opened.isEmpty) {
          active = null;
        } else if (active == null || !opened.contains(active)) {
          active = opened.first;
        }
      }
    }

    if (_mobileStripMirrorsAllAccounts) {
      for (final id in opened) {
        if (!prevOpenedSet.contains(id)) {
          ref.read(jenkinsTreeReloadSignalProvider.notifier).bump(id);
        }
      }
    }

    final prevJenkinsActive = accounts.activeId;
    state = WorkspaceState(
      byAccount: nextByAccount,
      openedAccountIds: opened,
      activeAccountId: active,
    );
    _persistWorkspaceStrip();
    _persistWorkspaceTabs();

    if (active != null && prevJenkinsActive != active) {
      unawaited(ref.read(jenkinsAccountsProvider.notifier).setActive(active));
    }
  }

  /// 在一级栏打开（或激活）某个已配置的 Jenkins 账号。
  Future<void> openAccountInStrip(String accountId) async {
    final accounts = ref.read(jenkinsAccountsProvider).value;
    if (accounts == null || !accounts.accounts.any((a) => a.id == accountId)) {
      return;
    }

    final wasAlreadyOpen = state.openedAccountIds.contains(accountId);
    var opened = [...state.openedAccountIds];
    if (!opened.contains(accountId)) {
      opened = [...opened, accountId];
    }

    await ref.read(jenkinsAccountsProvider.notifier).setActive(accountId);
    if (!ref.mounted) return;
    state = state.copyWith(
      openedAccountIds: opened,
      activeAccountId: accountId,
    );
    _persistWorkspaceStrip();

    // 关闭一级标签后已无侧栏 listener，仅在关闭时 bump 可能不会触发 family 重建。
    // 在「重新加入一级栏」时再 bump，此时必定 watch 树，强制重新请求 Jenkins。
    if (!wasAlreadyOpen) {
      ref.read(jenkinsTreeReloadSignalProvider.notifier).bump(accountId);
    }
  }

  /// 切换一级栏当前账号（须在已打开列表中）。
  Future<void> activateAccountInStrip(String accountId) async {
    if (!state.openedAccountIds.contains(accountId)) return;
    await ref.read(jenkinsAccountsProvider.notifier).setActive(accountId);
    if (!ref.mounted) return;
    state = state.copyWith(activeAccountId: accountId);
    _persistWorkspaceStrip();
  }

  /// 从一级栏移除某个账号（不删除 Jenkins 配置）。
  void closeAccountInStrip(String accountId) {
    final opened = [...state.openedAccountIds];
    final idx = opened.indexOf(accountId);
    if (idx < 0) return;
    opened.removeAt(idx);

    String? active = state.activeAccountId;
    if (active == accountId) {
      if (opened.isEmpty) {
        active = null;
      } else {
        active = opened[idx.clamp(0, opened.length - 1)];
      }
    }

    state = state.copyWith(openedAccountIds: opened, activeAccountId: active);
    _persistWorkspaceStrip();

    if (active != null) {
      unawaited(ref.read(jenkinsAccountsProvider.notifier).setActive(active));
    }
  }

  /// 在当前激活账号下打开（或激活）一个 tab。
  void openTab(WorkspaceTab tab) {
    _mutateActive((aw) {
      final existing = aw.tabs.indexWhere((t) => t.id == tab.id);
      if (existing >= 0) {
        return aw.copyWith(activeId: tab.id);
      }
      return aw.copyWith(tabs: [...aw.tabs, tab], activeId: tab.id);
    });
  }

  void activate(String id) {
    final aid = state.activeAccountId;
    if (aid == null) return;
    activateTabForAccount(aid, id);
  }

  /// 切换指定账号工作区内的二级 tab。
  void activateTabForAccount(String accountId, String tabId) {
    _mutateAccount(accountId, (aw) {
      if (!aw.tabs.any((t) => t.id == tabId)) return aw;
      return aw.copyWith(activeId: tabId);
    });
  }

  void closeTab(String id) {
    final aid = state.activeAccountId;
    if (aid == null) return;
    closeTabForAccount(aid, id);
  }

  void closeTabForAccount(String accountId, String tabId) {
    WorkspaceTab? closing;
    final current = state.byAccount[accountId];
    if (current != null) {
      for (final t in current.tabs) {
        if (t.id == tabId) {
          closing = t;
          break;
        }
      }
    }
    _mutateAccount(accountId, (aw) {
      final idx = aw.tabs.indexWhere((t) => t.id == tabId);
      if (idx < 0) return aw;
      final next = [...aw.tabs]..removeAt(idx);
      if (next.isEmpty) {
        return AccountWorkspace.seed();
      }
      final wasActive = aw.activeId == tabId;
      final newActive = wasActive
          ? next[idx.clamp(0, next.length - 1)].id
          : aw.activeId;
      return AccountWorkspace(tabs: next, activeId: newActive);
    });
    if (closing != null) {
      _invalidateProjectDetailsForTabs(accountId, [closing]);
    }
  }

  /// 关闭标签后丢弃详情缓存，下次从树里再打开同一 Job 会重新请求 Jenkins。
  ///
  /// 多分支目录下还会根据已缓存的 folder 详情失效各子 Job 的 [projectDetailProvider]，
  /// 避免仅清目录而分支参数页仍命中旧缓存。
  void _invalidateProjectDetailsForTabs(
    String accountId,
    Iterable<WorkspaceTab> tabs,
  ) {
    for (final t in tabs) {
      if (t.kind != WorkspaceTabKind.project) continue;
      final fullName = t.projectFullName;
      if (fullName == null || fullName.isEmpty) continue;
      final repo = ref.read(jenkinsRepositoryForAccountProvider(accountId));
      final folderKey = (accountId: accountId, fullName: fullName);
      final runTabsKey = (accountId: accountId, fullName: fullName);
      ref.read(projectRunTabsProvider(runTabsKey).notifier).disposeRuns();
      ref.invalidate(projectRunTabsProvider(runTabsKey));
      final cached = ref.read(projectDetailProvider(folderKey));
      cached.maybeWhen(
        data: (detail) {
          for (final node in detail.subJobs) {
            repo?.invalidateJobDetailCaches(node.fullName);
            ref.invalidate(
              projectDetailProvider((
                accountId: accountId,
                fullName: node.fullName,
              )),
            );
          }
        },
        orElse: () {},
      );
      repo?.invalidateJobDetailCaches(fullName);
      ref.invalidate(projectDetailProvider(folderKey));
    }
  }

  void closeOthers(String id) {
    final aid = state.activeAccountId;
    if (aid == null) return;
    final aw = state.byAccount[aid];
    if (aw != null) {
      final removed = aw.tabs.where((t) => t.id != id).toList();
      _invalidateProjectDetailsForTabs(aid, removed);
    }
    _mutateActive((aw) {
      final keep = aw.tabs.where((t) => t.id == id).toList();
      if (keep.isEmpty) return aw;
      return AccountWorkspace(tabs: keep, activeId: id);
    });
  }

  void closeAll() {
    final aid = state.activeAccountId;
    if (aid == null) return;
    final aw = state.byAccount[aid];
    if (aw != null) {
      _invalidateProjectDetailsForTabs(aid, aw.tabs);
    }
    _mutateActive((_) => AccountWorkspace.seed());
  }

  void reorderTab(int oldIndex, int newIndex) {
    _mutateActive((aw) {
      if (oldIndex < 0 || oldIndex >= aw.tabs.length) return aw;
      var insert = newIndex;
      if (insert > oldIndex) insert -= 1;
      insert = insert.clamp(0, aw.tabs.length - 1);
      final next = [...aw.tabs];
      final moved = next.removeAt(oldIndex);
      next.insert(insert, moved);
      return aw.copyWith(tabs: next);
    });
  }

  void _mutateActive(AccountWorkspace Function(AccountWorkspace) update) {
    final aid = state.activeAccountId;
    if (aid == null) return;
    _mutateAccount(aid, update);
  }

  void _mutateAccount(
    String accountId,
    AccountWorkspace Function(AccountWorkspace) update,
  ) {
    final current = state.byAccount[accountId] ?? AccountWorkspace.seed();
    final next = update(current);
    if (identical(next, current)) return;
    final map = {...state.byAccount, accountId: next};
    state = state.copyWith(byAccount: map);
    _persistWorkspaceTabs();
  }
}

final workspaceProvider = NotifierProvider<WorkspaceController, WorkspaceState>(
  WorkspaceController.new,
);
