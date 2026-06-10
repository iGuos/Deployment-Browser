import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/storage/encrypted_secret_store.dart';
import '../../../core/storage/preferences.dart';
import '../../../core/utils/app_logger.dart';
import '../../../core/utils/duration_formatter.dart';
import '../../jenkins/domain/jenkins_build.dart';

// ── 持久化键 ──────────────────────────────────────────────
const _kRecipientsV1 = 'slack.recipients_v1';
const _kRecipientLegacy = 'slack.recipient'; // 旧版单接收人，仅用于迁移
const _kNotifySuccess = 'slack.notify_success';
const _kNotifyFailure = 'slack.notify_failure';
const _kSuccessTemplate = 'slack.success_template';
const _kFailureTemplate = 'slack.failure_template';
const _kHasToken = 'slack.has_token';

/// 构建结束通知文案的默认模板。支持占位符（见 [renderSlackMessage]）：
/// `{emoji}` `{job}` `{number}` `{result}` `{duration}` `{url}`。
const kDefaultSlackSuccessTemplate = '✅ *{job}* #{number} {result}';
const kDefaultSlackFailureTemplate = '❌ *{job}* #{number} {result}';

/// 把模板里的占位符替换成本次构建的实际值；模板为空白时回退到 [fallback]。
String renderSlackMessage(
  String template, {
  required String job,
  required int number,
  required String result,
  required String emoji,
  required String duration,
  required String url,
  required String fallback,
}) {
  final t = template.trim().isEmpty ? fallback : template;
  return t
      .replaceAll('{emoji}', emoji)
      .replaceAll('{job}', job)
      .replaceAll('{number}', number.toString())
      .replaceAll('{result}', result)
      .replaceAll('{duration}', duration)
      .replaceAll('{url}', url);
}

/// Slack user token 在加密存储里的逻辑键。
const _kSlackTokenKey = 'slack.user_token';

/// 一个接收人（Slack 用户 / 会话）。
@immutable
class SlackRecipient {
  const SlackRecipient(this.id, this.label, {this.email = ''});

  /// 用户 ID（U…）、会话 ID（C/D/G…）。
  final String id;

  /// 展示名（用于 UI chip）。
  final String label;

  /// 邮箱（需要 users:read.email 权限才有值）。
  final String email;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        if (email.isNotEmpty) 'email': email,
      };

  factory SlackRecipient.fromJson(Map<String, dynamic> j) => SlackRecipient(
        (j['id'] as String?) ?? '',
        (j['label'] as String?) ?? '',
        email: (j['email'] as String?) ?? '',
      );

  @override
  bool operator ==(Object other) =>
      other is SlackRecipient && other.id == id;
  @override
  int get hashCode => id.hashCode;
}

/// Slack 通知配置（不含 token 本身；token 单独走加密存储）。
@immutable
class SlackConfig {
  const SlackConfig({
    this.recipients = const [],
    this.notifySuccess = true,
    this.notifyFailure = true,
    this.successTemplate = kDefaultSlackSuccessTemplate,
    this.failureTemplate = kDefaultSlackFailureTemplate,
    this.hasToken = false,
  });

  /// 候选接收人池（设置里配置的「可能发送的人」）。实际发给谁在发版页按次选择。
  final List<SlackRecipient> recipients;
  final bool notifySuccess;
  final bool notifyFailure;

  /// 成功 / 失败时的自定义消息模板（支持占位符，见 [renderSlackMessage]）。
  final String successTemplate;
  final String failureTemplate;

  /// 是否已保存 token（用于 UI 显示「已连接」，不必解密）。
  final bool hasToken;

  /// 已可用于发版页选择：有 token + 候选池非空。
  bool get isConfigured => hasToken && recipients.isNotEmpty;

  SlackConfig copyWith({
    List<SlackRecipient>? recipients,
    bool? notifySuccess,
    bool? notifyFailure,
    String? successTemplate,
    String? failureTemplate,
    bool? hasToken,
  }) {
    return SlackConfig(
      recipients: recipients ?? this.recipients,
      notifySuccess: notifySuccess ?? this.notifySuccess,
      notifyFailure: notifyFailure ?? this.notifyFailure,
      successTemplate: successTemplate ?? this.successTemplate,
      failureTemplate: failureTemplate ?? this.failureTemplate,
      hasToken: hasToken ?? this.hasToken,
    );
  }
}

class SlackConfigController extends Notifier<SlackConfig> {
  late final SharedPreferences _prefs;

  @override
  SlackConfig build() {
    _prefs = ref.watch(sharedPreferencesProvider);
    return SlackConfig(
      recipients: _readRecipients(),
      notifySuccess: _prefs.getBool(_kNotifySuccess) ?? true,
      notifyFailure: _prefs.getBool(_kNotifyFailure) ?? true,
      successTemplate:
          _prefs.getString(_kSuccessTemplate) ?? kDefaultSlackSuccessTemplate,
      failureTemplate:
          _prefs.getString(_kFailureTemplate) ?? kDefaultSlackFailureTemplate,
      hasToken: _prefs.getBool(_kHasToken) ?? false,
    );
  }

  List<SlackRecipient> _readRecipients() {
    final raw = _prefs.getString(_kRecipientsV1);
    if (raw != null && raw.isNotEmpty) {
      try {
        final list = jsonDecode(raw);
        if (list is List) {
          return list
              .whereType<Map>()
              .map((e) => SlackRecipient.fromJson(e.cast<String, dynamic>()))
              .where((r) => r.id.isNotEmpty)
              .toList();
        }
      } catch (_) {/* fallthrough */}
    }
    // 迁移旧版单接收人。
    final legacy = _prefs.getString(_kRecipientLegacy);
    if (legacy != null && legacy.trim().isNotEmpty) {
      return [SlackRecipient(legacy.trim(), legacy.trim())];
    }
    return const [];
  }

  Future<void> setRecipients(List<SlackRecipient> recipients) async {
    state = state.copyWith(recipients: recipients);
    await _prefs.setString(
      _kRecipientsV1,
      jsonEncode(recipients.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> setNotifySuccess(bool v) async {
    state = state.copyWith(notifySuccess: v);
    await _prefs.setBool(_kNotifySuccess, v);
  }

  Future<void> setNotifyFailure(bool v) async {
    state = state.copyWith(notifyFailure: v);
    await _prefs.setBool(_kNotifyFailure, v);
  }

  Future<void> setSuccessTemplate(String v) async {
    state = state.copyWith(successTemplate: v);
    await _prefs.setString(_kSuccessTemplate, v);
  }

  Future<void> setFailureTemplate(String v) async {
    state = state.copyWith(failureTemplate: v);
    await _prefs.setString(_kFailureTemplate, v);
  }

  /// 保存（或清除）user token；空串视为清除。token 变更后清空成员缓存。
  Future<void> saveToken(String token) async {
    final store = ref.read(encryptedSecretStoreProvider);
    final trimmed = token.trim();
    ref.read(slackNotifierProvider).clearUsersCache();
    if (trimmed.isEmpty) {
      await store.delete(_kSlackTokenKey);
      state = state.copyWith(hasToken: false);
      await _prefs.setBool(_kHasToken, false);
      return;
    }
    await store.write(_kSlackTokenKey, trimmed);
    state = state.copyWith(hasToken: true);
    await _prefs.setBool(_kHasToken, true);
  }

  Future<String?> readToken() =>
      ref.read(encryptedSecretStoreProvider).read(_kSlackTokenKey);
}

final slackConfigProvider =
    NotifierProvider<SlackConfigController, SlackConfig>(SlackConfigController.new);

/// 调用 Slack Web API（以**用户 token** 身份，消息显示为本人，非 bot）。
class SlackApi {
  SlackApi(String token)
      : _dio = Dio(BaseOptions(
          baseUrl: 'https://slack.com/api',
          headers: {'Authorization': 'Bearer $token'},
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 20),
          validateStatus: (s) => s != null && s < 500,
        ));

  final Dio _dio;

  void close() => _dio.close(force: true);

  Future<Map<String, dynamic>> _call(String method, Map<String, dynamic> form) async {
    final res = await _dio.post<dynamic>(
      '/$method',
      data: form,
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = res.data;
    if (data is Map) return data.cast<String, dynamic>();
    throw SlackException('返回非预期格式');
  }

  /// 拉取工作区成员列表（供 UI 多选）。需要 user scope `users:read`。
  /// 过滤掉 bot / 已停用 / Slackbot；按展示名排序；分页最多取若干页。
  Future<List<SlackRecipient>> listUsers() async {
    final out = <SlackRecipient>[];
    String cursor = '';
    var pages = 0;
    do {
      final res = await _call('users.list', {
        'limit': '200',
        if (cursor.isNotEmpty) 'cursor': cursor,
      });
      if (res['ok'] != true) {
        throw SlackException('拉取成员失败：${slackErrorHint(res['error'] as String?)}');
      }
      final members = (res['members'] as List?) ?? const [];
      for (final m in members.whereType<Map>()) {
        if (m['deleted'] == true || m['is_bot'] == true) continue;
        final id = (m['id'] as String?) ?? '';
        if (id.isEmpty || id == 'USLACKBOT') continue;
        final profile = (m['profile'] as Map?)?.cast<String, dynamic>() ?? const {};
        final display = (profile['display_name'] as String?)?.trim();
        final real = (profile['real_name'] as String?)?.trim() ??
            (m['real_name'] as String?)?.trim();
        final name = (m['name'] as String?)?.trim();
        final label = (display != null && display.isNotEmpty)
            ? display
            : (real != null && real.isNotEmpty ? real : (name ?? id));
        final email = (profile['email'] as String?)?.trim() ?? '';
        out.add(SlackRecipient(id, label, email: email));
      }
      cursor = ((res['response_metadata'] as Map?)?['next_cursor'] as String?) ?? '';
      pages++;
    } while (cursor.isNotEmpty && pages < 20);
    out.sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return out;
  }

  /// 把接收人解析成可投递的 channel/DM id。
  Future<String> resolveChannel(String idOrEmail) async {
    final r = idOrEmail.trim();
    if (r.isEmpty) throw SlackException('接收人为空');
    if (r.startsWith('C') || r.startsWith('D') || r.startsWith('G')) return r;

    String userId = r;
    if (r.contains('@') && r.contains('.')) {
      final look = await _call('users.lookupByEmail', {'email': r});
      if (look['ok'] != true) {
        throw SlackException('按邮箱找不到用户：${slackErrorHint(look['error'] as String?)}');
      }
      userId = (look['user'] as Map?)?['id'] as String? ?? '';
      if (userId.isEmpty) throw SlackException('按邮箱找不到用户');
    }
    final open = await _call('conversations.open', {'users': userId});
    if (open['ok'] != true) {
      throw SlackException('打开私信失败：${slackErrorHint(open['error'] as String?)}');
    }
    final ch = (open['channel'] as Map?)?['id'] as String?;
    if (ch == null || ch.isEmpty) throw SlackException('打开私信失败');
    return ch;
  }

  Future<void> postMessage({required String channel, required String text}) async {
    final res = await _call('chat.postMessage', {'channel': channel, 'text': text});
    if (res['ok'] != true) {
      throw SlackException('发送失败：${slackErrorHint(res['error'] as String?)}');
    }
  }

  /// 校验 token 是否有效,并从 `x-oauth-scopes` 响应头读取已授予的 scopes。
  Future<SlackAuth> authTest() async {
    final res = await _dio.post<dynamic>(
      '/auth.test',
      options: Options(contentType: Headers.formUrlEncodedContentType),
    );
    final data = (res.data is Map)
        ? (res.data as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final header = res.headers.value('x-oauth-scopes') ?? '';
    final scopes = header
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    return SlackAuth(
      ok: data['ok'] == true,
      error: data['error'] as String?,
      user: data['user'] as String?,
      team: data['team'] as String?,
      scopes: scopes,
    );
  }
}

class SlackException implements Exception {
  SlackException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// 把 Slack 的 error code 映射成可读提示。
String slackErrorHint(String? code) {
  switch (code) {
    case 'missing_scope':
      return 'token 缺少所需权限。请在 Slack App 的 User Token Scopes 里补上 '
          'users:read / chat:write / im:write,然后“重新安装(Reinstall)”并更新 token。';
    case 'invalid_auth':
    case 'not_authed':
    case 'token_revoked':
    case 'token_expired':
      return 'token 无效或已失效,请重新生成并更新。';
    case 'account_inactive':
      return 'Slack 账号已停用。';
    case 'channel_not_found':
    case 'users_not_found':
      return '找不到该用户 / 会话。';
    case 'cannot_dm_bot':
      return '不能给 bot 发私信。';
    case null:
    case '':
      return '未知错误';
    default:
      return code;
  }
}

/// `auth.test` 结果 + 已授予的 user scopes（来自 x-oauth-scopes 响应头）。
class SlackAuth {
  SlackAuth({
    required this.ok,
    this.error,
    this.user,
    this.team,
    this.scopes = const {},
  });

  final bool ok;
  final String? error;
  final String? user;
  final String? team;
  final Set<String> scopes;

  /// 本工具所需的 user scopes。
  static const requiredScopes = {'chat:write', 'im:write', 'users:read'};

  List<String> get missingScopes =>
      requiredScopes.where((s) => !scopes.contains(s)).toList();
}

/// 高层发送器：构建结束时按配置发 Slack 私信；也供「拉取成员 / 测试发送」。
class SlackNotifier {
  SlackNotifier(this._ref);
  final Ref _ref;

  /// 成员列表内存缓存（进程级；应用重启自然失效）。成员变动不频繁,默认走缓存。
  List<SlackRecipient>? _usersCache;

  /// 清空成员缓存（token 变更时调用）。
  void clearUsersCache() => _usersCache = null;

  /// 校验连接 + 权限：token 是否有效、以哪个用户、缺哪些 scope。
  Future<SlackAuth> checkConnection() async {
    final token = await _ref.read(slackConfigProvider.notifier).readToken();
    if (token == null || token.isEmpty) {
      throw SlackException('未配置 Slack token');
    }
    final api = SlackApi(token);
    try {
      return await api.authTest();
    } on DioException catch (e) {
      throw SlackException('网络错误: ${e.message}');
    } finally {
      api.close();
    }
  }

  /// 供 UI 多选用：拉取工作区成员。默认命中内存缓存;[forceRefresh] 强制重拉。
  Future<List<SlackRecipient>> fetchUsers({bool forceRefresh = false}) async {
    final cached = _usersCache;
    if (!forceRefresh && cached != null) return cached;
    final token = await _ref.read(slackConfigProvider.notifier).readToken();
    if (token == null || token.isEmpty) {
      throw SlackException('未配置 Slack token');
    }
    final api = SlackApi(token);
    try {
      final users = await api.listUsers();
      _usersCache = users;
      return users;
    } on DioException catch (e) {
      throw SlackException('网络错误: ${e.message}');
    } finally {
      api.close();
    }
  }

  /// 构建结束回调：发给本次发版选定的 [recipients]（为空则不发）。
  /// 成功/失败仍按设置里的开关过滤。失败仅记日志、不打扰主流程。
  Future<void> notifyBuildResult({
    required List<SlackRecipient> recipients,
    required String jobFullName,
    required int number,
    required BuildResult result,
    String url = '',
    int durationMillis = 0,
  }) async {
    if (recipients.isEmpty) return;
    final cfg = _ref.read(slackConfigProvider);
    final isSuccess = result == BuildResult.success;
    final isFailure = result == BuildResult.failure ||
        result == BuildResult.unstable ||
        result == BuildResult.aborted;
    if (isSuccess && !cfg.notifySuccess) return;
    if (isFailure && !cfg.notifyFailure) return;
    if (!isSuccess && !isFailure) return;

    final emoji = isSuccess ? '✅' : '❌';
    final word = switch (result) {
      BuildResult.success => '构建成功',
      BuildResult.failure => '构建失败',
      BuildResult.unstable => '构建不稳定',
      BuildResult.aborted => '构建已终止',
      _ => '构建结束',
    };
    final text = renderSlackMessage(
      isSuccess ? cfg.successTemplate : cfg.failureTemplate,
      job: jobFullName,
      number: number,
      result: word,
      emoji: emoji,
      duration: durationMillis > 0 ? formatDurationShort(durationMillis) : '',
      url: url,
      fallback: isSuccess
          ? kDefaultSlackSuccessTemplate
          : kDefaultSlackFailureTemplate,
    );
    try {
      await _sendToAll(recipients, text, stopOnError: false);
    } catch (e) {
      appLogger.w('Slack 通知发送失败（已忽略）: $e');
    }
  }

  /// 测试发送：发给指定一个候选人,失败抛给 UI 提示。
  Future<void> sendTestTo(SlackRecipient recipient) async {
    await _sendToAll([recipient], '🔔 Deployment 测试消息：Slack 通知已接通。',
        stopOnError: true);
  }

  Future<void> _sendToAll(
    List<SlackRecipient> recipients,
    String text, {
    required bool stopOnError,
  }) async {
    final token = await _ref.read(slackConfigProvider.notifier).readToken();
    if (token == null || token.isEmpty) {
      throw SlackException('未配置 Slack token');
    }
    final api = SlackApi(token);
    Object? firstError;
    try {
      for (final r in recipients) {
        try {
          final channel = await api.resolveChannel(r.id);
          await api.postMessage(channel: channel, text: text);
        } on DioException catch (e) {
          final err = SlackException('网络错误: ${e.message}');
          if (stopOnError) throw err;
          firstError ??= err;
          appLogger.w('Slack 发送给 ${r.label} 失败: $err');
        } catch (e) {
          if (stopOnError) rethrow;
          firstError ??= e;
          appLogger.w('Slack 发送给 ${r.label} 失败: $e');
        }
      }
    } finally {
      api.close();
    }
    if (firstError != null && stopOnError) throw firstError;
  }
}

final slackNotifierProvider = Provider<SlackNotifier>((ref) => SlackNotifier(ref));
