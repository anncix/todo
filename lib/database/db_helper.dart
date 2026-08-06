import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';

import '../models/pomodoro.dart';
import '../models/todo_list.dart';
import '../models/todo_tag.dart';
import '../models/todo_task.dart';

/// SQLite 数据库助手，负责清单、任务、标签与关联的本地持久化。
class DbHelper {
  DbHelper._();
  static final DbHelper instance = DbHelper._();

  static const _dbName = 'flutter_todo.db';
  static const _dbVersion = 3;

  Database? _db;

  Future<Database> get database async {
    _db ??= await _open();
    return _db!;
  }

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await _createListsTable(db);
    await _createTasksTable(db);
    await _createTagsTables(db);
    await _createPomodoroTables(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      // v1 -> v2：任务表新增子任务与重复字段
      await db.execute(
          'ALTER TABLE todo_tasks ADD COLUMN parent_id INTEGER');
      await db.execute(
          'ALTER TABLE todo_tasks ADD COLUMN repeat_rule TEXT');
      await db.execute(
          'ALTER TABLE todo_tasks ADD COLUMN repeat_until INTEGER');
      await _createTagsTables(db);
    }
    if (oldVersion < 3) {
      // v2 -> v3：任务表新增提前提醒字段 + 番茄钟表
      await db.execute(
          'ALTER TABLE todo_tasks ADD COLUMN reminder_minutes INTEGER NOT NULL DEFAULT 0');
      await _createPomodoroTables(db);
    }
  }

  Future<void> _createListsTable(Database db) async {
    await db.execute('''
      CREATE TABLE todo_lists (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color_value INTEGER NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        deleted_at INTEGER
      )
    ''');
  }

  Future<void> _createTasksTable(Database db) async {
    await db.execute('''
      CREATE TABLE todo_tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        list_id INTEGER,
        parent_id INTEGER,
        title TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        detail TEXT NOT NULL DEFAULT '',
        due_date INTEGER,
        priority INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        done_at INTEGER,
        deleted_at INTEGER,
        repeat_rule TEXT,
        repeat_until INTEGER,
        reminder_minutes INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute('CREATE INDEX idx_tasks_list ON todo_tasks(list_id)');
    await db.execute('CREATE INDEX idx_tasks_done ON todo_tasks(done)');
    await db.execute('CREATE INDEX idx_tasks_parent ON todo_tasks(parent_id)');
  }

  Future<void> _createTagsTables(Database db) async {
    await db.execute('''
      CREATE TABLE tags (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        color_value INTEGER NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE task_tags (
        task_id INTEGER NOT NULL,
        tag_id INTEGER NOT NULL,
        PRIMARY KEY (task_id, tag_id)
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_task_tags_tag ON task_tags(tag_id)');
  }

  // ==================== 番茄钟表 ====================

  Future<void> _createPomodoroTables(Database db) async {
    await db.execute('''
      CREATE TABLE pomodoro_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER,
        type TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL,
        started_at INTEGER NOT NULL,
        finished_at INTEGER,
        completed INTEGER NOT NULL DEFAULT 0
      )
    ''');
    await db.execute(
        'CREATE INDEX idx_pomodoro_task ON pomodoro_sessions(task_id)');
    await db.execute('''
      CREATE TABLE pomodoro_settings (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        focus_minutes INTEGER NOT NULL DEFAULT 25,
        short_break_minutes INTEGER NOT NULL DEFAULT 5,
        long_break_minutes INTEGER NOT NULL DEFAULT 15,
        long_break_interval INTEGER NOT NULL DEFAULT 4
      )
    ''');
  }

  // ==================== 清单 CRUD ====================

  /// 返回所有未删除的清单，按排序号排列
  Future<List<TodoList>> getLists() async {
    final db = await database;
    final rows = await db.query(
      'todo_lists',
      where: 'deleted_at IS NULL',
      orderBy: 'sort_order ASC, id ASC',
    );
    return rows.map(TodoList.fromMap).toList();
  }

  /// 返回所有清单（含逻辑删除的），用于同步合并
  Future<List<TodoList>> getAllLists() async {
    final db = await database;
    final rows = await db.query('todo_lists');
    return rows.map(TodoList.fromMap).toList();
  }

  Future<int> insertList(TodoList list) async {
    final db = await database;
    return db.insert('todo_lists', list.toMap());
  }

  Future<void> updateList(TodoList list) async {
    final db = await database;
    await db.update(
      'todo_lists',
      list.toMap(),
      where: 'id = ?',
      whereArgs: [list.id],
    );
  }

  /// 逻辑删除清单（同时逻辑删除其下任务）
  Future<void> deleteList(int id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'todo_lists',
        {'deleted_at': now, 'updated_at': now},
        where: 'id = ?',
        whereArgs: [id],
      );
      await txn.update(
        'todo_tasks',
        {'deleted_at': now, 'updated_at': now},
        where: 'list_id = ? AND deleted_at IS NULL',
        whereArgs: [id],
      );
    });
  }

  // ==================== 任务 CRUD ====================

  /// 获取指定清单下的未删除任务（listId 为 null 时为收件箱）
  Future<List<TodoTask>> getTasks({int? listId}) async {
    final db = await database;
    final rows = await db.query(
      'todo_tasks',
      where: listId == null
          ? 'deleted_at IS NULL AND list_id IS NULL'
          : 'deleted_at IS NULL AND list_id = ?',
      whereArgs: listId == null ? null : [listId],
      orderBy: 'done ASC, sort_order ASC, id ASC',
    );
    return rows.map(TodoTask.fromMap).toList();
  }

  /// 返回所有任务（含逻辑删除的），用于同步合并
  Future<List<TodoTask>> getAllTasks() async {
    final db = await database;
    final rows = await db.query('todo_tasks');
    return rows.map(TodoTask.fromMap).toList();
  }

  Future<TodoTask?> getTaskById(int id) async {
    final db = await database;
    final rows = await db.query(
      'todo_tasks',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return TodoTask.fromMap(rows.first);
  }

  Future<int> insertTask(TodoTask task) async {
    final db = await database;
    return db.insert('todo_tasks', task.toMap());
  }

  Future<void> updateTask(TodoTask task) async {
    final db = await database;
    await db.update(
      'todo_tasks',
      task.toMap(),
      where: 'id = ?',
      whereArgs: [task.id],
    );
  }

  /// 逻辑删除单个任务（同时删除其子任务与标签关联）
  Future<void> deleteTask(int id) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.transaction((txn) async {
      await txn.update(
        'todo_tasks',
        {'deleted_at': now, 'updated_at': now},
        where: 'id = ? OR parent_id = ?',
        whereArgs: [id, id],
      );
      await txn.delete('task_tags', where: 'task_id = ?', whereArgs: [id]);
    });
  }

  /// 切换任务完成状态
  Future<void> toggleTaskDone(TodoTask task) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final done = !task.done;
    await updateTask(task.copyWith(
      done: done,
      doneAt: done ? now : null,
      updatedAt: now,
    ));
  }

  /// 更新任务的排序号
  Future<void> updateTaskOrder(int id, int sortOrder) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'todo_tasks',
      {'sort_order': sortOrder, 'updated_at': now},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==================== 标签 CRUD ====================

  Future<List<TodoTag>> getTags() async {
    final db = await database;
    final rows = await db.query('tags', orderBy: 'name ASC');
    return rows.map(TodoTag.fromMap).toList();
  }

  Future<int> insertTag(TodoTag tag) async {
    final db = await database;
    return db.insert('tags', tag.toMap());
  }

  Future<void> updateTag(TodoTag tag) async {
    final db = await database;
    await db.update(
      'tags',
      tag.toMap(),
      where: 'id = ?',
      whereArgs: [tag.id],
    );
  }

  Future<void> deleteTag(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('tags', where: 'id = ?', whereArgs: [id]);
      await txn.delete('task_tags', where: 'tag_id = ?', whereArgs: [id]);
    });
  }

  /// 获取某任务的标签 id 列表
  Future<List<int>> getTaskTagIds(int taskId) async {
    final db = await database;
    final rows = await db.query(
      'task_tags',
      columns: ['tag_id'],
      where: 'task_id = ?',
      whereArgs: [taskId],
    );
    return rows.map((r) => r['tag_id'] as int).toList();
  }

  /// 设置某任务的标签集合（先清空再写入）
  Future<void> setTaskTags(int taskId, List<int> tagIds) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('task_tags', where: 'task_id = ?', whereArgs: [taskId]);
      final batch = txn.batch();
      for (final tagId in tagIds) {
        batch.insert('task_tags', {'task_id': taskId, 'tag_id': tagId});
      }
      await batch.commit(noResult: true);
    });
  }

  /// 返回所有任务-标签关联映射（taskId -> List<tagId>）
  Future<Map<int, List<int>>> getAllTaskTags() async {
    final db = await database;
    final rows = await db.query('task_tags');
    final map = <int, List<int>>{};
    for (final r in rows) {
      final taskId = r['task_id'] as int;
      final tagId = r['tag_id'] as int;
      map.putIfAbsent(taskId, () => []).add(tagId);
    }
    return map;
  }

  // ==================== 同步批量写入 ====================

  /// 用合并后的数据整体重写所有表（事务内原子提交）
  Future<void> replaceAll(
    List<TodoList> lists,
    List<TodoTask> tasks,
    List<TodoTag> tags,
    Map<int, List<int>> taskTags,
  ) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('task_tags');
      await txn.delete('tags');
      await txn.delete('todo_tasks');
      await txn.delete('todo_lists');
      final batch = txn.batch();
      for (final l in lists) {
        batch.insert('todo_lists', l.toMap());
      }
      for (final t in tasks) {
        batch.insert('todo_tasks', t.toMap());
      }
      for (final tag in tags) {
        batch.insert('tags', tag.toMap());
      }
      taskTags.forEach((taskId, tagIds) {
        for (final tagId in tagIds) {
          batch.insert('task_tags', {'task_id': taskId, 'tag_id': tagId});
        }
      });
      await batch.commit(noResult: true);
    });
  }

  // ==================== 番茄钟 CRUD ====================

  Future<int> insertPomodoroSession(PomodoroSession session) async {
    final db = await database;
    return db.insert('pomodoro_sessions', session.toMap());
  }

  Future<void> updatePomodoroSession(PomodoroSession session) async {
    final db = await database;
    await db.update(
      'pomodoro_sessions',
      session.toMap(),
      where: 'id = ?',
      whereArgs: [session.id],
    );
  }

  /// 最近 N 条番茄钟记录（按开始时间倒序）
  Future<List<PomodoroSession>> getRecentPomodoroSessions({int limit = 50}) async {
    final db = await database;
    final rows = await db.query(
      'pomodoro_sessions',
      orderBy: 'started_at DESC',
      limit: limit,
    );
    return rows.map(PomodoroSession.fromMap).toList();
  }

  /// 某任务的番茄钟记录
  Future<List<PomodoroSession>> getPomodoroSessionsForTask(int taskId) async {
    final db = await database;
    final rows = await db.query(
      'pomodoro_sessions',
      where: 'task_id = ?',
      whereArgs: [taskId],
      orderBy: 'started_at DESC',
    );
    return rows.map(PomodoroSession.fromMap).toList();
  }

  /// 读取番茄钟设置（无记录则返回默认值）
  Future<PomodoroSettings> getPomodoroSettings() async {
    final db = await database;
    final rows = await db.query('pomodoro_settings', limit: 1);
    if (rows.isEmpty) return const PomodoroSettings();
    return PomodoroSettings.fromMap(rows.first);
  }

  /// 保存番茄钟设置（覆盖单行）
  Future<void> savePomodoroSettings(PomodoroSettings settings) async {
    final db = await database;
    final rows = await db.query('pomodoro_settings', limit: 1);
    if (rows.isEmpty) {
      await db.insert('pomodoro_settings', settings.toMap());
    } else {
      await db.update(
        'pomodoro_settings',
        settings.toMap(),
        where: 'id = ?',
        whereArgs: [rows.first['id']],
      );
    }
  }

  /// 删除某条番茄钟记录
  Future<void> deletePomodoroSession(int id) async {
    final db = await database;
    await db.delete('pomodoro_sessions', where: 'id = ?', whereArgs: [id]);
  }
}