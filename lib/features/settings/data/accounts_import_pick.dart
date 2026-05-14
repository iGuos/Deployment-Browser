import 'accounts_import_pick_stub.dart'
    if (dart.library.io) 'accounts_import_pick_io.dart' as accounts_import_pick_impl;

/// 桌面端弹出「打开」并读取文本；Web / 非 IO 平台返回 null。
Future<String?> pickAndReadAccountsImportFile() =>
    accounts_import_pick_impl.pickAndReadAccountsImportFile();
