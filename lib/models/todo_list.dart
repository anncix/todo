/// 清单模型（一个清单 = 一组任务的容器）
class TodoList {
  final int? id;
  final String name;
  final int colorValue; // 清单颜色（ARGB int）
  final int sortOrder; // 排序号
  final int createdAt;
  final int updatedAt; // 用于同步冲突解决
  final int? deletedAt; // 逻辑删除时间戳，null 表示未删除（同步友好）

  const TodoList({
    this.id,
    required this.name,
    required this.colorValue,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
  });

  TodoList copyWith({
    int? id,
    String? name,
    int? colorValue,
    int? sortOrder,
    int? createdAt,
    int? updatedAt,
    Object? deletedAt = _sentinel,
  }) {
    return TodoList(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      deletedAt: deletedAt == _sentinel ? this.deletedAt : deletedAt as int?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'color_value': colorValue,
      'sort_order': sortOrder,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
    };
  }

  factory TodoList.fromMap(Map<String, Object?> map) {
    return TodoList(
      id: map['id'] as int?,
      name: map['name'] as String,
      colorValue: map['color_value'] as int,
      sortOrder: map['sort_order'] as int,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
      deletedAt: map['deleted_at'] as int?,
    );
  }

  /// 导出为同步用的 JSON map（不含自增 id，避免跨端冲突）
  Map<String, Object?> toSyncJson() {
    return {
      'uid': id,
      'name': name,
      'color_value': colorValue,
      'sort_order': sortOrder,
      'created_at': createdAt,
      'updated_at': updatedAt,
      'deleted_at': deletedAt,
    };
  }
}

const _sentinel = Object();