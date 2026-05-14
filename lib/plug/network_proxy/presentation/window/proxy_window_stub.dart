import 'package:flutter/material.dart';

const kProxyWindowArguments = 'app_proxy_settings';

Future<void> openNetworkProxySettings({BuildContext? context}) async {
  if (context != null && context.mounted) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: const Text('Web 端请使用桌面客户端配置代理。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}

Future<void> openAppProxySettings({BuildContext? context}) {
  return openNetworkProxySettings(context: context);
}
