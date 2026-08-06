import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/todo_tag.dart';
import '../models/todo_task.dart';

/// 可复用的任务行：复选框 + 标题 + 副标题（截止/备注/标签）+ 优先级/重复标记。
class TaskTile extends StatelessWidget {
  final TodoTask task;
  final List<TodoTag> tagList;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onDelete;

  const TaskTile({
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
    final isOverdue = !task.done &&
        task.dueDate != null &&
        task.dueDate! < DateTime.now().millisecondsSinceEpoch;
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
        subtitle: _TaskSubtitle(task: task, tags: tagList),
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
        // 逾期任务用细微底色提示
        tileColor: isOverdue
            ? Colors.red.withValues(alpha: 0.06)
            : null,
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

class _TaskSubtitle extends StatelessWidget {
  final TodoTask task;
  final List<TodoTag> tags;
  const _TaskSubtitle({required this.task, required this.tags});

  @override
  Widget build(BuildContext context) {
    final parts = <Widget>[];
    if (task.dueDate != null) {
      final due =
          DateTime.fromMillisecondsSinceEpoch(task.dueDate!).toLocal();
      final isOverdue = !task.done &&
          task.dueDate! < DateTime.now().millisecondsSinceEpoch;
      final isToday = DateFormat('yyyy-MM-dd').format(due) ==
          DateFormat('yyyy-MM-dd').format(DateTime.now());
      parts.add(Text(
        isToday ? '今天 ${DateFormat('HH:mm').format(due)}' : DateFormat('MM-dd').format(due),
        style: TextStyle(
          color: isOverdue ? Colors.red : Colors.grey,
          fontWeight: isOverdue ? FontWeight.w600 : null,
        ),
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