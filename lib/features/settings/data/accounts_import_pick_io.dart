import 'dart:io';

import 'package:file_selector/file_selector.dart';

Future<String?> pickAndReadAccountsImportFile() async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ],
  );
  if (file == null) return null;
  final path = file.path;
  if (path.isEmpty) return null;
  return File(path).readAsString();
}
