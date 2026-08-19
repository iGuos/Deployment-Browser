import 'package:deployment/features/jenkins/domain/build_parameter.dart';
import 'package:deployment/features/jenkins/presentation/parameter_form.dart';
import 'package:deployment/l10n/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _service = BuildParameter(
  name: 'SERVICE',
  kind: BuildParameterKind.choice,
  defaultValue: 'admin-api',
  choices: ['admin-api', 'admin-web'],
);
const _env = BuildParameter(
  name: 'ENV',
  kind: BuildParameterKind.choice,
  defaultValue: 'dev',
  choices: ['dev', 'pre'],
);
const _branch = BuildParameter(
  name: 'BRANCH',
  kind: BuildParameterKind.string,
  defaultValue: 'next',
);

void main() {
  group('expandForMultiTrigger', () {
    const merged = {'SERVICE': 'admin-api', 'BRANCH': 'next'};

    test('未开启多选时只发一次，参数原样透传', () {
      final variants = BuildParameter.expandForMultiTrigger(merged);
      expect(variants.length, 1);
      expect(variants.single.parameters, merged);
      expect(variants.single.label, isNull);
    });

    test('多选 N 个值 → 展开 N 次，仅该参数不同，其余参数一致', () {
      final variants = BuildParameter.expandForMultiTrigger(
        merged,
        multiParamName: 'SERVICE',
        multiValues: const ['admin-api', 'admin-web'],
      );
      expect(variants.length, 2);
      expect(variants[0].parameters['SERVICE'], 'admin-api');
      expect(variants[1].parameters['SERVICE'], 'admin-web');
      // 标签用于区分 run tab / 通知
      expect(variants.map((v) => v.label), ['admin-api', 'admin-web']);
      // 其余参数不受影响
      expect(variants.every((v) => v.parameters['BRANCH'] == 'next'), isTrue);
      // 不能改到原 map（否则第二次触发会带上第一次的值）
      expect(merged['SERVICE'], 'admin-api');
    });

    test('重复勾选的值去重，顺序保持勾选顺序', () {
      final variants = BuildParameter.expandForMultiTrigger(
        merged,
        multiParamName: 'SERVICE',
        multiValues: const ['admin-web', 'admin-api', 'admin-web'],
      );
      expect(variants.map((v) => v.label), ['admin-web', 'admin-api']);
    });

    test('开了多选但没勾任何值 → 退化为单次触发', () {
      final variants = BuildParameter.expandForMultiTrigger(
        merged,
        multiParamName: 'SERVICE',
        multiValues: const [],
      );
      expect(variants.length, 1);
      expect(variants.single.label, isNull);
    });
  });

  group('supportsMultiSelect', () {
    test('仅枚举值 >= 2 的 choice 参数可多选', () {
      expect(_service.supportsMultiSelect, isTrue);
      expect(_branch.supportsMultiSelect, isFalse);
      expect(
        const BuildParameter(
          name: 'ONLY_ONE',
          kind: BuildParameterKind.choice,
          defaultValue: 'a',
          choices: ['a'],
        ).supportsMultiSelect,
        isFalse,
      );
    });
  });

  group('ParameterForm 多选交互', () {
    Widget host({
      String? multiParam,
      List<String> multiValues = const [],
      required void Function(String, bool) onToggle,
      void Function(String, List<String>)? onValues,
    }) {
      return MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ParameterForm(
              parameters: const [_service, _env, _branch],
              values: const {},
              onChange: (_, _) {},
              multiSelectParam: multiParam,
              multiSelectValues: multiValues,
              onToggleMultiSelect: onToggle,
              onChangeMultiSelectValues: onValues ?? (_, _) {},
            ),
          ),
        ),
      );
    }

    // 多选开关是自绘的轻量控件（不是 Material Checkbox），可点 = 外层有 InkWell。
    Finder toggles() => find.text('多选');
    bool tappable(WidgetTester tester, int index) => tester
        .widgetList<InkWell>(
          find.ancestor(of: toggles().at(index), matching: find.byType(InkWell)),
        )
        .any((w) => w.onTap != null);

    testWidgets('每个 choice 参数各有一个「多选」开关，非 choice 参数没有', (tester) async {
      await tester.pumpWidget(host(onToggle: (_, _) {}));
      await tester.pumpAndSettle();
      // SERVICE / ENV 两个 choice 各一个；BRANCH（string）不给
      expect(toggles(), findsNWidgets(2));
      // 视觉上要小而克制：不使用 Material Checkbox（18px + 水波纹 + 40px 触控区）
      expect(find.byType(Checkbox), findsNothing);
      expect(tappable(tester, 0), isTrue);
      expect(tappable(tester, 1), isTrue);
    });

    testWidgets('已有参数开启多选时，其它参数的开关不可点（同时只允许一个）', (tester) async {
      await tester.pumpWidget(host(multiParam: 'SERVICE', onToggle: (_, _) {}));
      await tester.pumpAndSettle();
      expect(toggles(), findsNWidgets(2));
      // 已开启的 SERVICE 仍可点（用于关掉），ENV 被禁用
      expect(tappable(tester, 0), isTrue);
      expect(tappable(tester, 1), isFalse);
    });

    testWidgets('点开关回调参数名与开关状态；再点一次为关闭', (tester) async {
      final calls = <(String, bool)>[];
      await tester.pumpWidget(host(onToggle: (n, v) => calls.add((n, v))));
      await tester.pumpAndSettle();
      await tester.tap(toggles().first);
      expect(calls, [('SERVICE', true)]);

      await tester.pumpWidget(
        host(multiParam: 'SERVICE', onToggle: (n, v) => calls.add((n, v))),
      );
      await tester.pumpAndSettle();
      await tester.tap(toggles().first);
      expect(calls.last, ('SERVICE', false));
    });

    testWidgets('开启多选后展示多选控件；下拉勾选两项不关闭菜单并回调选中值', (tester) async {
      final selected = <List<String>>[];
      await tester.pumpWidget(
        host(
          multiParam: 'SERVICE',
          onToggle: (_, _) {},
          onValues: (_, v) => selected.add(v),
        ),
      );
      await tester.pumpAndSettle();
      // 多选态下是「请选择（可多选）」占位，而不是单选下拉的当前值
      expect(find.text('请选择（可多选）'), findsOneWidget);

      await tester.tap(find.text('请选择（可多选）'));
      await tester.pumpAndSettle();
      // 菜单里每个候选一行
      expect(find.text('admin-api'), findsOneWidget);
      expect(find.text('admin-web'), findsOneWidget);

      await tester.tap(find.text('admin-api'));
      await tester.pumpAndSettle();
      expect(selected, [
        ['admin-api'],
      ]);
      // closeOnActivate:false → 菜单仍开着，可以继续勾第二项
      expect(find.text('admin-web'), findsOneWidget);
    });

    testWidgets('已选项以 chips 展示，并显示已选数量', (tester) async {
      await tester.pumpWidget(
        host(
          multiParam: 'SERVICE',
          multiValues: const ['admin-api', 'admin-web'],
          onToggle: (_, _) {},
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('请选择（可多选）'), findsNothing);
      expect(find.text('已选 2 项'), findsOneWidget);
      expect(find.text('admin-api'), findsOneWidget);
      expect(find.text('admin-web'), findsOneWidget);
    });
  });
}
