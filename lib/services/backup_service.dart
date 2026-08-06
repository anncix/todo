import 'dart:convert';
import 'dart:io';

import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/todo_list.dart';
import '../models/todo_tag.dart';
import '../models/todo_task.dart';

/// 本地备份服务：把全部数据导出为 JSON 文件，或从 JSON 文件恢复。
class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  /// 导出所有数据为 JSON 字符串
  String toJson(
    List<TodoList> lists,
    List<TodoTask> tasks,
    List<TodoTag> tags,
    Map<int, List<int>> taskTags,
  ) {
    return jsonEncode({
      'app': 'flutter_todo',
      'version': 4,
      'exported_at': DateTime.now().toIso8601String(),
      'lists': lists.map((l) => l.toSyncJson()).toList(),
      'tasks': tasks.map((t) => t.toSyncJson()).toList(),
      'tags': tags.map((t) => t.toSyncJson()).toList(),
      'task_tags': taskTags.map((taskId, tagIds) => MapEntry(
            '$taskId',
            tagIds,
          )),
    });
  }

  /// 把数据导出为文件，返回文件路径。
  Future<String> exportToFile(
    List<TodoList> lists,
    List<TodoTask> tasks,
    List<TodoTag> tags,
    Map<int, List<int>> taskTags,
  ) async {
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
    final file = File(p.join(dir.path, 'flutter_todo_backup_$stamp.json'));
    await file.writeAsString(toJson(lists, tasks, tags, taskTags));
    return file.path;
  }

  /// 从文件解析备份数据。
  /// 返回 null 表示文件格式不合法。
  ({List<TodoList> lists, List<TodoTask> tasks, List<TodoTag> tags,
      Map<int, List<int>> taskTags})? parseFile(String path) {
    final content = File(path).readAsStringSync();
    return parse(content);
  }

  ({List<TodoList> lists, List<TodoTask> tasks, List<TodoTag> tags,
      Map<int, List<int>> taskTags})? parse(String content) {
    try {
      final data = jsonDecode(content) as Map<String, dynamic>;

      final lists = <TodoList>[];
      for (final item in (data['lists'] as List? ?? [])) {
        lists.add(_listFromJson(item as Map<String, dynamic>));
      }
      final tasks = <TodoTask>[];
      for (final item in (data['tasks'] as List? ?? [])) {
        tasks.add(_taskFromJson(item as Map<String, dynamic>));
      }
      final tags = <TodoTag>[];
      for (final item in (data['tags'] as List? ?? [])) {
        tags.add(_tagFromJson(item as Map<String, dynamic>));
      }
      final taskTags = <int, List<int>>{};
      (data['task_tags'] as Map<String, dynamic>? ?? {}).forEach((k, v) {
        taskTags[int.parse(k)] = (v as List).map((e) => e as int).toList();
      });

      return (lists: lists, tasks: tasks, tags: tags, taskTags: taskTags);
    } catch (_) {
      return null;
    }
  }

  TodoList _listFromJson(Map<String, dynamic> m) => TodoList(
        id: m['uid'] as int,
        name: m['name'] as String,
        colorValue: m['color_value'] as int,
        sortOrder: m['sort_order'] as int,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        deletedAt: m['deleted_at'] as int?,
      );

  TodoTask _taskFromJson(Map<String, dynamic> m) => TodoTask(
        id: m['uid'] as int,
        listId: m['list_uid'] as int?,
        parentId: m['parent_uid'] as int?,
        title: m['title'] as String,
        done: m['done'] as bool,
        detail: m['detail'] as String,
        dueDate: m['due_date'] as int?,
        priority: m['priority'] as int,
        sortOrder: m['sort_order'] as int,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
        doneAt: m['done_at'] as int?,
        deletedAt: m['deleted_at'] as int?,
        repeatRule: m['repeat_rule'] as String?,
        repeatUntil: m['repeat_until'] as int?,
        reminderMinutes: m['reminder_minutes'] as int? ?? 0,
      );

  TodoTag _tagFromJson(Map<String, dynamic> m) => TodoTag(
        id: m['uid'] as int,
        name: m['name'] as String,
        colorValue: m['color_value'] as int,
        createdAt: m['created_at'] as int,
        updatedAt: m['updated_at'] as int,
      );
}