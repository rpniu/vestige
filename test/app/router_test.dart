// 2026-10-27 审查 M-004 的回归测试：编辑页路由参数的编码 / 解码必须成对。
//
// 背景：CSV 导入的 ID 直接当主键，而 `/edit/<id>` 是把它拼进 URL 路径的。
// 含 `/`、空格、`#` 的 id 会让路由匹配失败（记录点不开）；
// 而「先 encode、读的时候又用已解码的 pathParameters」这类错配只会在特殊 id 上暴露。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/app/router.dart';

void main() {
  group('[M-004] 编辑页路由参数', () {
    test('写入侧对特殊字符做 encode', () {
      expect(AppRoutes.editExisting('a1'), '/edit/a1');
      expect(AppRoutes.editExisting('a/b'), '/edit/a%2Fb');
      expect(AppRoutes.editExisting('a b'), '/edit/a%20b');
      expect(AppRoutes.editExisting('a#b'), '/edit/a%23b');
      expect(AppRoutes.editExisting('a?b'), '/edit/a%3Fb');
    });

    test('读取侧用 pathSegments 恰好解码一次（与 router._recordIdOf 同一机制）', () {
      // 这是 `_recordIdOf` 依赖的语义：Uri 把 %2F 还原成 '/'
      for (final raw in const <String>['a/b', 'a b', 'a#b', 'a?b']) {
        final uri = Uri.parse(AppRoutes.editExisting(raw));
        expect(
          uri.pathSegments.last,
          raw,
          reason: 'encode 与 pathSegments 解码必须严格成对',
        );
      }
    });

    test('中文 id 同样可往返', () {
      final raw = '记录-一';
      final uri = Uri.parse(AppRoutes.editExisting(raw));
      expect(uri.pathSegments.last, raw);
    });
  });
}
