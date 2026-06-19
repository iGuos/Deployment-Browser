import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../features/jenkins/data/jenkins_repository.dart';
import '../../../features/jenkins/domain/jenkins_tree_transform.dart';
import '../../../features/settings/data/jenkins_accounts_repository.dart';
import '../application/mcp_server_log_provider.dart';
import '../application/mcp_server_state_provider.dart';
import '../application/mcp_server_status_provider.dart';
import '../core/mcp_server_config.dart';
import '../core/mcp_token.dart';

/// 打开 MCP 接口设置（应用内对话框）。
Future<void> showMcpServerSettings(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const McpServerSettingsDialog(),
  );
}

class McpServerSettingsDialog extends ConsumerStatefulWidget {
  const McpServerSettingsDialog({super.key});

  @override
  ConsumerState<McpServerSettingsDialog> createState() =>
      _McpServerSettingsDialogState();
}

class _McpServerSettingsDialogState
    extends ConsumerState<McpServerSettingsDialog> {
  late final TextEditingController _portController;

  @override
  void initState() {
    super.initState();
    final cfg = ref.read(mcpServerConfigProvider);
    _portController = TextEditingController(
      text: cfg.port > 0 ? '${cfg.port}' : '8765',
    );
  }

  @override
  void dispose() {
    _portController.dispose();
    super.dispose();
  }

  McpServerConfigController get _controller =>
      ref.read(mcpServerConfigProvider.notifier);

  Future<void> _onToggleEnabled(bool value) async {
    if (value) {
      await _controller.update((c) => c.copyWith(enabled: true));
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('关闭 MCP 接口？'),
        content: const Text(
          '关闭后将停止监听，所有 MCP 客户端将立即无法访问。已配置的令牌会保留，重新开启即可恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _controller.update((c) => c.copyWith(enabled: false));
    }
  }

  Future<void> _commitPort() async {
    final raw = int.tryParse(_portController.text.trim()) ?? 0;
    final clamped = (raw >= 1 && raw <= 65535) ? raw : 0;
    if (clamped != ref.read(mcpServerConfigProvider).port) {
      await _controller.update((c) => c.copyWith(port: clamped));
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final cfg = ref.watch(mcpServerConfigProvider);
    final media = MediaQuery.of(context);
    final width = min(620.0, media.size.width - 32);
    final height = media.size.height * 0.86;

    return Dialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(palette),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _enableRow(palette, cfg),
                    if (cfg.enabled) ...[
                      const SizedBox(height: 12),
                      _statusBanner(palette),
                    ],
                    const SizedBox(height: 16),
                    _bindModeRow(palette, cfg),
                    const SizedBox(height: 16),
                    _portRow(palette),
                    const SizedBox(height: 16),
                    _endpointCard(palette, cfg),
                    const SizedBox(height: 20),
                    _tokensSection(palette, cfg),
                    const SizedBox(height: 20),
                    _logsSection(palette),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () async {
                      await _commitPort();
                      if (context.mounted) Navigator.of(context).pop();
                    },
                    child: const Text('关闭'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
      child: Row(
        children: [
          Icon(Icons.hub_outlined, size: 18, color: palette.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'MCP 接口',
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '对外提供标准 MCP（Streamable HTTP）接口，供 Claude 等客户端查询账号/项目、触发与查询发版。',
                  style: TextStyle(color: palette.muted, fontSize: 11.5),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            onPressed: () async {
              await _commitPort();
              if (mounted) Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _enableRow(AppPalette palette, McpServerConfig cfg) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '开启 MCP 接口',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                cfg.tokens.isEmpty
                    ? '开启后需至少创建一个访问令牌，否则所有请求都会被拒绝。'
                    : '已配置 ${cfg.tokens.length} 个访问令牌。',
                style: TextStyle(color: palette.muted, fontSize: 11.5),
              ),
            ],
          ),
        ),
        Switch(
          value: cfg.enabled,
          onChanged: _onToggleEnabled,
        ),
      ],
    );
  }

  Widget _statusBanner(AppPalette palette) {
    final status = ref.watch(mcpServerStatusProvider);
    final (Color color, IconData icon, String text) = status.hasError
        ? (palette.danger, Icons.error_outline, '接口未运行：${status.error}')
        : status.listening
            ? (
                palette.success,
                Icons.check_circle_outline,
                '监听中 · ${status.loopbackOnly ? '127.0.0.1' : '0.0.0.0'}:${status.port}',
              )
            : (palette.warning, Icons.hourglass_empty, '正在启动…');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w500),
            ),
          ),
        ],
      ),
    );
  }

  Widget _bindModeRow(AppPalette palette, McpServerConfig cfg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '监听范围',
          style: TextStyle(
            color: palette.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
              value: true,
              icon: Icon(Icons.computer, size: 15),
              label: Text('仅本机'),
            ),
            ButtonSegment(
              value: false,
              icon: Icon(Icons.lan_outlined, size: 15),
              label: Text('局域网'),
            ),
          ],
          selected: {cfg.listenOnLoopbackOnly},
          onSelectionChanged: (s) => _controller
              .update((c) => c.copyWith(listenOnLoopbackOnly: s.first)),
        ),
        const SizedBox(height: 6),
        Text(
          cfg.listenOnLoopbackOnly
              ? '仅监听 127.0.0.1，只有本机程序可访问。'
              : '监听 0.0.0.0，同一局域网内设备可通过本机 IP 访问（请确保已配置访问令牌）。',
          style: TextStyle(color: palette.muted, fontSize: 11.5),
        ),
      ],
    );
  }

  Widget _portRow(AppPalette palette) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            '监听端口',
            style: TextStyle(
              color: palette.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        SizedBox(
          width: 120,
          child: TextField(
            controller: _portController,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(5),
            ],
            decoration: const InputDecoration(
              isDense: true,
              hintText: '8765',
              border: OutlineInputBorder(),
            ),
            onSubmitted: (_) => _commitPort(),
            onEditingComplete: _commitPort,
          ),
        ),
      ],
    );
  }

  Widget _endpointCard(AppPalette palette, McpServerConfig cfg) {
    final host = cfg.listenOnLoopbackOnly ? '127.0.0.1' : '<本机局域网IP>';
    final port = cfg.port > 0 ? cfg.port : (int.tryParse(_portController.text) ?? 8765);
    final url = 'http://$host:$port/mcp';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.link, size: 14, color: palette.muted),
              const SizedBox(width: 6),
              Text(
                'MCP 端点',
                style: TextStyle(
                  color: palette.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              _copyButton(palette, url),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            url,
            style: TextStyle(
              color: palette.text,
              fontSize: 12.5,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '调用方需在请求头携带：Authorization: Bearer <令牌>（或 X-MCP-Token: <令牌>）。',
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _tokensSection(AppPalette palette, McpServerConfig cfg) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '访问令牌',
              style: TextStyle(
                color: palette.text,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建令牌'),
              onPressed: () => _openTokenEditor(null),
            ),
          ],
        ),
        const SizedBox(height: 4),
        if (cfg.tokens.isEmpty)
          Text(
            '暂无令牌。新建后即可被 MCP 客户端使用。',
            style: TextStyle(color: palette.muted, fontSize: 11.5),
          )
        else
          ...cfg.tokens.map((t) => _tokenCard(palette, t)),
      ],
    );
  }

  Widget _tokenCard(AppPalette palette, McpToken token) {
    final scope = StringBuffer();
    scope.write(token.scopesAllAccounts
        ? '全部账号'
        : '${token.allowedAccountIds.length} 个账号');
    scope.write(' · ');
    scope.write(token.scopesAllProjects
        ? '全部项目'
        : '${token.allowedProjectFullNames.length} 个项目');

    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  token.label.isEmpty ? '(未命名令牌)' : token.label,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _maskSecret(token.secret),
                        style: TextStyle(
                          color: palette.muted,
                          fontSize: 11.5,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  scope.toString(),
                  style: TextStyle(color: palette.muted, fontSize: 11),
                ),
              ],
            ),
          ),
          _copyButton(palette, token.secret, tooltip: '复制令牌'),
          IconButton(
            icon: Icon(Icons.edit_outlined, size: 16, color: palette.muted),
            tooltip: '编辑',
            onPressed: () => _openTokenEditor(token),
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 16, color: palette.danger),
            tooltip: '删除',
            onPressed: () => _confirmDeleteToken(token),
          ),
        ],
      ),
    );
  }

  Widget _logsSection(AppPalette palette) {
    final logs = ref.watch(mcpServerLogProvider);
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text(
          '运行日志（${logs.length}）',
          style: TextStyle(
            color: palette.text,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        children: [
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 160),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: palette.editorBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: logs.isEmpty
                ? Text('暂无日志。',
                    style: TextStyle(color: palette.muted, fontSize: 11.5))
                : SingleChildScrollView(
                    reverse: true,
                    child: SelectableText(
                      logs.join('\n'),
                      style: TextStyle(
                        color: palette.muted,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _copyButton(AppPalette palette, String value, {String? tooltip}) {
    return IconButton(
      icon: Icon(Icons.copy, size: 15, color: palette.muted),
      tooltip: tooltip ?? '复制',
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: value));
        if (mounted) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('已复制到剪贴板'), duration: Duration(seconds: 1)),
          );
        }
      },
    );
  }

  Future<void> _confirmDeleteToken(McpToken token) async {
    final name = token.label.isEmpty ? '(未命名令牌)' : token.label;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除访问令牌？'),
        content: Text(
          '将删除令牌「$name」。删除后使用该令牌的客户端将立即无法访问，此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: context.palette.danger,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _controller.update(
      (c) => c.copyWith(
        tokens:
            c.tokens.where((t) => t.id != token.id).toList(growable: false),
      ),
    );
  }

  Future<void> _openTokenEditor(McpToken? existing) async {
    final result = await showDialog<McpToken>(
      context: context,
      builder: (_) => _McpTokenEditorDialog(existing: existing),
    );
    if (result == null) return;
    await _controller.update((c) {
      final list = [...c.tokens];
      final idx = list.indexWhere((t) => t.id == result.id);
      if (idx >= 0) {
        list[idx] = result;
      } else {
        list.add(result);
      }
      return c.copyWith(tokens: list);
    });
  }

  static String _maskSecret(String secret) {
    if (secret.length <= 8) return '••••••••';
    return '${secret.substring(0, 4)}••••••••${secret.substring(secret.length - 4)}';
  }
}

/// 令牌编辑器：备注名、自动生成的密钥、允许访问的账号与项目。
class _McpTokenEditorDialog extends ConsumerStatefulWidget {
  const _McpTokenEditorDialog({required this.existing});

  final McpToken? existing;

  @override
  ConsumerState<_McpTokenEditorDialog> createState() =>
      _McpTokenEditorDialogState();
}

class _McpTokenEditorDialogState extends ConsumerState<_McpTokenEditorDialog> {
  late final TextEditingController _labelController;
  late String _secret;
  late Set<String> _accounts;
  late Set<String> _projects;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _labelController = TextEditingController(text: e?.label ?? '');
    _secret = e?.secret ?? _generateSecret();
    _accounts = {...?e?.allowedAccountIds};
    _projects = {...?e?.allowedProjectFullNames};
  }

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  static String _generateSecret() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return 'mcp_${base64Url.encode(bytes).replaceAll('=', '')}';
  }

  Future<void> _confirmRegenerate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重新生成令牌密钥？'),
        content: const Text(
          '生成新密钥后，旧密钥将立即失效，所有正在使用旧密钥的客户端都需要更新。此操作不可撤销。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('重新生成'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      setState(() => _secret = _generateSecret());
    }
  }

  void _save() {
    final e = widget.existing;
    final token = McpToken(
      id: e?.id ?? 'tok_${DateTime.now().microsecondsSinceEpoch}',
      label: _labelController.text.trim(),
      secret: _secret,
      allowedAccountIds: _accounts.toList(growable: false),
      // 未选任何账号时项目作用域无意义，强制清空（= 全部）。
      allowedProjectFullNames:
          _accounts.isEmpty ? const [] : _projects.toList(growable: false),
      createdAtMs: e?.createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
    );
    Navigator.of(context).pop(token);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final accountsAsync = ref.watch(jenkinsAccountsProvider);
    final media = MediaQuery.of(context);
    final width = min(560.0, media.size.width - 32);
    final height = media.size.height * 0.82;

    return Dialog(
      backgroundColor: palette.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 12),
              child: Text(
                widget.existing == null ? '新建访问令牌' : '编辑访问令牌',
                style: TextStyle(
                  color: palette.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _labelController,
                      decoration: const InputDecoration(
                        labelText: '备注名',
                        hintText: '例如：CI 机器人 / Claude Desktop',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _secretField(palette),
                    const SizedBox(height: 20),
                    Text(
                      '允许访问的账号',
                      style: TextStyle(
                        color: palette.text,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '不勾选 = 允许全部账号。',
                      style: TextStyle(color: palette.muted, fontSize: 11),
                    ),
                    const SizedBox(height: 8),
                    accountsAsync.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => Text('账号加载失败：$e',
                          style: TextStyle(color: palette.danger, fontSize: 12)),
                      data: (state) => _accountsAndProjects(palette, state),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: _secret.trim().isEmpty ? null : _save,
                    child: const Text('保存'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _secretField(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: palette.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('令牌密钥',
              style: TextStyle(
                  color: palette.muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _secret,
                  style: TextStyle(
                    color: palette.text,
                    fontSize: 12.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              IconButton(
                icon: Icon(Icons.copy, size: 15, color: palette.muted),
                tooltip: '复制',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _secret));
                  if (mounted) {
                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                      const SnackBar(
                        content: Text('已复制令牌'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  }
                },
              ),
              IconButton(
                icon: Icon(Icons.refresh, size: 16, color: palette.muted),
                tooltip: '重新生成',
                onPressed: _confirmRegenerate,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _accountsAndProjects(AppPalette palette, JenkinsAccountsState state) {
    if (state.accounts.isEmpty) {
      return Text('尚未配置任何 Jenkins 账号。',
          style: TextStyle(color: palette.muted, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final a in state.accounts)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: _accounts.contains(a.id),
            title: Text(a.displayName,
                style: TextStyle(color: palette.text, fontSize: 13)),
            subtitle: Text(a.config.displayHost,
                style: TextStyle(color: palette.muted, fontSize: 11)),
            onChanged: (v) => setState(() {
              if (v == true) {
                _accounts.add(a.id);
              } else {
                _accounts.remove(a.id);
              }
            }),
          ),
        if (_accounts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            '允许访问的项目',
            style: TextStyle(
              color: palette.text,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '不勾选 = 允许所选账号下的全部项目。',
            style: TextStyle(color: palette.muted, fontSize: 11),
          ),
          const SizedBox(height: 8),
          for (final id in _accounts) _projectsForAccount(palette, state, id),
        ],
      ],
    );
  }

  Widget _projectsForAccount(
    AppPalette palette,
    JenkinsAccountsState state,
    String accountId,
  ) {
    final account = state.accounts.firstWhere(
      (a) => a.id == accountId,
      orElse: () => state.accounts.first,
    );
    final treeAsync = ref.watch(jenkinsTreeForAccountProvider(accountId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            account.displayName,
            style: TextStyle(
              color: palette.muted,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        treeAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
          error: (e, _) => Text('项目加载失败：$e',
              style: TextStyle(color: palette.danger, fontSize: 11.5)),
          data: (roots) {
            final projects = collectSidebarProjectNodes(roots);
            if (projects.isEmpty) {
              return Text('（无可发版项目）',
                  style: TextStyle(color: palette.muted, fontSize: 11.5));
            }
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in projects)
                  FilterChip(
                    label: Text(p.fullName,
                        style: const TextStyle(fontSize: 11.5)),
                    selected: _projects.contains(p.fullName),
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _projects.add(p.fullName);
                      } else {
                        _projects.remove(p.fullName);
                      }
                    }),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
