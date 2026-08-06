import 'dart:convert';
import 'dart:typed_data';

import 'package:webdav_client/webdav_client.dart';

import '../models/todo_list.dart';
import '../models/todo_tag.dart';
import '../models/todo_task.dart';

/// WebDAV 配置（url / 账号 / 密码）
class WebDavConfig {
  final String url;
  final String username;
  final String password;

  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
  });

  bool get isConfigured => url.trim().isNotEmpty && username.trim().isNotEmpty;

  WebDavConfig copyWith({
    String? url,
    String? username,
    String? password,
  }) {
    return WebDavConfig(
      url: url ?? this.url,
      username: username ?? this.username,
      password: password ?? this.password,
    );
  }
}

/// 一次同步的完整数据集
class SyncData {
  final List<TodoList> lists;
  final List<TodoTask> tasks;
  final List<TodoTag> tags;
  final Map<int, List<int>> taskTags;

  const SyncData({
    required this.lists,
    required this.tasks,
    required this.tags,
    required this.taskTags,
  });
}

/// WebDAV 同步服务。
///
/// 采用「整库 JSON 快照」同步：
/// - 把本地所有清单、任务、标签与关联序列化为一个 JSON 文件上传到远端；
/// - 拉取时读取远端 JSON，与本地的每一条记录按 `updatedAt` 取较新者合并，
///   再整体写回本地并上传，从而支持多端编辑不丢数据。
class WebDavSyncService {
  WebDavSyncService._();
  static final WebDavSyncService instance = WebDavSyncService._();

  /// 远端保存的文件名
  static const remoteFile = '/flutter_todo_sync.json';

  Client _newClient(WebDavConfig config) {
    return newClient(
      config.url,
      user: config.username,
      password: config.password,
      debug: false,
    );
  }

  /// 测试连接是否可用
  Future<bool> testConnection(WebDavConfig config) async {
    try {
      final client = _newClient(config);
      await client.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 导出本地数据为 JSON 字符串
  String exportToJson(SyncData data) {
    return jsonEncode({
      'version': 4,
      'lists': data.lists.map((l) => l.toSyncJson()).toList(),
      'tasks': data.tasks.map((t) => t.toSyncJson()).toList(),
      'tags': data.tags.map((t) => t.toSyncJson()).toList(),
      'task_tags': data.taskTags.map((taskId, tagIds) => MapEntry(
            '$taskId',
            tagIds,
          )),
    });
  }

  /// 把本地数据上传到 WebDAV
  Future<void> push(WebDavConfig config, SyncData data) async {
    final client = _newClient(config);
    final content = exportToJson(data);
    final bytes = Uint8List.fromList(utf8.encode(content));
    await client.write(remoteFile, bytes);
  }

  /// 从 WebDAV 拉取远端 JSON 字符串；远端不存在时返回 null。
  ///
  /// 先列目录确认文件是否存在，避免把网络错误误判为「首次同步」。
  Future<String?> pull(WebDavConfig config) async {
    final client = _newClient(config);
    final fileName = remoteFile.split('/').last;
    final entries = await client.readDir('/');
    final exists =
        entries.any((f) => f.name == fileName || f.path == remoteFile);
    if (!exists) return null;
    final bytes = await client.read(remoteFile);
    return utf8.decode(bytes);
  }

  /// 合并远端 JSON 与本地数据，返回合并后的结果。
  /// 「按 updatedAt 取较新者」，uid(id) 作为合并主键。
  SyncData merge(
    String? remoteJson,
    SyncData local,
  ) {
    if (remoteJson == null || remoteJson.trim().isEmpty) {
      return local;
    }

    final data = jsonDecode(remoteJson) as Map<String, dynamic>;

    // 远端清单
    final remoteListMap = <int, TodoList>{};
    for (final item in (data['lists'] as List? ?? [])) {
      final m = item as Map<String, dynamic>;
      final uid = m['uid'] as int?;
      if (uid == null) continue;
      remoteListMap[uid] = _listFromJson(m);
    }

    // 远端任务
    final remoteTaskMap = <int, TodoTask>{};
    for (final item in (data['tasks'] as List? ?? [])) {
      final m = item as Map<String, dynamic>;
      final uid = m['uid'] as int?;
      if (uid == null) continue;
      remoteTaskMap[uid] = _taskFromJson(m);
    }

    // 远端标签
    final remoteTagMap = <int, TodoTag>{};
    for (final item in (data['tags'] as List? ?? [])) {
      final m = item as Map<String, dynamic>;
      final uid = m['uid'] as int?;
      if (uid == null) continue;
      remoteTagMap[uid] = _tagFromJson(m);
    }

    // 合并清单
    final mergedLists = <TodoList>[];
    final seenListIds = <int>{};
    for (final local in local.lists) {
      if (local.id == null) continue;
      seenListIds.add(local.id!);
      final remote = remoteListMap[local.id];
      mergedLists.add(remote != null && remote.updatedAt > local.updatedAt
          ? remote
          : local);
    }
    for (final remote in remoteListMap.values) {
      if (!seenListIds.contains(remote.id)) mergedLists.add(remote);
    }

    // 合并任务
    final mergedTasks = <TodoTask>[];
    final seenTaskIds = <int>{};
    for (final local in local.tasks) {
      if (local.id == null) continue;
      seenTaskIds.add(local.id!);
      final remote = remoteTaskMap[local.id];
      mergedTasks.add(remote != null && remote.updatedAt > local.updatedAt
          ? remote
          : local);
    }
    for (final remote in remoteTaskMap.values) {
      if (!seenTaskIds.contains(remote.id)) mergedTasks.add(remote);
    }

    // 合并标签
    final mergedTags = <TodoTag>[];
    final seenTagIds = <int>{};
    for (final local in local.tags) {
      if (local.id == null) continue;
      seenTagIds.add(local.id!);
      final remote = remoteTagMap[local.id];
      mergedTags.add(remote != null && remote.updatedAt > local.updatedAt
          ? remote
          : local);
    }
    for (final remote in remoteTagMap.values) {
      if (!seenTagIds.contains(remote.id)) mergedTags.add(remote);
    }

    // 合并任务-标签关联：取并集（交集处保留远端）
    final mergedTaskTags = <int, List<int>>{};
    final mergedTaskTagIds = <int, Set<int>>{};
    local.taskTags.forEach((taskId, tagIds) {
      mergedTaskTagIds.putIfAbsent(taskId, () => {}).addAll(tagIds);
    });
    final remoteTaskTagsRaw = data['task_tags'] as Map<String, dynamic>? ?? {};
    remoteTaskTagsRaw.forEach((taskIdStr, tagIds) {
      final taskId = int.tryParse('$taskIdStr');
      if (taskId != null) {
        mergedTaskTagIds.putIfAbsent(taskId, () => {}).addAll(
            (tagIds as List).map((e) => e as int));
      }
    });
    mergedTaskTagIds.forEach((taskId, tagSet) {
      mergedTaskTags[taskId] = tagSet.toList()..sort();
    });

    return SyncData(
      lists: mergedLists,
      tasks: mergedTasks,
      tags: mergedTags,
      taskTags: mergedTaskTags,
    );
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