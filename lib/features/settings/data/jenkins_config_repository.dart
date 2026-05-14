import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/jenkins_config.dart';
import 'jenkins_accounts_repository.dart';

/// 当前激活账号的 [JenkinsConfig]（不存在则为 null）。
///
/// 这里保留旧名是为了让现有所有 `ref.watch(jenkinsConfigProvider).value` 调用
/// 无缝过渡到多账号模型；真实的存储与状态全部转移到 [jenkinsAccountsProvider]。
final jenkinsConfigProvider = Provider<AsyncValue<JenkinsConfig?>>((ref) {
  final accountsAsync = ref.watch(jenkinsAccountsProvider);
  return accountsAsync.when(
    data: (s) => AsyncValue.data(s.activeAccount?.config),
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
  );
});
