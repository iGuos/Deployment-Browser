/// Git 引用类型。
///
/// 排序原则：[branch] 与 [tag] 是 UI 上可独立筛选的两大主类；
/// [revision] 表示具体提交（SHA）；[unknown] 用于无法可靠判断的历史值。
enum RefType { branch, tag, revision, unknown }

/// 分支 / Tag 候选项（带类型）。
///
/// 仅用于 Git Parameter 类分支参数的下拉候选；choice 类参数仍走纯字符串列表。
class RefOption {
  const RefOption(this.value, this.type);

  final String value;
  final RefType type;

  RefOption copyWith({String? value, RefType? type}) =>
      RefOption(value ?? this.value, type ?? this.type);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RefOption && other.value == value && other.type == type);

  @override
  int get hashCode => Object.hash(value, type);

  @override
  String toString() => 'RefOption($value, ${type.name})';
}

final RegExp _semverLike = RegExp(r'^v?\d+\.\d+(\.\d+)?([.+\-].+)?$');
final RegExp _shaLike = RegExp(r'^[0-9a-f]{7,40}$');

/// 启发式推断 git 引用类型。
///
/// 优先级：
/// 1. 显式前缀（`refs/tags/`, `tags/`, `refs/heads/`, `origin/`）
/// 2. plugin 在 [pluginName] 里塞的标签（如 `[Tag] v1.0` / `[Branch] main`）
/// 3. 字面启发式（语义化版本号 → tag；7-40 位 hex → revision；含 `/` → branch）
RefType detectRefType(String value, {String? pluginName}) {
  if (value.isEmpty) return RefType.unknown;
  final v = value.trim();
  final lower = v.toLowerCase();

  if (lower.startsWith('refs/tags/') || lower.startsWith('tags/')) {
    return RefType.tag;
  }
  if (lower.startsWith('refs/heads/') || lower.startsWith('origin/')) {
    return RefType.branch;
  }
  if (lower.startsWith('refs/remotes/')) return RefType.branch;

  if (pluginName != null && pluginName.isNotEmpty) {
    final pl = pluginName.toLowerCase();
    if (pl.contains('[tag]') || pl.contains('tag:')) return RefType.tag;
    if (pl.contains('[branch]') || pl.contains('branch:')) return RefType.branch;
    if (pl.contains('[revision]') || pl.contains('rev:')) return RefType.revision;
  }

  if (_shaLike.hasMatch(lower)) return RefType.revision;
  if (_semverLike.hasMatch(v)) return RefType.tag;
  if (v.contains('/')) return RefType.branch;

  // 单段裸字符串（main / develop / next）大概率是分支
  return RefType.branch;
}

/// 去掉常见前缀，返回更友好的展示字符串。
String displayRef(String value) {
  for (final prefix in const [
    'refs/tags/',
    'refs/heads/',
    'refs/remotes/',
    'origin/',
  ]) {
    if (value.startsWith(prefix)) return value.substring(prefix.length);
  }
  if (value.startsWith('tags/')) return value.substring(5);
  return value;
}
