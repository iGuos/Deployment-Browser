import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../l10n/app_localizations.dart';
import '../data/jenkins_account_qr_share.dart';

/// 与取景框 UI 一致；传给 [MobileScanner.scanWindow] 后仅识别与该矩形相交的条码（Web 不支持 scanWindow）。
Rect _jenkinsAccountQrScanCutoutRect(double w, double h) {
  const horizontalMargin = 36.0;
  final maxSide = w - horizontalMargin * 2;
  final side =
      (math.min(maxSide, h * 0.52)).clamp(160.0, 320.0).toDouble();
  final left = (w - side) / 2;
  final top = (((h - side) / 2 - 16)
          .clamp(8.0, math.max(8.0, h - side - 8)))
      .toDouble();
  return Rect.fromLTWH(left, top, side, side);
}

/// 扫描 Jenkins 账号分享二维码（仅识别 `dep:j1:` / `dep:j2:` 载荷）。
class JenkinsAccountQrScanPage extends StatefulWidget {
  const JenkinsAccountQrScanPage({super.key});

  @override
  State<JenkinsAccountQrScanPage> createState() => _JenkinsAccountQrScanPageState();
}

class _JenkinsAccountQrScanPageState extends State<JenkinsAccountQrScanPage> {
  final MobileScannerController _controller = MobileScannerController();
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled || !mounted) return;
    for (final b in capture.barcodes) {
      final raw = b.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      if (!looksLikeJenkinsAccountSharePayload(raw)) continue;
      setState(() => _handled = true);
      await _controller.stop();
      if (!mounted) return;
      Navigator.of(context).pop<String>(raw);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(l10n.accountsImportScanQr),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final cutout = _jenkinsAccountQrScanCutoutRect(
            constraints.maxWidth,
            constraints.maxHeight,
          );

          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                scanWindow: kIsWeb ? null : cutout,
                onDetect: _onDetect,
                errorBuilder: (ctx, error) {
                  final msg = error.errorDetails?.message ?? error.toString();
                  final isDenied =
                      error.errorCode == MobileScannerErrorCode.permissionDenied;
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        isDenied ? l10n.accountsCameraPermissionDenied : msg,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70, height: 1.45),
                      ),
                    ),
                  );
                },
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _QrScanMaskPainter(cutout: cutout),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 20,
                bottom: 40,
                child: Material(
                  color: Colors.transparent,
                  child: Text(
                    l10n.accountsScanQrInstruction,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      height: 1.45,
                      shadows: const [
                        Shadow(blurRadius: 12, color: Colors.black87),
                        Shadow(blurRadius: 4, color: Colors.black54),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 取景区域：中央正方形镂空 + 四周压暗 + 白框（与 [MobileScanner.scanWindow] 使用同一 [cutout]）。
class _QrScanMaskPainter extends CustomPainter {
  _QrScanMaskPainter({required this.cutout});

  final Rect cutout;
  static const Radius _r = Radius.circular(10);

  @override
  void paint(Canvas canvas, Size size) {
    final outer = Path()..addRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(cutout.deflate(1), _r));
    final mask = Path.combine(PathOperation.difference, outer, hole);

    canvas.drawPath(
      mask,
      Paint()..color = Colors.black.withValues(alpha: 0.52),
    );

    final borderPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawRRect(
      RRect.fromRectAndRadius(cutout, _r),
      borderPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _QrScanMaskPainter oldDelegate) =>
      oldDelegate.cutout != cutout;
}
