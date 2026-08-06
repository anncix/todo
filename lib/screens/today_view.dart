import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/todo_task.dart';
import '../providers/app_state.dart';
import '../widgets/task_tile.dart';
import 'task_screen.dart';

/// 今日视图：逾期 / 今天到期 / 今日完成。
class TodayViewScreen extends StatelessWidget {
  const TodayViewScreen({super.key});

  Future<void> _openTask(BuildContext context, TodoTask? task,
      int? presetListId) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => TaskScreen(task: task, presetListId: presetListId),
    ));
  }

  Future<void> _confirmDelete(BuildContext context, TodoTask task) async {
    final state = context.read<AppState>();
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
    if (ok == true) await state.deleteTask(task.id!);
  }

  Widget _section(BuildContext context, AppState state, String title,
      List<TodoTask> tasks, {IconData? icon}) {
    if (tasks.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
              ],
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('${tasks.length}',
                  style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.primary)),
            ],
          ),
        ),
        for (final task in tasks)
          TaskTile(
            task: task,
            tagList: state.tagsOf(task.id),
            onTap: () => _openTask(context, task, null),
            onToggle: () => state.toggleDone(task),
            onDelete: () => _confirmDelete(context, task),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final overdue = state.overdueTasks;
    final today = state.dueTodayTasks;
    final done = state.completedTodayTasks;

    return Scaffold(
      appBar: AppBar(title: const Text('今天')),
      body: overdue.isEmpty && today.isEmpty && done.isEmpty
          ? const Center(child: Text('今天暂无任务', style: TextStyle(color: Colors.grey)))
          : ListView(
              padding: const EdgeInsets.only(bottom: 16),
              children: [
                _section(context, state, '逾期', overdue, icon: Icons.error_outline),
                _section(context, state, '今天到期', today, icon: Icons.event_outlined),
                _section(context, state, '已完成', done, icon: Icons.check_circle_outline),
              ],
            ),
    );
  }
}