import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/todo_task.dart';
import '../providers/app_state.dart';
import '../widgets/task_tile.dart';
import 'task_screen.dart';

/// 智能视图：高优先级 / 未来 7 天即将到期 / 本周汇总。
class SmartViewScreen extends StatelessWidget {
  const SmartViewScreen({super.key});

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
    final color = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Row(
            children: [
              if (icon != null) ...[Icon(icon, size: 18, color: color), const SizedBox(width: 6)],
              Text(title,
                  style: const TextStyle(
                      fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('${tasks.length}',
                  style: TextStyle(fontSize: 13, color: color)),
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
    final high = state.highPriorityTasks;
    final upcoming = state.upcomingTasks;
    final (weekDue, weekDone) = state.weekSummary;

    return Scaffold(
      appBar: AppBar(title: const Text('智能视图')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          // 本周汇总卡片
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Icon(Icons.date_range_outlined,
                    size: 18, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 6),
                const Text('本周汇总',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const Spacer(),
                Text('${weekDue.length} 待完成 · ${weekDone.length} 已完成',
                    style: const TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
          ),
          _section(context, state, '高优先级', high, icon: Icons.flag_outlined),
          _section(context, state, '未来 7 天到期', upcoming,
              icon: Icons.event_outlined),
        ],
      ),
    );
  }
}