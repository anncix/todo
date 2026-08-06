/// 任务模型（一个 TODO 项）
class TodoTask {
  final int? id;
  final int? listId; // 所属清单，null 表示「收件箱」
  final int? parentId; // 所属父任务，非 null 表示这是子任务
  final String title;
  final bool done; // 是否完成
  final String detail; // 备注
  final int? dueDate; // 截止时间戳（毫秒）
  final int priority; // 优先级 0=无 1=低 2=中 3=高
  final int sortOrder; // 排序号
  final int createdAt;
  final int updatedAt; // 用于同步冲突解决
  final int? doneAt; // 完成时间戳
  final int? deletedAt; // 逻辑删除时间戳
  final String? repeatRule; // 重复规则："daily"|"weekly"|"monthly"|"yearly"|"custom:N"|null
  final int? repeatUntil; // 重复截止时间戳；null 表示无限重复
  final int reminderMinutes; // 截止前提前提醒的分钟数，0=准时提醒

  const TodoTask({
    this.id,
    this.listId,
    this.parentId,
    required this.title,
    required this.done,
    required this.detail,
    this.dueDate,
    required this.priority,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.doneAt,
    this.deletedAt,
    this.repeatRule,
    this.repeatUntil,
    this.reminderMinutes = 0,
  });

  /// 是否为子任务
  bool get isSubtask => parentId != null;

  /// 是否为重复任务
  bool get isRepeating => repeatRule != null;

  TodoTask copyWith({
    int? id,
    Object? listId = _sentinel,
    Object? parentId = _sentinel,
    String? title,
    bool? done,
    String? detail,
    Object? dueDate = _sentinel,
    int? priority,
    int? sortOrder,
    int? createdAt,
    int? updatedAt,
    Object? doneAt = _sentinel,
    Object? deletedAt = _sentinel,
    Object? repeatRule = _sentinel,
    Object? repeatUntil = _sentinel,
    int? reminderMinutes,
  }) {
    return TodoTask(
      id: id ?? this.id,
      listId: listId == _sentinel ? this.listId : listId as int?,
      parentId: parentId == _sentinel ? this.parentId : parentId as int?,
      title: title ?? this.title,
      done: done ?? this.done,
      detail: detail ?? this.detail,
      dueDate: dueDate == _sentinel ? this.dueDate : dueDate as int?,
      priority: priority ?? this.priority,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      doneAt: doneAt == _sentinel ? this.doneAt : doneAt as int?,
      deletedAt: deletedAt == _sentinel ? this.deletedAt : deletedAt as int?,
      repeatRule: repeatRule == _sentinel ? this.repeatRule : repeatRule as String?,
      repeatUntil: repeatUntil == _sentinel
          ? this.repeatUntil
          : repeatUntil as int?,
      reminderMinutes: reminderMinutes ?? this.reminderMinutes,
    );
  }

  /// 计算下一次重复的截止时间戳（毫秒）。
  /// 若已超过 repeatUntil 或规则无法解析，返回 null。
  int? nextDueDate() {
    if (repeatRule == null || dueDate == null) return null;
    final base = DateTime.fromMillisecondsSinceEpoch(dueDate!);
    DateTime next = _advance(base);
    if (repeatUntil != null && next.millisecondsSinceEpoch > repeatUntil!) {
      return null;
    }
    return next.millisecondsSinceEpoch;
  }

  DateTime _advance(DateTime d) {
    final rule = repeatRule!;
    switch (rule) {
      case 'daily':
        return d.add(const Duration(days: 1));
      case 'weekly':
        return d.add(const Duration(days: 7));
      case 'monthly':
        return DateTime(d.year, d.month + 1, d.day,
            d.hour, d.minute, d.second);
      case 'yearly':
        return DateTime(d.year + 1, d.month, d.day,
            d.hour, d.minute, d.second);
      default:
        // custom:N —— 每 N 天
        if (rule.startsWith('custom:')) {
          final n = int.tryParse(rule.substring('custom:'.length));
          if (n != null && n > 0) {
            return d.add(Duration(days: n));
          }
        }
        return d.add(const Duration(days: 1));
    }
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'list_id': listId,
      'parent_id': parentId,
      'title': title,
      'done': done ? 1 : 0,
      'detail': detail,
      'due_date': dueDate,
      'priority': priority,
      'sort_order': sortOrder,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'done_at': doneAt,
      'deleted_at': deletedAt,
      'repeat_rule': repeatRule,
      'repeat_until': repeatUntil,
      'reminder_minutes': reminderMinutes,
    };
  }

  factory TodoTask.fromMap(Map<String, Object?> map) {
    return TodoTask(
      id: map['id'] as int?,
      listId: map['list_id'] as int?,
      parentId: map['parent_id'] as int?,
      title: map['title'] as String,
      done: (map['done'] as int) == 1,
      detail: map['detail'] as String,
      dueDate: map['due_date'] as int?,
      priority: map['priority'] as int,
      sortOrder: map['sort_order'] as int,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
      doneAt: map['done_at'] as int?,
      deletedAt: map['deleted_at'] as int?,
      repeatRule: map['repeat_rule'] as String?,
      repeatUntil: map['repeat_until'] as int?,
      reminderMinutes: map['reminder_minutes'] as int? ?? 0,
    );
  }

  /// 导出为同步用的 JSON map（不含自增 id）
  Map<String, Object?> toSyncJson() {
    return {
      'uid': id,
      'list_uid': listId,
      'parent_uid': parentId,
      'title': title,
      'done': done,
      'detail': detail,
      'due_date': dueDate,
      'priority': priority,
      'sort_order': sortOrder,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'done_at': doneAt,
      'deleted_at': deletedAt,
      'repeat_rule': repeatRule,
      'repeat_until': repeatUntil,
      'reminder_minutes': reminderMinutes,
    };
  }
}

const _sentinel = Object();