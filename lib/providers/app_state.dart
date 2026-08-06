import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../database/db_helper.dart';
import '../models/pomodoro.dart';
import '../models/todo_list.dart';
import '../models/todo_tag.dart';
import '../models/todo_task.dart';
import '../services/backup_service.dart';
import '../services/notification_service.dart';
import '../services/webdav_sync.dart';

/// 全局状态管理（ChangeNotifier），负责数据加载、增删改查、通知与同步。
class AppState extends ChangeNotifier {
  final DbHelper _db = DbHelper.instance;
  final WebDavSyncService _sync = WebDavSyncService.instance;
  final BackupService _backup = BackupService.instance;

  List<TodoList> _lists = [];
  List<TodoTask> _tasks = [];
  List<TodoTag> _tags = [];
  Map<int, List<int>> _taskTags = {};
  WebDavConfig _config = const WebDavConfig(url: '', username: '', password: '');

  /// 当前选中的清单 id；null 表示「收件箱」
  int? _selectedListId;

  /// 当前筛选的标签 id；null 表示不按标签筛选
  int? _selectedTagId;

  /// 搜索关键字
  String _searchQuery = '';

  /// 主题模式
  ThemeMode _themeMode = ThemeMode.system;

  bool _loading = true;
  String _syncStatus = 'idle'; // idle | syncing | synced | error
  String? _syncError;

  /// 自动同步防抖定时器
  Timer? _autoSyncTimer;

  List<TodoList> get lists => List.unmodifiable(_lists);
  List<TodoTask> get tasks => List.unmodifiable(_tasks);
  List<TodoTag> get tags => List.unmodifiable(_tags);
  Map<int, List<int>> get taskTags => _taskTags;
  WebDavConfig get config => _config;
  int? get selectedListId => _selectedListId;
  int? get selectedTagId => _selectedTagId;
  String get searchQuery => _searchQuery;
  ThemeMode get themeMode => _themeMode;
  bool get loading => _loading;
  String get syncStatus => _syncStatus;
  String? get syncError => _syncError;

  /// 当前视图是否「收件箱」（未分配清单的任务）
  bool get isInbox => _selectedListId == null && _selectedTagId == null;

  /// 当前清单对象；收件箱时返回 null
  TodoList? get currentList {
    if (_selectedListId == null) return null;
    for (final l in _lists) {
      if (l.id == _selectedListId) return l;
    }
    return null;
  }

  /// 当前筛选的标签对象
  TodoTag? get currentTag {
    if (_selectedTagId == null) return null;
    for (final t in _tags) {
      if (t.id == _selectedTagId) return t;
    }
    return null;
  }

  /// 某任务的标签列表
  List<TodoTag> tagsOf(int? taskId) {
    if (taskId == null) return const [];
    final ids = _taskTags[taskId] ?? const [];
    return ids.map((id) {
      for (final t in _tags) {
        if (t.id == id) return t;
      }
      return null;
    }).whereType<TodoTag>().toList();
  }

  /// 某任务是否包含指定标签
  bool taskHasTag(int? taskId, int tagId) {
    return _taskTags[taskId]?.contains(tagId) ?? false;
  }

  /// 某任务的子任务
  List<TodoTask> subtasksOf(int parentId) {
    return _tasks
        .where((t) =>
            t.parentId == parentId &&
            t.deletedAt == null)
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  /// 当前视图下的顶级任务（不含子任务）
  List<TodoTask> get currentTasks {
    var base = _tasks.where((t) {
      if (t.deletedAt != null || t.parentId != null) return false;
      // 清单筛选
      if (_selectedTagId != null) {
        if (!taskHasTag(t.id, _selectedTagId!)) return false;
      } else if (isInbox) {
        if (t.listId != null) return false;
      } else {
        if (t.listId != _selectedListId) return false;
      }
      return true;
    }).toList();

    // 搜索筛选
    if (_searchQuery.trim().isNotEmpty) {
      final q = _searchQuery.toLowerCase();
      base = base
          .where((t) =>
              t.title.toLowerCase().contains(q) ||
              t.detail.toLowerCase().contains(q))
          .toList();
    }

    base.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.sortOrder != b.sortOrder) return a.sortOrder.compareTo(b.sortOrder);
      return a.id!.compareTo(b.id!);
    });
    return base;
  }

  /// 收件箱任务
  List<TodoTask> get inboxTasks {
    final filtered = _tasks
        .where((t) => t.deletedAt == null && t.listId == null && t.parentId == null)
        .toList();
    filtered.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.sortOrder != b.sortOrder) return a.sortOrder.compareTo(b.sortOrder);
      return a.id!.compareTo(b.id!);
    });
    return filtered;
  }

  /// 所有顶级任务（含收件箱），用于搜索/所有视图
  List<TodoTask> get allTasks {
    return _tasks.where((t) => t.deletedAt == null && t.parentId == null).toList();
  }

  // ==================== 今日视图 ====================

  /// 一天的起始毫秒时间戳
  static int _dayStart(DateTime d) =>
      DateTime(d.year, d.month, d.day).millisecondsSinceEpoch;
  static int _dayEnd(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59).millisecondsSinceEpoch;

  /// 逾期未完成的任务
  List<TodoTask> get overdueTasks {
    final end = _dayEnd(DateTime.now());
    return allTasks
        .where((t) => !t.done && t.dueDate != null && t.dueDate! < end)
        .toList()
      ..sort((a, b) => (a.dueDate ?? 0).compareTo(b.dueDate ?? 0));
  }

  /// 今天到期且未完成的任务
  List<TodoTask> get dueTodayTasks {
    final start = _dayStart(DateTime.now());
    final end = _dayEnd(DateTime.now());
    return allTasks
        .where((t) =>
            !t.done && t.dueDate != null && t.dueDate! >= start && t.dueDate! <= end)
        .toList()
      ..sort((a, b) => (a.dueDate ?? 0).compareTo(b.dueDate ?? 0));
  }

  /// 今天完成的任务
  List<TodoTask> get completedTodayTasks {
    final start = _dayStart(DateTime.now());
    final end = _dayEnd(DateTime.now());
    return allTasks
        .where((t) =>
            t.done &&
            t.doneAt != null &&
            t.doneAt! >= start &&
            t.doneAt! <= end)
        .toList()
      ..sort((a, b) => (b.doneAt ?? 0).compareTo(a.doneAt ?? 0));
  }

  // ==================== 智能视图 ====================

  /// 高优先级未完成任务（中/高）
  List<TodoTask> get highPriorityTasks {
    return allTasks
        .where((t) => !t.done && t.priority >= 2)
        .toList()
      ..sort((a, b) => b.priority.compareTo(a.priority));
  }

  /// 未来 7 天即将到期且未完成的任务
  List<TodoTask> get upcomingTasks {
    final start = _dayEnd(DateTime.now());
    final end = _dayEnd(DateTime.now().add(const Duration(days: 7)));
    return allTasks
        .where((t) =>
            !t.done && t.dueDate != null && t.dueDate! > start && t.dueDate! <= end)
        .toList()
      ..sort((a, b) => (a.dueDate ?? 0).compareTo(b.dueDate ?? 0));
  }

  /// 本周到期（未完成）与本周完成（已完成）的任务
  (List<TodoTask>, List<TodoTask>) get weekSummary {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    final start = _dayStart(monday);
    final sunday = now.add(Duration(days: 7 - now.weekday));
    final end = _dayEnd(sunday);

    final due = allTasks
        .where((t) =>
            !t.done && t.dueDate != null && t.dueDate! >= start && t.dueDate! <= end)
        .toList()
      ..sort((a, b) => (a.dueDate ?? 0).compareTo(b.dueDate ?? 0));

    final completed = allTasks
        .where((t) =>
            t.done && t.doneAt != null && t.doneAt! >= start && t.doneAt! <= end)
        .toList()
      ..sort((a, b) => (b.doneAt ?? 0).compareTo(a.doneAt ?? 0));

    return (due, completed);
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  // ==================== 初始化 ====================

  /// 应用启动时调用：加载配置 + 数据 + 通知
  Future<void> init() async {
    await _loadConfig();
    await _loadData();
    await NotificationService.instance.init();
    _loading = false;
    notifyListeners();
    // 启动时自动同步一次
    _autoSync();
  }

  Future<void> _loadConfig() async {
    final prefs = await SharedPreferences.getInstance();
    _config = WebDavConfig(
      url: prefs.getString('webdav_url') ?? '',
      username: prefs.getString('webdav_user') ?? '',
      password: prefs.getString('webdav_pass') ?? '',
    );
    final themeName = prefs.getString('theme_mode') ?? 'system';
    _themeMode = switch (themeName) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> _loadData() async {
    _lists = await _db.getLists();
    _tasks = await _db.getAllTasks();
    _tags = await _db.getTags();
    _taskTags = await _db.getAllTaskTags();
  }

  /// 保存主题模式
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
    notifyListeners();
  }

  // ==================== 搜索 ====================

  void setSearch(String query) {
    _searchQuery = query;
    notifyListeners();
  }

  // ==================== 清单操作 ====================

  Future<void> addList(String name, {int color = 0xFF4B3FE3}) async {
    final now = _now();
    final list = TodoList(
      name: name,
      colorValue: color,
      sortOrder: _lists.length,
      createdAt: now,
      updatedAt: now,
    );
    final id = await _db.insertList(list);
    await _loadData();
    _selectedListId = id;
    notifyListeners();
    _autoSync();
  }

  Future<void> renameList(int id, String name) async {
    final list = _lists.firstWhere((l) => l.id == id);
    final updated = list.copyWith(name: name, updatedAt: _now());
    await _db.updateList(updated);
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  Future<void> deleteList(int id) async {
    await _db.deleteList(id);
    if (_selectedListId == id) _selectedListId = null;
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  void selectList(int? id) {
    _selectedListId = id;
    _selectedTagId = null;
    notifyListeners();
  }

  // ==================== 标签操作 ====================

  Future<void> addTag(String name, {int color = 0xFF22A5F7}) async {
    final now = _now();
    final tag = TodoTag(
      name: name,
      colorValue: color,
      createdAt: now,
      updatedAt: now,
    );
    await _db.insertTag(tag);
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  Future<void> deleteTag(int id) async {
    await _db.deleteTag(id);
    if (_selectedTagId == id) _selectedTagId = null;
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  void selectTag(int? id) {
    _selectedTagId = id;
    _selectedListId = null;
    notifyListeners();
  }

  /// 给任务设置标签集合
  Future<void> setTagsForTask(int taskId, List<int> tagIds) async {
    await _db.setTaskTags(taskId, tagIds);
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  // ==================== 任务操作 ====================

  Future<int?> addTask({
    required String title,
    int? listId,
    String detail = '',
    int? dueDate,
    int priority = 0,
    int? parentId,
    String? repeatRule,
    int? repeatUntil,
    int reminderMinutes = 0,
  }) async {
    final now = _now();
    final task = TodoTask(
      listId: listId ?? (parentId == null ? _selectedListId : _listIdOf(parentId)),
      parentId: parentId,
      title: title,
      done: false,
      detail: detail,
      dueDate: dueDate,
      priority: priority,
      sortOrder: _tasks.length,
      createdAt: now,
      updatedAt: now,
      repeatRule: repeatRule,
      repeatUntil: repeatUntil,
      reminderMinutes: reminderMinutes,
    );
    final id = await _db.insertTask(task);
    await _loadData();
    // 若有截止时间则调度提醒
    await _rescheduleReminder(task.copyWith(id: id));
    notifyListeners();
    _autoSync();
    return id;
  }

  int? _listIdOf(int? parentId) {
    if (parentId == null) return null;
    for (final t in _tasks) {
      if (t.id == parentId) return t.listId;
    }
    return null;
  }

  Future<void> updateTask(TodoTask task) async {
    final updated = task.copyWith(updatedAt: _now());
    await _db.updateTask(updated);
    await _loadData();
    await _rescheduleReminder(updated);
    notifyListeners();
    _autoSync();
  }

  /// 切换完成状态；若为重复任务，勾选完成时推进到下一次。
  Future<void> toggleDone(TodoTask task) async {
    final now = _now();
    if (!task.done && task.isRepeating) {
      final next = task.nextDueDate();
      if (next != null) {
        // 推进到期日并重置完成状态
        final updated = task.copyWith(
          doneAt: now, // 记录本次完成
          dueDate: next,
          done: false,
          updatedAt: now,
        );
        await _db.updateTask(updated);
        await _loadData();
        await _rescheduleReminder(updated);
        notifyListeners();
        _autoSync();
        return;
      }
      // 重复已过期，退化为普通完成
    }
    await _db.toggleTaskDone(task);
    final reloaded = await _db.getTaskById(task.id!);
    await _loadData();
    if (reloaded != null) await _rescheduleReminder(reloaded);
    notifyListeners();
    _autoSync();
  }

  /// 新增子任务
  Future<int?> addSubtask(int parentId, String title) {
    return addTask(title: title, parentId: parentId);
  }

  Future<void> deleteTask(int id) async {
    await _db.deleteTask(id);
    await NotificationService.instance.cancelReminder(id);
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  /// 拖拽排序：更新列表中任务的顺序
  Future<void> reorderTasks(List<int> orderedIds) async {
    for (var i = 0; i < orderedIds.length; i++) {
      await _db.updateTaskOrder(orderedIds[i], i);
    }
    await _loadData();
    notifyListeners();
    _autoSync();
  }

  /// 调度或取消某任务的提醒
  Future<void> _rescheduleReminder(TodoTask task) async {
    if (task.id == null) return;
    if (task.deletedAt != null || task.done || task.dueDate == null) {
      await NotificationService.instance.cancelReminder(task.id!);
      return;
    }
    await NotificationService.instance.scheduleTaskReminder(task);
  }

  // ==================== WebDAV 配置 ====================

  Future<void> saveConfig(WebDavConfig config) async {
    _config = config;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('webdav_url', config.url);
    await prefs.setString('webdav_user', config.username);
    await prefs.setString('webdav_pass', config.password);
    notifyListeners();
  }

  // ==================== 同步 ====================

  /// 手动/启动时执行一次完整同步：拉取远端 -> 合并 -> 写回本地 -> 上传
  Future<void> sync() async {
    if (!_config.isConfigured) {
      _setSync('error', '未配置 WebDAV，请先在设置中填写服务器、账号与密码');
      return;
    }
    _setSync('syncing', null);
    try {
      final remote = await _sync.pull(_config);
      final local = SyncData(
        lists: await _db.getAllLists(),
        tasks: await _db.getAllTasks(),
        tags: await _db.getTags(),
        taskTags: await _db.getAllTaskTags(),
      );

      final merged = _sync.merge(remote, local);

      await _db.replaceAll(
          merged.lists, merged.tasks, merged.tags, merged.taskTags);
      await _sync.push(_config, merged);

      await _loadData();
      _setSync('synced', null);
    } catch (e) {
      _setSync('error', '同步失败：$e');
    }
  }

  /// 仅上传本地数据到远端（自动同步使用，不拉取）
  Future<void> push() async {
    if (!_config.isConfigured) return;
    try {
      final data = SyncData(
        lists: await _db.getAllLists(),
        tasks: await _db.getAllTasks(),
        tags: await _db.getTags(),
        taskTags: await _db.getAllTaskTags(),
      );
      await _sync.push(_config, data);
      _setSync('synced', null);
    } catch (_) {
      // 自动同步失败静默处理，避免打扰
    }
  }

  /// 数据变更后触发防抖自动同步（2 秒内无新变更才上传）
  void _autoSync() {
    if (!_config.isConfigured) return;
    _autoSyncTimer?.cancel();
    _autoSyncTimer = Timer(const Duration(seconds: 2), () {
      push();
    });
  }

  /// 测试 WebDAV 连接
  Future<bool> testConfig(WebDavConfig config) {
    return _sync.testConnection(config);
  }

  // ==================== 番茄钟 ====================

  /// 读取番茄钟设置
  Future<PomodoroSettings> getPomodoroSettings() {
    return _db.getPomodoroSettings();
  }

  /// 保存番茄钟设置
  Future<void> savePomodoroSettings(PomodoroSettings settings) {
    return _db.savePomodoroSettings(settings);
  }

  /// 新增一条番茄钟会话记录
  Future<int> addPomodoroSession(PomodoroSession session) {
    return _db.insertPomodoroSession(session);
  }

  /// 更新一条番茄钟会话记录
  Future<void> updatePomodoroSession(PomodoroSession session) {
    return _db.updatePomodoroSession(session);
  }

  /// 最近 N 条番茄钟记录
  Future<List<PomodoroSession>> recentPomodoroSessions({int limit = 50}) {
    return _db.getRecentPomodoroSessions(limit: limit);
  }

  /// 某任务的番茄钟记录
  Future<List<PomodoroSession>> pomodoroSessionsForTask(int taskId) {
    return _db.getPomodoroSessionsForTask(taskId);
  }

  /// 删除某条番茄钟记录
  Future<void> deletePomodoroSession(int id) {
    return _db.deletePomodoroSession(id);
  }

  // ==================== 备份 ====================

  /// 导出备份，返回文件路径
  Future<String> exportBackup() {
    return _backup.exportToFile(
      _lists,
      _tasks,
      _tags,
      _taskTags,
    );
  }

  /// 从备份文件恢复（整体替换当前数据）
  Future<bool> importBackup(String path) async {
    final parsed = _backup.parseFile(path);
    if (parsed == null) return false;
    await _db.replaceAll(parsed.lists, parsed.tasks, parsed.tags, parsed.taskTags);
    await _loadData();
    notifyListeners();
    _autoSync();
    return true;
  }

  void _setSync(String status, String? error) {
    _syncStatus = status;
    _syncError = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    super.dispose();
  }
}