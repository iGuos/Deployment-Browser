import 'accounts_export_save_stub.dart'
    if (dart.library.io) 'accounts_export_save_io.dart' as _impl;

/// 桌面端弹出「另存为」并写入 [content]；Web / 非 IO 平台返回 false。
Future<bool> saveAccountsExportFile(String content, String suggestedName) =>
    _impl.saveAccountsExportFile(content, suggestedName);
