import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/build_parameter.dart';

/// 加载某个参数的"可选值"集合（典型用例：git 分支历史）。
/// 失败时应抛异常，UI 会展示「重试」按钮。
///
/// [forceRefresh] 为 true 时绕过任何缓存层，强制走网络重拉。
typedef BranchOptionsLoader = Future<List<String>> Function(
  String paramName, {
  bool forceRefresh,
});

/// 动态参数表单：根据 [parameters] 渲染对应输入控件，
/// 通过 [values] 受控、[onChange] 回调写回。
class ParameterForm extends StatelessWidget {
  const ParameterForm({
    super.key,
    required this.parameters,
    required this.values,
    required this.onChange,
    this.branchOptionsLoader,
    this.branchDefaultGetter,
    this.onSaveBranchDefault,
    this.onClearBranchDefault,
    this.onShowReleaseHistory,
  });

  final List<BuildParameter> parameters;
  final Map<String, String> values;
  final void Function(String key, String value) onChange;

  /// 可选：当某个参数被识别为「分支」时，用它去拉候选项；为 null 时仅当作普通输入框。
  final BranchOptionsLoader? branchOptionsLoader;

  /// 可选：读取该参数当前保存的默认分支；null = 未设置。
  /// 仅对被识别为分支的参数生效。
  final String? Function(String paramName)? branchDefaultGetter;

  /// 可选：保存某个分支参数的默认值。
  final void Function(String paramName, String value)? onSaveBranchDefault;

  /// 可选：清除某个分支参数的默认值。
  final void Function(String paramName)? onClearBranchDefault;

  /// 可选：在项目页展示「历史发版记录」入口。
  final VoidCallback? onShowReleaseHistory;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);

    final header = Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              l10n.projectParameters,
              style:
                  TextStyle(color: palette.muted, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
          if (onShowReleaseHistory != null)
            TextButton.icon(
              onPressed: onShowReleaseHistory,
              icon: Icon(Icons.history_rounded, size: 18, color: palette.accent),
              label: Text(l10n.projectReleaseHistory),
              style: TextButton.styleFrom(
                foregroundColor: palette.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
        ],
      ),
    );

    if (parameters.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: palette.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: palette.borderSubtle),
            ),
            child: Row(
              children: [
                Icon(Icons.info_outline_rounded, size: 16, color: palette.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.projectNoParameters,
                    style: TextStyle(color: palette.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        ...parameters.map((p) => _buildParam(context, p)),
      ],
    );
  }

  Widget _buildParam(BuildContext context, BuildParameter p) {
    final current = values[p.name] ?? p.defaultValue;
    final palette = context.palette;
    Widget child;
    // 优先识别"分支参数"：渲染为可搜索下拉，候选来源由父组件注入。
    // 之所以把这一步放在 switch 之前：分支参数底层 kind 大多数仍是 string/unknown，
    // 用 switch 的话会先被 string 分支 catch 住。
    if (p.isLikelyBranch && branchOptionsLoader != null) {
      final saved = branchDefaultGetter?.call(p.name);
      final currentForStar = current;
      Widget? trailing;
      if (onSaveBranchDefault != null && onClearBranchDefault != null) {
        trailing = _BranchDefaultStar(
          saved: saved,
          currentValue: currentForStar,
          onSave: () =>
              onSaveBranchDefault!(p.name, currentForStar),
          onClear: () => onClearBranchDefault!(p.name),
        );
      }
      child = _LabelWrap(
        label: p.name,
        description: p.description,
        trailing: trailing,
        child: _OptionsCombobox(
          paramName: p.name,
          defaultValue: p.defaultValue,
          fixedChoices: p.choices,
          currentValue: values[p.name],
          loader: branchOptionsLoader!,
          onChange: (v) => onChange(p.name, v),
          // 分支：允许任意输入（用户的 fork 分支可能不在历史记录里）
          freeInput: true,
          // 默认值倾向 main/master
          primaryPicker: BuildParameter.pickPrimaryBranch,
          // 用户保存的偏好优先于 primaryPicker
          userDefault: saved,
        ),
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: child,
      );
    }
    switch (p.kind) {
      case BuildParameterKind.boolean:
        child = SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(p.name, style: const TextStyle(fontSize: 13)),
          subtitle: (p.description ?? '').isEmpty
              ? null
              : Text(p.description!, style: TextStyle(color: palette.muted, fontSize: 11.5)),
          value: current.toLowerCase() == 'true',
          onChanged: (v) => onChange(p.name, v ? 'true' : 'false'),
        );
        break;
      case BuildParameterKind.choice:
        // 用与分支同款的可搜索下拉，区别是必须从枚举值中选（freeInput=false）。
        // 之所以放弃 DropdownButtonFormField：
        //   1. 它的菜单是从输入框位置覆盖式弹出，不能放下方；
        //   2. 选项多时缺少搜索能力。
        child = _LabelWrap(
          label: p.name,
          description: p.description,
          child: _OptionsCombobox(
            paramName: p.name,
            defaultValue: p.choices.contains(current)
                ? current
                : (p.choices.isNotEmpty ? p.choices.first : ''),
            fixedChoices: p.choices,
            currentValue: values[p.name],
            onChange: (v) => onChange(p.name, v),
            freeInput: false,
            // `service` 发板常用：仅允许从枚举中点选，不做键入模糊过滤（外观与其它 choice 一致）。
            filterable: p.name.toLowerCase() != 'service',
            iconData: Icons.list_rounded,
          ),
        );
        break;
      case BuildParameterKind.text:
        child = _LabelWrap(
          label: p.name,
          description: p.description,
          child: TextFormField(
            initialValue: current,
            maxLines: 4,
            decoration: const InputDecoration(),
            onChanged: (v) => onChange(p.name, v),
          ),
        );
        break;
      case BuildParameterKind.password:
        child = _LabelWrap(
          label: p.name,
          description: p.description,
          child: TextFormField(
            initialValue: current,
            obscureText: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.lock_outline_rounded, size: 18)),
            onChanged: (v) => onChange(p.name, v),
          ),
        );
        break;
      case BuildParameterKind.gitBranch:
      // git parameter 但 loader 未注入：退化成普通字符串输入
      case BuildParameterKind.string:
      case BuildParameterKind.run:
      case BuildParameterKind.file:
      case BuildParameterKind.unknown:
        child = _LabelWrap(
          label: p.name,
          description: p.description,
          child: TextFormField(
            initialValue: current,
            decoration: InputDecoration(
              prefixIcon: Icon(_iconFor(p.kind), size: 18),
            ),
            onChanged: (v) => onChange(p.name, v),
          ),
        );
        break;
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: child,
    );
  }

  IconData _iconFor(BuildParameterKind k) {
    return switch (k) {
      BuildParameterKind.string => Icons.text_fields_rounded,
      BuildParameterKind.text => Icons.notes_rounded,
      BuildParameterKind.boolean => Icons.toggle_on_rounded,
      BuildParameterKind.choice => Icons.list_rounded,
      BuildParameterKind.password => Icons.lock_outline_rounded,
      BuildParameterKind.run => Icons.play_circle_outline_rounded,
      BuildParameterKind.file => Icons.attach_file_rounded,
      BuildParameterKind.gitBranch => Icons.alt_route_rounded,
      BuildParameterKind.unknown => Icons.help_outline_rounded,
    };
  }
}

/// 在候选集合中挑「优先项」的回调（如「主分支」）。
typedef PrimaryPicker = String? Function(String defaultValue, List<String> options);

/// 通用的"输入框 + 下拉候选"组件，给 [BuildParameterKind.choice] 与
/// [BuildParameter.isLikelyBranch] 两类参数共用。
///
/// 关键设计：
/// - **弹层在输入框正下方、宽度等同输入框**：通过 `LayoutBuilder` 拿到父级
///   宽度，再把 `maxWidth` 透传到 `optionsViewBuilder` 的 `ConstrainedBox`，
///   保证下拉视觉上「贴住」输入框，而不是 `DropdownButton` 那种覆盖式弹出。
/// - **支持模糊匹配**：lowercase contains，前缀命中排前。
/// - **`freeInput` 控制是否允许任意文本**：
///   - true（分支模式）：用户输入即生效；
///   - false（choice 模式）：输入仅作过滤；失焦/回车若不在候选中，
///     回退到上次合法值，避免把搜索词当成参数发出。
/// - **`filterable`**：为 false 时不做键入过滤（候选恒为全量），输入框只读，
///   用于如 `service` 等仅需点选下拉的枚举参数。
class _OptionsCombobox extends StatefulWidget {
  const _OptionsCombobox({
    required this.paramName,
    required this.defaultValue,
    required this.fixedChoices,
    required this.currentValue,
    required this.onChange,
    required this.freeInput,
    this.filterable = true,
    this.loader,
    this.primaryPicker,
    this.userDefault,
    this.iconData = Icons.alt_route_rounded,
  });

  final String paramName;
  final String defaultValue;

  /// 为 false 时（如 `service`）：输入框只读，候选始终为完整列表，不能键入过滤。
  final bool filterable;

  /// 参数自身在 Jenkins 上声明的固定选项；
  /// - choice 模式：就是合法枚举集；
  /// - 分支模式：兜底候选（loader 还没回来之前可立刻使用）。
  final List<String> fixedChoices;

  /// 父级当前持有的值；用 null 区分"用户尚未选过"——这一情况里要主动写默认值。
  final String? currentValue;
  final ValueChanged<String> onChange;

  /// 是否允许任意输入（true=分支；false=必须从候选选）。
  final bool freeInput;

  /// 可选异步加载器（分支模式才用）。
  final BranchOptionsLoader? loader;

  /// 自动选取「优先项」的策略（分支模式用主分支挑选）。
  final PrimaryPicker? primaryPicker;

  /// 用户为该参数保存的"偏好默认值"。
  /// 优先级高于 [primaryPicker]：有则直接套用，无则回退到主分支策略。
  final String? userDefault;

  final IconData iconData;

  @override
  State<_OptionsCombobox> createState() => _OptionsComboboxState();
}

class _OptionsComboboxState extends State<_OptionsCombobox> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  List<String> _options = const [];
  bool _loading = false;
  Object? _error;
  bool _autoSelectedDefault = false;

  /// choice 模式下"上一次合法值"，失焦时用它复位。
  String? _lastValid;

  @override
  void initState() {
    super.initState();
    // 初值优先级：父级已有值 > 用户保存的偏好 > Jenkins 默认。
    // 保存的偏好在 initState 就应用，避免先显示 Jenkins 默认再"闪一下"切到偏好。
    final userDefault = widget.userDefault;
    final hasUserDefault = userDefault != null && userDefault.isNotEmpty;
    final initial = widget.currentValue ??
        (hasUserDefault ? userDefault : widget.defaultValue);
    _controller = TextEditingController(text: initial);
    _focusNode = FocusNode();
    _focusNode.addListener(_onFocusChanged);
    _options = widget.fixedChoices;
    if (!widget.freeInput && _options.contains(initial)) {
      _lastValid = initial;
    }
    if (widget.currentValue == null && hasUserDefault) {
      _autoSelectedDefault = true;
      _lastValid = userDefault;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChange(userDefault);
      });
    }
    if (widget.loader != null) {
      _load();
    } else {
      // 没有 loader（典型 choice）：直接尝试套用默认值
      _maybeApplyDefault();
    }
  }

  Future<void> _load({bool forceRefresh = false}) async {
    final loader = widget.loader;
    if (loader == null) return;
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final loaded = await loader(
        widget.paramName,
        forceRefresh: forceRefresh,
      );
      final merged = <String>{};
      merged.addAll(widget.fixedChoices);
      merged.addAll(loaded);
      final list = merged.toList(growable: false);
      if (!mounted) return;
      setState(() {
        _options = list;
        _loading = false;
      });
      _maybeApplyDefault();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
      _options = widget.fixedChoices;
      _maybeApplyDefault();
    }
  }

  /// 把「优先项」回写父组件，仅在用户没选过时执行一次。
  void _maybeApplyDefault() {
    if (_autoSelectedDefault) return;
    if (widget.currentValue != null) {
      _autoSelectedDefault = true;
      return;
    }
    final picker = widget.primaryPicker;
    final picked = picker != null
        ? picker(widget.defaultValue, _options)
        // choice 兜底：defaultValue 在候选中就用它，否则取首项
        : (_options.contains(widget.defaultValue)
            ? widget.defaultValue
            : (_options.isNotEmpty ? _options.first : null));
    if (picked == null || picked.isEmpty) return;
    _autoSelectedDefault = true;
    _controller.text = picked;
    _lastValid = picked;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onChange(picked);
    });
  }

  void _onFocusChanged() {
    // choice 模式失焦：如果当前文本不在候选里，回退到上次合法值。
    if (_focusNode.hasFocus) return;
    if (widget.freeInput) return;
    final text = _controller.text;
    if (_options.contains(text)) {
      _lastValid = text;
      return;
    }
    final fallback = _lastValid ?? widget.defaultValue;
    if (fallback.isEmpty) return;
    _controller.text = fallback;
    _controller.selection = TextSelection.collapsed(offset: fallback.length);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Iterable<String> _filter(String query) {
    if (_options.isEmpty) return const [];
    if (query.isEmpty) return _options;
    final q = query.toLowerCase();
    final prefix = <String>[];
    final contains = <String>[];
    for (final o in _options) {
      final l = o.toLowerCase();
      if (l == q) {
        prefix.insert(0, o);
      } else if (l.startsWith(q)) {
        prefix.add(o);
      } else if (l.contains(q)) {
        contains.add(o);
      }
    }
    return [...prefix, ...contains];
  }

  void _onUserTyped(String value) {
    if (widget.freeInput) {
      widget.onChange(value);
    }
    // choice 模式：键入只用于过滤候选，选中时才写父级
  }

  void _onSelected(String value) {
    _lastValid = value;
    widget.onChange(value);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);

    return LayoutBuilder(
      builder: (ctx, constraints) {
        // 父级给的 maxWidth：用它统一输入框 & 弹层宽度。
        // 当父级没显式约束（infinity）时，回退一个合理上限，
        // 避免弹层变成横向无限拉伸。
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 480.0;
        return RawAutocomplete<String>(
          textEditingController: _controller,
          focusNode: _focusNode,
          optionsBuilder: (text) =>
              widget.filterable ? _filter(text.text) : _options,
          onSelected: _onSelected,
          fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
            final readOnlyDropdown = !widget.freeInput && !widget.filterable;
            return SizedBox(
              width: width,
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                readOnly: readOnlyDropdown,
                onChanged: _onUserTyped,
                onSubmitted: (_) => onSubmit(),
                decoration: InputDecoration(
                  prefixIcon: Icon(widget.iconData, size: 18),
                  suffixIcon: _ComboboxSuffix(
                    loading: _loading,
                    error: _error,
                    count: _options.length,
                    showRefresh: widget.loader != null,
                    showCount: widget.loader != null,
                    onRefresh: () {
                      _autoSelectedDefault = true;
                      _load(forceRefresh: true);
                    },
                    onTapDown: () {
                      // 点 ↓ 图标时主动 focus + 触发 options 重算（清空文本会显示全量）
                      if (!_focusNode.hasFocus) _focusNode.requestFocus();
                    },
                  ),
                  hintText: _hintText(l10n),
                  hintStyle: TextStyle(color: palette.muted, fontSize: 12.5),
                ),
              ),
            );
          },
          optionsViewBuilder: (ctx, onSelected, options) {
            final list = options.toList(growable: false);
            if (list.isEmpty) return const SizedBox.shrink();
            return Align(
              alignment: Alignment.topLeft,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                color: palette.surfaceRaised,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 240, maxWidth: width),
                  child: SizedBox(
                    width: width,
                    child: ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: list.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: palette.borderSubtle.withValues(alpha: 0.6),
                      ),
                      itemBuilder: (ctx, i) {
                        final item = list[i];
                        final selected = _controller.text == item;
                        final isPrimary = widget.primaryPicker != null &&
                            _isPrimaryLike(item);
                        return InkWell(
                          onTap: () => onSelected(item),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isPrimary
                                      ? Icons.star_rounded
                                      : (selected
                                          ? Icons.check_rounded
                                          : widget.iconData),
                                  size: 14,
                                  color: isPrimary
                                      ? palette.warning
                                      : (selected
                                          ? palette.accent
                                          : palette.muted),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    item,
                                    style: TextStyle(
                                      color: palette.text,
                                      fontSize: 13,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _hintText(AppL10n l10n) {
    if (widget.freeInput) {
      return _options.isEmpty && !_loading
          ? l10n.parameterBranchHintInputOnly
          : l10n.parameterBranchHint;
    }
    return l10n.parameterChoiceHint;
  }

  static bool _isPrimaryLike(String name) {
    final l = name.toLowerCase();
    return l == 'main' ||
        l == 'master' ||
        l == 'origin/main' ||
        l == 'origin/master';
  }
}

class _ComboboxSuffix extends StatelessWidget {
  const _ComboboxSuffix({
    required this.loading,
    required this.error,
    required this.count,
    required this.showRefresh,
    required this.showCount,
    required this.onRefresh,
    required this.onTapDown,
  });

  final bool loading;
  final Object? error;
  final int count;
  final bool showRefresh;
  final bool showCount;
  final VoidCallback onRefresh;
  final VoidCallback onTapDown;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    if (loading) {
      return const Padding(
        padding: EdgeInsets.all(10),
        child: SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showCount && error == null && count > 0)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              l10n.parameterBranchCount(count),
              style: TextStyle(color: palette.muted, fontSize: 11),
            ),
          ),
        if (showRefresh)
          IconButton(
            tooltip: l10n.parameterBranchRefresh,
            onPressed: onRefresh,
            icon: Icon(
              error == null ? Icons.refresh_rounded : Icons.error_outline_rounded,
              size: 16,
              color: error == null ? palette.muted : palette.danger,
            ),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        IconButton(
          tooltip: l10n.parameterChoiceExpand,
          onPressed: onTapDown,
          icon: Icon(
            Icons.arrow_drop_down_rounded,
            size: 22,
            color: palette.muted,
          ),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        ),
      ],
    );
  }
}

class _LabelWrap extends StatelessWidget {
  const _LabelWrap({
    required this.label,
    required this.child,
    this.description,
    this.trailing,
  });

  final String label;
  final String? description;
  final Widget child;

  /// 标签行右侧的操作区（如「设为默认分支」星标按钮）。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: palette.text,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            ?trailing,
          ],
        ),
        if ((description ?? '').isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(description!, style: TextStyle(color: palette.muted, fontSize: 11.5)),
          ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }
}

/// 「将当前分支保存为该项目的默认分支」星标按钮。
///
/// 状态：
/// - [saved] == null  → 灰色空心星，点击保存 [currentValue]
/// - [saved] == [currentValue] → 金色实心星，点击清除
/// - [saved] != null 但与 [currentValue] 不同 → 灰色空心星，点击把保存值替换为当前值
class _BranchDefaultStar extends StatelessWidget {
  const _BranchDefaultStar({
    required this.saved,
    required this.currentValue,
    required this.onSave,
    required this.onClear,
  });

  final String? saved;
  final String currentValue;
  final VoidCallback onSave;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final l10n = AppL10n.of(context);
    final hasSaved = saved != null && saved!.isNotEmpty;
    final isFilled = hasSaved && saved == currentValue;

    final tooltip = isFilled
        ? l10n.parameterBranchDefaultClear(saved!)
        : hasSaved
            ? l10n.parameterBranchDefaultUpdate(saved!)
            : l10n.parameterBranchDefaultSave(currentValue);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 300),
      child: IconButton(
        onPressed: () {
          if (isFilled) {
            onClear();
          } else if (currentValue.isNotEmpty) {
            onSave();
          }
        },
        icon: Icon(
          isFilled ? Icons.star_rounded : Icons.star_outline_rounded,
          size: 18,
          color: isFilled ? palette.warning : palette.muted,
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        visualDensity: VisualDensity.compact,
      ),
    );
  }
}
