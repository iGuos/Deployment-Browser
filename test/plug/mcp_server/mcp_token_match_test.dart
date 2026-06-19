import 'package:deployment/plug/mcp_server/core/mcp_server_config.dart';
import 'package:deployment/plug/mcp_server/core/mcp_token.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('constantTimeEquals', () {
    test('相等返回 true', () {
      expect(constantTimeEquals('mcp_abc123', 'mcp_abc123'), isTrue);
    });

    test('内容不同返回 false', () {
      expect(constantTimeEquals('mcp_abc123', 'mcp_abc124'), isFalse);
      expect(constantTimeEquals('mcp_abc123', 'xxx_abc123'), isFalse);
    });

    test('长度不同返回 false', () {
      expect(constantTimeEquals('mcp_abc', 'mcp_abc123'), isFalse);
      expect(constantTimeEquals('', 'x'), isFalse);
    });

    test('空串相等', () {
      expect(constantTimeEquals('', ''), isTrue);
    });
  });

  group('McpServerConfig.tokenIdForSecret', () {
    McpToken tok(String id, String secret) =>
        McpToken(id: id, label: id, secret: secret);

    final config = McpServerConfig(
      enabled: true,
      port: 8765,
      tokens: [tok('t1', 'mcp_aaa'), tok('t2', 'mcp_bbb')],
    );

    test('命中正确令牌返回对应 id', () {
      expect(config.tokenIdForSecret('mcp_aaa'), 't1');
      expect(config.tokenIdForSecret('mcp_bbb'), 't2');
    });

    test('前缀相同但不完全匹配不命中', () {
      expect(config.tokenIdForSecret('mcp_aa'), isNull);
      expect(config.tokenIdForSecret('mcp_aaaa'), isNull);
    });

    test('空 / 未知令牌返回 null', () {
      expect(config.tokenIdForSecret(null), isNull);
      expect(config.tokenIdForSecret(''), isNull);
      expect(config.tokenIdForSecret('   '), isNull);
      expect(config.tokenIdForSecret('unknown'), isNull);
    });

    test('两端空白被裁剪后匹配', () {
      expect(config.tokenIdForSecret('  mcp_aaa  '), 't1');
    });
  });
}
