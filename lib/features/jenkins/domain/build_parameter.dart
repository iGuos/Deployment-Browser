import 'package:flutter/foundation.dart';

/// 构建参数类型（取自 Jenkins parameterDefinitions）。
enum BuildParameterKind {
  string,
  text,
  boolean,
  choice,
  password,
  run,
  file,
  /// Git Parameter 插件提供的分支/Tag/Revision 参数。
  gitBranch,
  unknown,
}

@immutable
class BuildParameter {
  const BuildParameter({
    required this.name,
    required this.kind,
    required this.defaultValue,
    this.description,
    this.choices = const [],
  });

  final String name;
  final BuildParameterKind kind;

  /// 默认值（Boolean 用 'true'/'false'；Choice 用枚举值之一）
  final String defaultValue;

  final String? description;

  /// 对 [BuildParameterKind.choice] 是必选枚举；对 [BuildParameterKind.gitBranch]
  /// 若插件返回了 `allValueItems` 也会被填进来，作为分支下拉的"已知项"。
  final List<String> choices;

  /// 是否应当渲染为「分支选择器」：除 git parameter 外，名字含
  /// `branch / ref / revision / tag` 关键字的 string 参数也启用，
  /// 因为大量项目用普通 string 参数承载分支输入。
  bool get isLikelyBranch {
    if (kind == BuildParameterKind.gitBranch) return true;
    if (kind != BuildParameterKind.string && kind != BuildParameterKind.unknown) {
      return false;
    }
    final lower = name.toLowerCase();
    return lower == 'branch' ||
        lower == 'ref' ||
        lower == 'revision' ||
        lower == 'tag' ||
        lower.endsWith('_branch') ||
        lower.endsWith('branch') ||
        lower.contains('git_branch') ||
        lower.contains('git_ref');
  }

  factory BuildParameter.fromJson(Map<String, dynamic> json) {
    final clsSource =
        (json['_class'] as String?) ?? (json['type'] as String?) ?? '';
    final cls = clsSource.toLowerCase();
    final kind = _kindFromClass(cls);
    final defaultParam = json['defaultParameterValue'];
    String defaultValue = '';
    if (defaultParam is Map<String, dynamic>) {
      final v = defaultParam['value'];
      defaultValue = v?.toString() ?? '';
    }
    return BuildParameter(
      name: (json['name'] as String?) ?? '',
      kind: kind,
      defaultValue: defaultValue,
      description: json['description'] as String?,
      choices: _normalizeChoices(json['choices']),
    );
  }

  /// Jenkins `choices` 可能是 `["a","b"]`，也可能是 `[{value:"a"}, ...]`。
  static List<String> _normalizeChoices(dynamic raw) {
    if (raw is! List) return const [];
    final out = <String>[];
    for (final e in raw) {
      if (e is String) {
        out.add(e);
      } else if (e is Map<String, dynamic>) {
        final v = e['value'];
        if (v != null) out.add(v.toString());
      } else if (e != null) {
        out.add(e.toString());
      }
    }
    return out;
  }

  /// 合并 UI 覆盖值与 Jenkins 默认值，用于触发 **buildWithParameters**。
  ///
  /// 若用户未改任何项，[overrides] 往往为空，必须用 [defaultValue] 填充，
  /// 否则会误走 `POST .../build`（无参），参数化流水线常返回 **403**。
  static Map<String, String> mergeForTrigger(
    List<BuildParameter> definitions,
    Map<String, String> overrides,
  ) {
    final out = <String, String>{};
    for (final p in definitions) {
      final fromUi = overrides[p.name];
      if (fromUi != null) {
        out[p.name] = fromUi;
        continue;
      }
      var def = p.defaultValue;
      // Choice 常出现 API 未带 defaultParameterValue：空串会导致 Jenkins 拒绝参数
      if (p.kind == BuildParameterKind.choice && def.isEmpty && p.choices.isNotEmpty) {
        def = p.choices.first;
      }
      out[p.name] = def;
    }
    return out;
  }

  /// 一次「点击构建」要发出的若干次触发之一：参数快照 + 用于区分的短标签。
  ///
  /// 单选时只有一条、[label] 为 null；某个 choice 参数开启多选时，
  /// 每个选中的值各自展开成一条，[label] 即该值（用于 run tab / 通知区分）。
  static List<({Map<String, String> parameters, String? label})>
      expandForMultiTrigger(
    Map<String, String> merged, {
    String? multiParamName,
    List<String> multiValues = const [],
  }) {
    if (multiParamName == null || multiValues.isEmpty) {
      return [(parameters: merged, label: null)];
    }
    // 去重并保持勾选顺序：同一个值发两次没有意义。
    final seen = <String>{};
    final out = <({Map<String, String> parameters, String? label})>[];
    for (final v in multiValues) {
      if (!seen.add(v)) continue;
      out.add((parameters: {...merged, multiParamName: v}, label: v));
    }
    if (out.isEmpty) return [(parameters: merged, label: null)];
    return out;
  }

  /// 该参数是否可以在发版页开启「多选 → 发 N 次」。
  ///
  /// 只放开 Jenkins 声明了枚举值的 choice 参数：自由输入 / 分支类参数多选
  /// 语义不清（用户可能只是想改一次值），也容易误触发一堆构建。
  bool get supportsMultiSelect =>
      kind == BuildParameterKind.choice && choices.length > 1;

  static BuildParameterKind _kindFromClass(String cls) {
    // gitparameter 必须放在 string 检测之前，避免被旧版插件的 `gitparameterstring` 误命中
    if (cls.contains('gitparameter') || cls.contains('gitbranch')) {
      return BuildParameterKind.gitBranch;
    }
    if (cls.contains('boolean')) return BuildParameterKind.boolean;
    if (cls.contains('choice')) return BuildParameterKind.choice;
    if (cls.contains('text')) return BuildParameterKind.text;
    if (cls.contains('password')) return BuildParameterKind.password;
    if (cls.contains('file')) return BuildParameterKind.file;
    if (cls.contains('run')) return BuildParameterKind.run;
    if (cls.contains('string')) return BuildParameterKind.string;
    return BuildParameterKind.unknown;
  }

  /// 在候选分支集合 [options] 中挑选最像「主分支」的那一项。
  ///
  /// 优先级：
  ///   1. 非空 [defaultValue]（来自 Jenkins 自身的 `defaultParameterValue.value`）；
  ///   2. `origin/main` → `main` → `origin/master` → `master` → `develop` → `trunk`；
  ///   3. 任何带 `*main*` 或 `*master*` 的；
  ///   4. 候选列表第一项。
  ///
  /// 没有任何候选且 [defaultValue] 也为空时返回 `null`，由调用方保留空值。
  static String? pickPrimaryBranch(String defaultValue, List<String> options) {
    if (defaultValue.trim().isNotEmpty) return defaultValue;
    const preferred = [
      'origin/main',
      'main',
      'origin/master',
      'master',
      'develop',
      'trunk',
    ];
    for (final candidate in preferred) {
      if (options.contains(candidate)) return candidate;
    }
    for (final o in options) {
      final l = o.toLowerCase();
      if (l.contains('main') || l.contains('master')) return o;
    }
    return options.isNotEmpty ? options.first : null;
  }
}
