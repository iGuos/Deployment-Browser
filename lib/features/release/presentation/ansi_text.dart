import 'package:flutter/material.dart';

// Jenkins HyperlinkNote 注解：ESC[8m..ESC[0m 包裹的 base64 元数据，
// Web UI 会渲染成超链接；裸日志里需要先剥掉，否则用户看到一串乱码。
final _jenkinsAnnotation = RegExp(
  r'\x1B\[8mha:////[A-Za-z0-9+/=]+?\x1B\[0m',
  dotAll: true,
);

final _sgr = RegExp(r'\x1B\[([0-9;]*)m');

String stripJenkinsAnnotations(String s) =>
    s.replaceAll(_jenkinsAnnotation, '');

String stripAnsi(String s) =>
    s.replaceAll(_jenkinsAnnotation, '').replaceAll(_sgr, '');

const _ansi16 = <Color>[
  Color(0xFF000000), Color(0xFFCD3131), Color(0xFF0DBC79), Color(0xFFE5E510),
  Color(0xFF2472C8), Color(0xFFBC3FBC), Color(0xFF11A8CD), Color(0xFFE5E5E5),
  Color(0xFF666666), Color(0xFFF14C4C), Color(0xFF23D18B), Color(0xFFF5F543),
  Color(0xFF3B8EEA), Color(0xFFD670D6), Color(0xFF29B8DB), Color(0xFFFFFFFF),
];

List<TextSpan> parseAnsi(String text, TextStyle base) {
  final spans = <TextSpan>[];
  var style = base;
  var cursor = 0;
  for (final m in _sgr.allMatches(text)) {
    if (m.start > cursor) {
      spans.add(TextSpan(text: text.substring(cursor, m.start), style: style));
    }
    final group = m.group(1) ?? '';
    final codes = group.isEmpty
        ? const <int>[0]
        : group.split(';').map((e) => int.tryParse(e) ?? 0).toList();
    style = _applyCodes(style, base, codes);
    cursor = m.end;
  }
  if (cursor < text.length) {
    spans.add(TextSpan(text: text.substring(cursor), style: style));
  }
  return spans;
}

TextStyle _applyCodes(TextStyle current, TextStyle base, List<int> codes) {
  var s = current;
  for (var i = 0; i < codes.length; i++) {
    final c = codes[i];
    if (c == 0) {
      s = base;
    } else if (c == 1) {
      s = s.copyWith(fontWeight: FontWeight.bold);
    } else if (c == 3) {
      s = s.copyWith(fontStyle: FontStyle.italic);
    } else if (c == 4) {
      s = s.copyWith(decoration: TextDecoration.underline);
    } else if (c == 22) {
      s = s.copyWith(fontWeight: FontWeight.normal);
    } else if (c == 23) {
      s = s.copyWith(fontStyle: FontStyle.normal);
    } else if (c == 24) {
      s = s.copyWith(decoration: TextDecoration.none);
    } else if (c >= 30 && c <= 37) {
      s = s.copyWith(color: _ansi16[c - 30]);
    } else if (c == 38 && i + 2 < codes.length && codes[i + 1] == 5) {
      s = s.copyWith(color: _xterm256(codes[i + 2]));
      i += 2;
    } else if (c == 38 && i + 4 < codes.length && codes[i + 1] == 2) {
      s = s.copyWith(
        color: Color.fromARGB(0xFF, codes[i + 2], codes[i + 3], codes[i + 4]),
      );
      i += 4;
    } else if (c >= 40 && c <= 47) {
      s = s.copyWith(backgroundColor: _ansi16[c - 40]);
    } else if (c >= 90 && c <= 97) {
      s = s.copyWith(color: _ansi16[c - 90 + 8]);
    } else if (c >= 100 && c <= 107) {
      s = s.copyWith(backgroundColor: _ansi16[c - 100 + 8]);
    }
  }
  return s;
}

Color _xterm256(int code) {
  if (code < 16) return _ansi16[code];
  if (code >= 232) {
    final v = 8 + (code - 232) * 10;
    return Color.fromARGB(0xFF, v, v, v);
  }
  final n = code - 16;
  final r = (n ~/ 36) * 51;
  final g = ((n ~/ 6) % 6) * 51;
  final b = (n % 6) * 51;
  return Color.fromARGB(0xFF, r, g, b);
}
