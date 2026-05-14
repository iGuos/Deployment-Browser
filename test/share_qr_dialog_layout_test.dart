import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 回归：分享二维码使用 [QrImageView]（内含 [LayoutBuilder]），不可放在 [AlertDialog]
///（IntrinsicWidth 会查询固有尺寸）里，否则运行时布局断言失败。
void main() {
  testWidgets('share-QR Dialog with QrImageView lays out and settles', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return TextButton(
                onPressed: () {
                  showDialog<void>(
                    context: context,
                    builder: (ctx) {
                      const payload = 'deployment-share-test';
                      return Dialog(
                        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
                        clipBehavior: Clip.antiAlias,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 600),
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Wrap(
                                  spacing: 8,
                                  children: [
                                    Icon(Icons.qr_code_2_rounded, size: 22),
                                    Text('QR title'),
                                  ],
                                ),
                                const SizedBox(height: 16),
                                Center(
                                  child: QrImageView(
                                    data: payload,
                                    version: QrVersions.auto,
                                    size: 120,
                                    padding: EdgeInsets.zero,
                                    backgroundColor: Colors.white,
                                  ),
                                ),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(),
                                    child: const Text('Close'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
                child: const Text('open-dialog'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-dialog'));
    await tester.pumpAndSettle();

    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(find.text('QR title'), findsOneWidget);
  });
}
