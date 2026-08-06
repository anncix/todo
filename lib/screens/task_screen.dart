import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/todo_task.dart';
import '../providers/app_state.dart';
import 'pomodoro_screen.dart';

/// 任务新增/编辑页
class TaskScreen extends StatefulWidget {
  final TodoTask? task; // null 表示新增
  final int? presetListId;

  const TaskScreen({super.key, this.task, this.presetListId});

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  final _titleCtrl = TextEditingController();
  final _detailCtrl = TextEditingController();
  final _subtaskCtrl = TextEditingController();
  int? _listId;
  DateTime? _dueDate;
  int _priority = 0;
  String? _repeatRule;
  int _reminderMinutes = 0;
  Set<int> _selectedTagIds = {};

  bool get _isEdit => widget.task != null;

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    if (t != null) {
      _titleCtrl.text = t.title;
      _detailCtrl.text = t.detail;
      _listId = t.listId;
      _dueDate = t.dueDate != null
          ? DateTime.fromMillisecondsSinceEpoch(t.dueDate!)
          : null;
      _priority = t.priority;
      _repeatRule = t.repeatRule;
      _reminderMinutes = t.reminderMinutes;
      _selectedTagIds = Set.of(
        _stateOrNull()?.taskTags[t.id] ?? const [],
      );
    } else {
      _listId = widget.presetListId;
    }
  }

  AppState? _stateOrNull() {
    try {
      return context.read<AppState>();
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _detailCtrl.dispose();
    _subtaskCtrl.dispose();
    super.dispose();
  }

  static const _repeatNames = {
    null: '不重复',
    'daily': '每天',
    'weekly': '每周',
    'monthly': '每月',
    'yearly': '每年',
  };
  static const _priorityNames = ['无', '低', '中', '高'];
  static const _reminderNames = {
    0: '不提醒',
    1: '准时提醒',
    5: '提前 5 分钟',
    10: '提前 10 分钟',
    15: '提前 15 分钟',
    30: '提前 30 分钟',
    60: '提前 1 小时',
    120: '提前 2 小时',
    1440: '提前 1 天',
  };

  Future<void> _pickDueDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _dueDate = picked);
  }

  Future<void> _save() async {
    final title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入任务标题')));
      return;
    }
    final state = context.read<AppState>();
    final due = _dueDate?.millisecondsSinceEpoch;

    if (_isEdit) {
      final t = widget.task!;
      await state.updateTask(t.copyWith(
        title: title,
        detail: _detailCtrl.text.trim(),
        listId: _listId,
        dueDate: due,
        priority: _priority,
        repeatRule: _repeatRule,
        reminderMinutes: _reminderMinutes,
      ));
      await state.setTagsForTask(t.id!, _selectedTagIds.toList());
    } else {
      final newId = await state.addTask(
        title: title,
        listId: _listId,
        detail: _detailCtrl.text.trim(),
        dueDate: due,
        priority: _priority,
        repeatRule: _repeatRule,
        reminderMinutes: _reminderMinutes,
      );
      if (newId != null) {
        await state.setTagsForTask(newId, _selectedTagIds.toList());
      }
    }
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _addSubtask(AppState state) async {
    final title = _subtaskCtrl.text.trim();
    if (title.isEmpty || widget.task == null) return;
    await state.addSubtask(widget.task!.id!, title);
    _subtaskCtrl.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final subtasks = widget.task == null
        ? const <TodoTask>[]
        : state.subtasksOf(widget.task!.id!);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEdit ? '编辑任务' : '新建任务'),
        actions: [
          if (_isEdit)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                await state.deleteTask(widget.task!.id!);
                if (mounted) Navigator.of(context).pop();
              },
            ),
          TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _titleCtrl,
            autofocus: !_isEdit,
            decoration: const InputDecoration(
              labelText: '标题',
              hintText: '要做点什么？',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _detailCtrl,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: '备注',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          _fieldTile(
            icon: Icons.folder_outlined,
            label: '清单',
            value: _listName(state),
            onTap: () => _pickList(state),
          ),
          const SizedBox(height: 12),
          _fieldTile(
            icon: Icons.event_outlined,
            label: '截止日期',
            value: _dueDate == null
                ? '无'
                : DateFormat('yyyy-MM-dd').format(_dueDate!),
            trailing: _dueDate != null
                ? IconButton(
                    icon: const Icon(Icons.clear),
                    onPressed: () => setState(() => _dueDate = null),
                  )
                : null,
            onTap: _pickDueDate,
          ),
          const SizedBox(height: 12),
          _fieldTile(
            icon: Icons.flag_outlined,
            label: '优先级',
            value: _priorityNames[_priority],
            onTap: _pickPriority,
          ),
          const SizedBox(height: 12),
          _fieldTile(
            icon: Icons.repeat,
            label: '重复',
            value: _repeatNames[_repeatRule] ?? '不重复',
            onTap: _pickRepeat,
          ),
          const SizedBox(height: 12),
          _fieldTile(
            icon: Icons.notifications_active_outlined,
            label: '截止提醒',
            value: _reminderNames[_reminderMinutes] ?? '不提醒',
            onTap: _pickReminder,
          ),
          if (_isEdit) ...[
            const SizedBox(height: 12),
            ListTile(
              dense: true,
              leading: const Icon(Icons.timer_outlined),
              title: const Text('番茄钟'),
              subtitle: const Text('为这个任务开始专注计时'),
              trailing: const Icon(Icons.chevron_right),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
                side: BorderSide(color: Theme.of(context).dividerColor),
              ),
              onTap: () {
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PomodoroScreen(task: widget.task),
                ));
              },
            ),
          ],
          const SizedBox(height: 12),
          // 标签多选
          _buildTagSection(state),
          // 子任务
          if (_isEdit) ...[
            const SizedBox(height: 20),
            const Divider(),
            const Text('子任务',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
            const SizedBox(height: 8),
            for (final sub in subtasks)
              ListTile(
                dense: true,
                leading: Checkbox(
                  value: sub.done,
                  onChanged: (_) => state.toggleDone(sub),
                ),
                title: Text(
                  sub.title,
                  style: sub.done
                      ? const TextStyle(
                          decoration: TextDecoration.lineThrough)
                      : null,
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  onPressed: () => state.deleteTask(sub.id!),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _subtaskCtrl,
                    decoration: const InputDecoration(
                      hintText: '添加子任务…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _addSubtask(state),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _addSubtask(state),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _fieldTile({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
    Widget? trailing,
  }) {
    return ListTile(
      dense: true,
      leading: Icon(icon),
      title: Text(label),
      subtitle: Text(value),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
    );
  }

  Widget _buildTagSection(AppState state) {
    if (state.tags.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('暂无标签，可在设置或抽屉中创建标签',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('标签',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final tag in state.tags)
              FilterChip(
                label: Text(tag.name),
                avatar: CircleAvatar(
                  radius: 8,
                  backgroundColor: Color(tag.colorValue),
                ),
                selected: _selectedTagIds.contains(tag.id),
                onSelected: (sel) {
                  setState(() {
                    if (sel) {
                      _selectedTagIds.add(tag.id!);
                    } else {
                      _selectedTagIds.remove(tag.id);
                    }
                  });
                },
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  String _listName(AppState state) {
    if (_listId == null) return '收件箱';
    for (final l in state.lists) {
      if (l.id == _listId) return l.name;
    }
    return '收件箱';
  }

  void _pickList(AppState state) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('收件箱'),
              trailing: _listId == null ? const Icon(Icons.check) : null,
              onTap: () {
                setState(() => _listId = null);
                Navigator.of(ctx).pop();
              },
            ),
            for (final l in state.lists)
              ListTile(
                leading: CircleAvatar(
                  radius: 10,
                  backgroundColor: Color(l.colorValue),
                ),
                title: Text(l.name),
                trailing: _listId == l.id ? const Icon(Icons.check) : null,
                onTap: () {
                  setState(() => _listId = l.id);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickPriority() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (var i = 0; i < _priorityNames.length; i++)
              ListTile(
                title: Text(_priorityNames[i]),
                trailing: _priority == i ? const Icon(Icons.check) : null,
                onTap: () {
                  setState(() => _priority = i);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickRepeat() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in _repeatNames.entries)
              ListTile(
                title: Text(entry.value),
                trailing:
                    _repeatRule == entry.key ? const Icon(Icons.check) : null,
                onTap: () {
                  setState(() => _repeatRule = entry.key);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }

  void _pickReminder() {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final entry in _reminderNames.entries)
              ListTile(
                title: Text(entry.value),
                trailing: _reminderMinutes == entry.key
                    ? const Icon(Icons.check)
                    : null,
                onTap: () {
                  setState(() => _reminderMinutes = entry.key);
                  Navigator.of(ctx).pop();
                },
              ),
          ],
        ),
      ),
    );
  }
}