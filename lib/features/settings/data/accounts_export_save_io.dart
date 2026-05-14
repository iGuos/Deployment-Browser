import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';

Future<bool> saveAccountsExportFile(String content, String suggestedName) async {
  final location = await getSaveLocation(
    acceptedTypeGroups: const [
      XTypeGroup(label: 'JSON', extensions: ['json']),
    ],
    suggestedName: suggestedName,
  );
  if (location == null) return false;
  await File(location.path).writeAsString(content, encoding: utf8);
  return true;
}
