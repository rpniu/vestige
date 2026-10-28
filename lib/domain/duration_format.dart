/// 时长的展示格式化（纯函数）。输入一律是**秒**（存储单位，见
/// records.durationS）；展示按跨度自动选单位，非零的秒数不被静默吞掉。
String durationLabel(int seconds) {
  if (seconds < 60) return '$seconds 秒';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  final parts = <String>[
    if (hours > 0) '$hours 小时',
    if (minutes > 0) '$minutes 分钟',
    if (rest > 0) '$rest 秒',
  ];
  return parts.join(' ');
}

/// 紧凑格式（卡片标签 / 统计格子用）：`45秒` / `5分` / `1分30秒` / `1时20分`。
String durationLabelCompact(int seconds) {
  if (seconds < 60) return '$seconds秒';
  final hours = seconds ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final rest = seconds % 60;
  final suffix = rest > 0 ? '$rest秒' : '';
  if (hours > 0) {
    return minutes > 0 ? '$hours时$minutes分$suffix' : '$hours时$suffix';
  }
  return '$minutes分$suffix';
}

/// 计时中的钟面格式：`MM:SS`（超过 1 小时进位成 `H:MM:SS`）。
String elapsedClockLabel(int seconds) {
  // 时钟回拨（起点落在未来）会算出负秒数：`~/` 与 `%` 对负数向零取整，
  // -30 会得到 "59:30" 这种荒谬值。计时永远不该显示负时长，一律按 0 处理。
  final int safe = seconds < 0 ? 0 : seconds;
  final hours = safe ~/ 3600;
  final minutes = (safe % 3600) ~/ 60;
  final rest = safe % 60;
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${rest.toString().padLeft(2, '0')}';
  }
  return '${minutes.toString().padLeft(2, '0')}:${rest.toString().padLeft(2, '0')}';
}
