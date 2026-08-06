/// 番茄钟会话类型
enum PomodoroType {
  focus('专注'),
  shortBreak('短休息'),
  longBreak('长休息');

  final String label;
  const PomodoroType(this.label);
}

/// 一条番茄钟记录（持久化到数据库）
class PomodoroSession {
  final int? id;
  final int? taskId; // 关联任务（可为 null）
  final PomodoroType type;
  final int durationSeconds; // 计划时长
  final int startedAt; // 开始时间戳
  final int? finishedAt; // 完成时间戳（null 表示未完成/中断）
  final bool completed; // 是否完整跑完

  const PomodoroSession({
    this.id,
    this.taskId,
    required this.type,
    required this.durationSeconds,
    required this.startedAt,
    this.finishedAt,
    required this.completed,
  });

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'task_id': taskId,
      'type': type.name,
      'duration_seconds': durationSeconds,
      'started_at': startedAt,
      'finished_at': finishedAt,
      'completed': completed ? 1 : 0,
    };
  }

  factory PomodoroSession.fromMap(Map<String, Object?> map) {
    return PomodoroSession(
      id: map['id'] as int?,
      taskId: map['task_id'] as int?,
      type: PomodoroType.values.firstWhere(
        (t) => t.name == map['type'],
        orElse: () => PomodoroType.focus,
      ),
      durationSeconds: map['duration_seconds'] as int,
      startedAt: map['started_at'] as int,
      finishedAt: map['finished_at'] as int?,
      completed: (map['completed'] as int) == 1,
    );
  }
}

/// 番茄钟设置（专注时长、短休息、长休息、长休息间隔）
class PomodoroSettings {
  final int focusMinutes;
  final int shortBreakMinutes;
  final int longBreakMinutes;
  final int longBreakInterval; // 每 N 个番茄后长休息

  const PomodoroSettings({
    this.focusMinutes = 25,
    this.shortBreakMinutes = 5,
    this.longBreakMinutes = 15,
    this.longBreakInterval = 4,
  });

  PomodoroSettings copyWith({
    int? focusMinutes,
    int? shortBreakMinutes,
    int? longBreakMinutes,
    int? longBreakInterval,
  }) {
    return PomodoroSettings(
      focusMinutes: focusMinutes ?? this.focusMinutes,
      shortBreakMinutes: shortBreakMinutes ?? this.shortBreakMinutes,
      longBreakMinutes: longBreakMinutes ?? this.longBreakMinutes,
      longBreakInterval: longBreakInterval ?? this.longBreakInterval,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'focus_minutes': focusMinutes,
      'short_break_minutes': shortBreakMinutes,
      'long_break_minutes': longBreakMinutes,
      'long_break_interval': longBreakInterval,
    };
  }

  factory PomodoroSettings.fromMap(Map<String, Object?> map) {
    return PomodoroSettings(
      focusMinutes: map['focus_minutes'] as int? ?? 25,
      shortBreakMinutes: map['short_break_minutes'] as int? ?? 5,
      longBreakMinutes: map['long_break_minutes'] as int? ?? 15,
      longBreakInterval: map['long_break_interval'] as int? ?? 4,
    );
  }
}

/// 番茄钟计时状态
class PomodoroTimer {
  final PomodoroType type;
  final int totalSeconds;
  final int remainingSeconds;
  final bool running;
  final int completedFocusCount; // 本次会话完成的专注数
  final int? taskId;

  const PomodoroTimer({
    required this.type,
    required this.totalSeconds,
    required this.remainingSeconds,
    required this.running,
    required this.completedFocusCount,
    this.taskId,
  });

  /// 进度 0~1
  double get progress =>
      totalSeconds == 0 ? 0 : 1 - (remainingSeconds / totalSeconds);

  int get elapsedSeconds => totalSeconds - remainingSeconds;

  String get timeText {
    final m = (remainingSeconds ~/ 60).toString().padLeft(2, '0');
    final s = (remainingSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}