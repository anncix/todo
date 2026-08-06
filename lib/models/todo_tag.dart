/// 标签模型（可附加到任意任务上，多对多关联）
class TodoTag {
  final int? id;
  final String name;
  final int colorValue; // 标签颜色（ARGB int）
  final int createdAt;
  final int updatedAt;

  const TodoTag({
    this.id,
    required this.name,
    required this.colorValue,
    required this.createdAt,
    required this.updatedAt,
  });

  TodoTag copyWith({
    int? id,
    String? name,
    int? colorValue,
    int? createdAt,
    int? updatedAt,
  }) {
    return TodoTag(
      id: id ?? this.id,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'color_value': colorValue,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }

  factory TodoTag.fromMap(Map<String, Object?> map) {
    return TodoTag(
      id: map['id'] as int?,
      name: map['name'] as String,
      colorValue: map['color_value'] as int,
      createdAt: map['created_at'] as int,
      updatedAt: map['updated_at'] as int,
    );
  }

  Map<String, Object?> toSyncJson() {
    return {
      'uid': id,
      'name': name,
      'color_value': colorValue,
      'created_at': createdAt,
      'updated_at': updatedAt,
    };
  }
}