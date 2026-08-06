import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/todo_list.dart';
import '../models/todo_tag.dart';
import '../models/todo_task.dart';
import '../providers/app_state.dart';
import 'pomodoro_screen.dart';
import 'settings_screen.dart';
import 'smart_view.dart';
import 'task_screen.dart';
import 'today_view.dart';

/// 主界面：左侧抽屉（清单/标签）+ 右侧任务列表
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _inputCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();

  @override
  void dispose() {
    _inputCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _addTaskFromInput(AppState state) async {
    final title = _inputCtrl.text.trim();
    if (title.isEmpty) return;
    await state.addTask(title: title);
    _inputCtrl.clear();
  }

  Future<void> _openTask(TodoTask? task, int? presetListId) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TaskScreen(task: task, presetListId: presetListId),
    ));
  }

  Future<void> _confirmDeleteTask(AppState state, TodoTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除任务'),
        content: Text('确定删除「${task.title}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && mounted) await state.deleteTask(task.id!);
  }

  Future<void> _confirmDeleteList(AppState state, TodoList list) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除清单'),
        content: Text('确定删除「${list.name}」及其全部任务吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除')),
        ],
      ),
    );
    if (ok == true && mounted) await state.deleteList(list.id!);
  }

  Future<void> _renameList(AppState state, TodoList list) async {
    final ctrl = TextEditingController(text: list.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名清单'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('保存')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await state.renameList(list.id!, name);
  }

  Future<void> _newList(AppState state) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建清单'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await state.addList(name);
  }

  Future<void> _newTag(AppState state) async {
    final ctrl = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建标签'),
        content: TextField(controller: ctrl, autofocus: true),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('创建')),
        ],
      ),
    );
    if (name != null && name.isNotEmpty) await state.addTag(name);
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();

    if (state.loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final tasks = state.currentTasks;
    final title = state.currentTag != null
        ? '#${state.currentTag!.name}'
        : state.isInbox
            ? '收件箱'
            : (state.currentList?.name ?? '清单');

    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          _SyncIndicator(state: state),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      drawer: _buildDrawer(state),
      body: Column(
        children: [
          // 搜索框
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => state.setSearch(v),
              decoration: InputDecoration(
                hintText: '搜索任务标题或备注…',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          state.setSearch('');
                        },
                      ),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                ),
              ),
            ),
          ),
          // 任务列表（可拖拽排序）
          Expanded(
            child: tasks.isEmpty
                ? _EmptyHint(title: title)
                : _buildTaskList(state, tasks),
          ),
          // 底部输入框
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _inputCtrl,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        hintText: '添加任务到「$title」…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                      onSubmitted: (_) => _addTaskFromInput(state),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    icon: const Icon(Icons.add),
                    onPressed: () => _addTaskFromInput(state),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTaskList(AppState state, List<TodoTask> tasks) {
    return ReorderableListView.builder(
      itemCount: tasks.length,
      onReorder: (oldIndex, newIndex) {
        if (newIndex > oldIndex) newIndex -= 1;
        final ids = tasks.map((t) => t.id!).toList();
        final moved = ids.removeAt(oldIndex);
        ids.insert(newIndex, moved);
        state.reorderTasks(ids);
      },
      itemBuilder: (ctx, i) {
        final task = tasks[i];
        return _TaskTile(
          key: ValueKey('task-${task.id}'),
          task: task,
          tagList: state.tagsOf(task.id),
          onTap: () => _openTask(task, null),
          onToggle: () => state.toggleDone(task),
          onDelete: () => _confirmDeleteTask(state, task),
        );
      },
    );
  }

  Widget _buildDrawer(AppState state) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text('清单',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            ),
            ListTile(
              leading: const Icon(Icons.inbox_outlined),
              title: const Text('收件箱'),
              selected: state.isInbox && state.selectedTagId == null,
              onTap: () {
                state.selectList(null);
                Navigator.of(context).pop();
              },
            ),
            ListTile(
              leading: const Icon(Icons.today_outlined),
              title: const Text('今天'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const TodayViewScreen(),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.auto_awesome_outlined),
              title: const Text('智能视图'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const SmartViewScreen(),
                ));
              },
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('番茄钟'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => const PomodoroScreen(),
                ));
              },
            ),
            const Divider(),
            Expanded(
              child: ListView(
                children: [
                  for (final l in state.lists)
                    _listTile(state, l),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('新建清单'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          _newList(state);
                        },
                      ),
                    ),
                  ),
                  const Divider(),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        const Text('标签',
                            style: TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w600)),
                        const Spacer(),
                        IconButton(
                          icon: const Icon(Icons.add, size: 20),
                          onPressed: () {
                            Navigator.of(context).pop();
                            _newTag(state);
                          },
                        ),
                      ],
                    ),
                  ),
                  for (final tag in state.tags) _tagTile(state, tag),
                ],
              ),
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _listTile(AppState state, TodoList l) {
    return ListTile(
      leading: CircleAvatar(
        radius: 10,
        backgroundColor: Color(l.colorValue),
      ),
      title: Text(l.name),
      selected: state.selectedListId == l.id,
      onTap: () {
        state.selectList(l.id);
        Navigator.of(context).pop();
      },
      onLongPress: () => _showListActions(state, l),
    );
  }

  Widget _tagTile(AppState state, TodoTag tag) {
    final selected = state.selectedTagId == tag.id;
    return ListTile(
      leading: CircleAvatar(
        radius: 10,
        backgroundColor: Color(tag.colorValue),
      ),
      title: Text('#${tag.name}'),
      selected: selected,
      trailing: selected
          ? IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: () {
                state.selectTag(null);
                Navigator.of(context).pop();
              },
            )
          : null,
      onTap: () {
        state.selectTag(tag.id);
        Navigator.of(context).pop();
      },
      onLongPress: () => _showTagActions(state, tag),
    );
  }

  void _showListActions(AppState state, TodoList list) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () {
                Navigator.of(ctx).pop();
                _renameList(state, list);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除', style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.of(ctx).pop();
                _confirmDeleteList(state, list);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showTagActions(AppState state, TodoTag tag) {
    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text('删除标签', style: TextStyle(color: Colors.red)),
              onTap: () async {
                Navigator.of(ctx).pop();
                await state.deleteTag(tag.id!);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// 单个任务行（支持滑动删除）
class _TaskTile extends StatelessWidget {
  final TodoTask task;
  final List<TodoTag> tagList;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const _TaskTile({
    super.key,
    required this.task,
    required this.tagList,
    required this.onTap,
    required this.onToggle,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('dismiss-${task.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) => onDelete(),
      child: ListTile(
        leading: Checkbox(
          value: task.done,
          onChanged: (_) => onToggle(),
        ),
        title: Text(
          task.title,
          style: TextStyle(
            decoration: task.done ? TextDecoration.lineThrough : null,
            color: task.done ? theme.disabledColor : null,
          ),
        ),
        subtitle: _Subtitle(task: task, tags: tagList),
        onTap: onTap,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (task.isRepeating)
              const Icon(Icons.repeat, size: 16, color: Colors.grey),
            if (task.priority > 0)
              Icon(Icons.flag,
                  size: 18, color: _priorityColor(task.priority)),
          ],
        ),
      ),
    );
  }

  Color _priorityColor(int p) {
    switch (p) {
      case 3:
        return Colors.red;
      case 2:
        return Colors.orange;
      case 1:
        return Colors.blue;
      default:
        return Colors.transparent;
    }
  }
}

class _Subtitle extends StatelessWidget {
  final TodoTask task;
  final List<TodoTag> tags;
  const _Subtitle({required this.task, required this.tags});

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    if (task.dueDate != null) {
      parts.add(Text(
        DateFormat('MM-dd')
            .format(DateTime.fromMillisecondsSinceEpoch(task.dueDate!)),
        style: const TextStyle(color: Colors.grey),
      ));
    }
    if (task.detail.isNotEmpty) {
      parts.add(Text(task.detail, maxLines: 1, overflow: TextOverflow.ellipsis));
    }
    if (parts.isEmpty && tags.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        ...parts,
        if (parts.isNotEmpty && tags.isNotEmpty) const SizedBox(width: 6),
        if (tags.isNotEmpty)
          Expanded(
            child: Wrap(
              spacing: 4,
              runSpacing: 2,
              children: [
                for (final tag in tags)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: Color(tag.colorValue).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '#${tag.name}',
                      style: TextStyle(
                        fontSize: 11,
                        color: Color(tag.colorValue),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 空状态提示
class _EmptyHint extends StatelessWidget {
  final String title;
  const _EmptyHint({required this.title});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.checklist, size: 56, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('「$title」暂无任务', style: TextStyle(color: Colors.grey.shade600)),
        ],
      ),
    );
  }
}

/// AppBar 上的同步状态指示
class _SyncIndicator extends StatelessWidget {
  final AppState state;
  const _SyncIndicator({required this.state});

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    final Color color;
    switch (state.syncStatus) {
      case 'syncing':
        return const Padding(
          padding: EdgeInsets.all(10),
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2.5),
          ),
        );
      case 'synced':
        icon = Icons.cloud_done_outlined;
        color = Colors.green;
        break;
      case 'error':
        icon = Icons.cloud_off;
        color = Colors.red;
        break;
      default:
        icon = Icons.cloud_outlined;
        color = Colors.grey;
    }
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: '同步',
      onPressed: () => context.read<AppState>().sync(),
    );
  }
}