// 多选态共享逻辑的单测。
//
// 这些用例盯的是 **2026-09-23 那个 bug 的根**：多选态是**显式开关**，
// 「取消全选」「取消勾选最后一条」「剪掉失效项」都只清勾选、不退出多选态，
// 退出只有 [RecordSelection.exit] 一个口。
//
// 首页和回收站共用这一份实现，所以这些断言同时保护两个页面 ——
// 以前两边各写一份，改一处忘一处就出现了「首页改对了、回收站没改」的跑偏。

import 'package:flutter_test/flutter_test.dart';
import 'package:vestige/domain/record_selection.dart';

void main() {
  group('开关与勾选', () {
    test('初始：没进多选、一条没勾', () {
      final s = RecordSelection();
      expect(s.isActive, isFalse);
      expect(s.isEmpty, isTrue);
      expect(s.isNotEmpty, isFalse);
      expect(s.count, 0);
    });

    test('toggle 会顺带把开关打开', () {
      final s = RecordSelection();
      s.toggle('a');
      expect(s.isActive, isTrue);
      expect(s.count, 1);
      expect(s.contains('a'), isTrue);
    });

    test('再 toggle 同一条 = 取消勾选，但**不退出多选态**', () {
      final s = RecordSelection()..toggle('a');
      s.toggle('a');
      expect(s.isEmpty, isTrue, reason: '勾选被清空了');
      expect(s.isActive, isTrue, reason: '取消最后一条不该退出多选态');
    });

    test('exit 是唯一的关闭出口，关开关和清勾选一起做', () {
      final s = RecordSelection()..toggle('a');
      s.exit();
      expect(s.isActive, isFalse);
      expect(s.isEmpty, isTrue);
    });
  });

  group('全选 / 全不选', () {
    test('部分选中 → 点一下 = 补齐成全选', () {
      final s = RecordSelection()..toggle('a');
      s.toggleAll(<String>['a', 'b', 'c']);
      expect(s.count, 3);
      expect(s.isActive, isTrue);
    });

    test('已全选 → 点一下 = 只清勾选，**不退出多选态**', () {
      final s = RecordSelection()..toggle('a');
      const all = <String>['a', 'b', 'c'];
      s.toggleAll(all);
      s.toggleAll(all);
      expect(s.isEmpty, isTrue, reason: '勾选清空');
      expect(s.isActive, isTrue, reason: '取消全选不该退出多选态');
    });

    test('全不选之后还能再全选回来', () {
      final s = RecordSelection();
      const all = <String>['a', 'b'];
      s.toggleAll(all);
      s.toggleAll(all);
      expect(s.isEmpty, isTrue);
      s.toggleAll(all);
      expect(s.count, 2);
    });
  });

  group('三态判据', () {
    test('空勾选 → false；部分 → null；全勾 → true', () {
      final s = RecordSelection();
      const all = <String>['a', 'b'];
      expect(s.triStateOf(all), isFalse);
      s.toggle('a');
      expect(s.triStateOf(all), isNull);
      s.toggle('b');
      expect(s.triStateOf(all), isTrue);
    });

    test('空候选集不算「全选」', () {
      final s = RecordSelection();
      expect(s.coversAll(const <String>[]), isFalse);
      expect(s.triStateOf(const <String>[]), isFalse);
    });

    test('勾选集混进候选之外的 id 时，不能误判成「已全选」', () {
      // 这正是「点了已勾选的全选框却没反应」那个坑：
      // 若用「勾选数 ≥ 候选数」来判，这里 2 >= 1 会被判成全选，
      // 于是点下去走的是「全选」分支而不是「清空」。
      final s = RecordSelection()
        ..toggle('a')
        ..toggle('ghost');
      expect(s.coversAll(<String>['a']), isTrue);
      expect(s.triStateOf(<String>['a']), isTrue);
      // 换成另一个候选集：'a' 在里面但 'b' 没勾 → 只能是部分选中
      expect(s.triStateOf(<String>['a', 'b']), isNull);
    });
  });

  group('剪枝', () {
    test('prune 丢掉失效项，保留仍然有效的', () {
      final s = RecordSelection()
        ..toggle('a')
        ..toggle('b');
      final changed = s.prune(<String>['a']);
      expect(changed, isTrue);
      expect(s.ids, <String>{'a'});
      expect(s.isActive, isTrue, reason: '剪枝不该关开关');
    });

    test('剪到一条不剩也**不退出多选态**', () {
      final s = RecordSelection()..toggle('a');
      final changed = s.prune(const <String>[]);
      expect(changed, isTrue);
      expect(s.isEmpty, isTrue);
      expect(s.isActive, isTrue, reason: '退出由用户决定，别替他退');
    });

    test('没有失效项时 prune 返回 false（调用方据此免掉一次 setState）', () {
      final s = RecordSelection()..toggle('a');
      expect(s.prune(<String>['a', 'b']), isFalse);
    });

    test('hasStale 是只读预检，不改状态', () {
      final s = RecordSelection()..toggle('a');
      expect(s.hasStale(<String>['b']), isTrue);
      expect(s.count, 1, reason: '预检不能动勾选');
      expect(s.hasStale(<String>['a']), isFalse);
    });

    test('空勾选集谈不上失效', () {
      final s = RecordSelection();
      expect(s.hasStale(const <String>[]), isFalse);
      expect(s.prune(const <String>[]), isFalse);
    });
  });

  group('对外暴露的集合是只读的', () {
    test('ids 改不动；snapshot 是独立快照', () {
      final s = RecordSelection()..toggle('a');
      expect(() => s.ids.add('b'), throwsUnsupportedError);

      final snap = s.snapshot();
      s.toggle('b');
      expect(snap, <String>['a'], reason: '快照不该跟着变');
      expect(s.count, 2);
    });
  });
}
