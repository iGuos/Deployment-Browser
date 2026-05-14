import 'package:flutter/foundation.dart';

import '../../../core/http/jenkins_http_client.dart';

/// Jenkins 服务连接配置（不可变值对象）。
@immutable
class JenkinsConfig {
  const JenkinsConfig({
    required this.baseUrl,
    required this.username,
    required this.secret,
    required this.authKind,
  });

  final String baseUrl;
  final String username;
  final String secret;
  final JenkinsAuthKind authKind;

  bool get isComplete =>
      baseUrl.trim().isNotEmpty && username.trim().isNotEmpty && secret.trim().isNotEmpty;

  JenkinsCredentials toCredentials() => JenkinsCredentials(
        username: username.trim(),
        secret: secret,
        kind: authKind,
      );

  String get displayHost {
    final stripped = baseUrl.replaceFirst(RegExp(r'^https?://'), '');
    return stripped.endsWith('/') ? stripped.substring(0, stripped.length - 1) : stripped;
  }

  JenkinsConfig copyWith({
    String? baseUrl,
    String? username,
    String? secret,
    JenkinsAuthKind? authKind,
  }) {
    return JenkinsConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      username: username ?? this.username,
      secret: secret ?? this.secret,
      authKind: authKind ?? this.authKind,
    );
  }

  Map<String, String> toPlainJson() => {
        'baseUrl': baseUrl,
        'username': username,
        'authKind': authKind.name,
      };

  static JenkinsConfig? fromPartial({
    String? baseUrl,
    String? username,
    String? secret,
    String? authKind,
  }) {
    if ((baseUrl ?? '').isEmpty || (username ?? '').isEmpty || (secret ?? '').isEmpty) {
      return null;
    }
    return JenkinsConfig(
      baseUrl: baseUrl!,
      username: username!,
      secret: secret!,
      authKind: switch (authKind) {
        'password' => JenkinsAuthKind.password,
        _ => JenkinsAuthKind.token,
      },
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JenkinsConfig &&
          other.baseUrl == baseUrl &&
          other.username == username &&
          other.secret == secret &&
          other.authKind == authKind);

  @override
  int get hashCode => Object.hash(baseUrl, username, secret, authKind);
}
