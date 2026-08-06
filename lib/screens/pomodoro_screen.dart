import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/pomodoro.dart';
import '../models/todo_task.dart';
import '../providers/app_state.dart';

/// 番茄钟页面：计时、开始/暂停/重置、模式切换、设置与历史记录。
class PomodoroScreen extends StatefulWidget {
  /// 可选：关联的任务（从任务详情页进入时传入）
  final TodoTask? task;

  const PomodoroScreen({super.key, this.task});

  @override
  State<PomodoroScreen> createState() => _PomodoroScreenState();
}

class _PomodoroScreenState extends State<PomodoroScreen> {
  Timer? _timer;
  PomodoroType _type = PomodoroType.focus;
  int _totalSeconds = 25 * 60;
  int _remainingSeconds = 25 * 60;
  bool _running = false;
  int _completedFocusCount = 0;
  int _sessionStart = 0; // 本次计时的开始时间戳
  int? _activeSessionId; // 当前进行中的会话记录 id

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final state = context.read<AppState>();
    final s = await state.getPomodoroSettings();
    if (!mounted) return;
    setState(() {
      _applySettings(s);
    });
  }

  void _applySettings(PomodoroSettings s) {
    _totalSeconds = _durationForType(_type, s);
    _remainingSeconds = _totalSeconds;
    _running = false;
    _timer?.cancel();
  }

  int _durationForType(PomodoroType type, PomodoroSettings s) {
    switch (type) {
      case PomodoroType.focus:
        return s.focusMinutes * 60;
      case PomodoroType.shortBreak:
        return s.shortBreakMinutes * 60;
      case PomodoroType.longBreak:
        return s.longBreakMinutes * 60;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _switchType(PomodoroType type) {
    if (_running) {
      // 切换时先记录/中断当前会话
      _recordSession(completed: false);
    }
    setState(() {
      _type = type;
      _totalSeconds = _durationForType(
          type, _currentSettings ?? const PomodoroSettings());
      _remainingSeconds = _totalSeconds;
      _running = false;
    });
    _timer?.cancel();
  }

  PomodoroSettings? _currentSettings;

  void _toggle() {
    if (_running) {
      _pause();
    } else {
      _start();
    }
  }

  void _start() {
    _timer?.cancel();
    _running = true;
    _sessionStart = DateTime.now().millisecondsSinceEpoch;
    // 专注开始时写入一条记录；休息不写记录
    if (_type == PomodoroType.focus) {
      _createSession();
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    setState(() {});
  }

  Future<void> _createSession() async {
    final state = context.read<AppState>();
    final id = await state.addPomodoroSession(PomodoroSession(
      taskId: widget.task?.id,
      type: _type,
      durationSeconds: _totalSeconds,
      startedAt: _sessionStart,
      completed: false,
    ));
    _activeSessionId = id;
  }

  void _pause() {
    _timer?.cancel();
    _running = false;
    // 暂停视为中断本次会话
    _recordSession(completed: false);
    setState(() {});
  }

  void _reset() {
    _timer?.cancel();
    _running = false;
    _recordSession(completed: false);
    setState(() {
      _remainingSeconds = _totalSeconds;
    });
  }

  void _tick() {
    if (_remainingSeconds <= 1) {
      _onComplete();
      return;
    }
    setState(() {
      _remainingSeconds -= 1;
    });
  }

  Future<void> _onComplete() async {
    _timer?.cancel();
    _running = false;
    _remainingSeconds = 0;
    _recordSession(completed: true);

    final state = context.read<AppState>();
    final settings = await state.getPomodoroSettings();

    if (_type == PomodoroType.focus) {
      _completedFocusCount += 1;
      // 根据间隔决定长休息还是短休息
      final needLong = _completedFocusCount % settings.longBreakInterval == 0;
      setState(() {
        _type = needLong ? PomodoroType.longBreak : PomodoroType.shortBreak;
        _totalSeconds = _durationForType(_type, settings);
        _remainingSeconds = _totalSeconds;
      });
    } else {
      // 休息结束回到专注
      setState(() {
        _type = PomodoroType.focus;
        _totalSeconds = _durationForType(_type, settings);
        _remainingSeconds = _totalSeconds;
      });
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_type == PomodoroType.focus ? '休息结束，开始专注吧' : '专注完成！')),
      );
    }
  }

  Future<void> _recordSession({required bool completed}) async {
    final id = _activeSessionId;
    if (id == null) return;
    _activeSessionId = null;
    final state = context.read<AppState>();
    final now = DateTime.now().millisecondsSinceEpoch;
    await state.updatePomodoroSession(PomodoroSession(
      id: id,
      taskId: widget.task?.id,
      type: _type,
      durationSeconds: _totalSeconds,
      startedAt: _sessionStart,
      finishedAt: now,
      completed: completed,
    ));
  }

  Future<void> _openSettings() async {
    final state = context.read<AppState>();
    final s = await state.getPomodoroSettings();
    _currentSettings = s;
    if (!mounted) return;
    final result = await showDialog<PomodoroSettings>(
      context: context,
      builder: (_) => _SettingsDialog(settings: s),
    );
    if (result != null) {
      await state.savePomodoroSettings(result);
      setState(() {
        _currentSettings = result;
        _applySettings(result);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final progress = _totalSeconds == 0
        ? 0.0
        : 1 - (_remainingSeconds / _totalSeconds);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.task != null
            ? '专注「${widget.task!.title}」'
            : '番茄钟'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // 模式切换
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SegmentedButton<PomodoroType>(
              segments: [
                for (final t in PomodoroType.values)
                  ButtonSegment(
                      value: t, label: Text(t.label)),
              ],
              selected: {_type},
              onSelectionChanged: (set) => _switchType(set.first),
            ),
          ),
          const Spacer(),
          // 圆形进度
          SizedBox(
            width: 240,
            height: 240,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: progress,
                  strokeWidth: 10,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _fmt(_remainingSeconds),
                      style: const TextStyle(
                          fontSize: 48, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(_type.label,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.grey)),
                    if (_completedFocusCount > 0) ...[
                      const SizedBox(height: 4),
                      Text('今日已完成 $_completedFocusCount 个番茄',
                          style: const TextStyle(
                              fontSize: 12, color: Colors.grey)),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          // 控制按钮
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                iconSize: 32,
                icon: const Icon(Icons.refresh),
                tooltip: '重置',
                onPressed: _reset,
              ),
              const SizedBox(width: 24),
              FilledButton.icon(
                onPressed: _toggle,
                icon: Icon(_running ? Icons.pause : Icons.play_arrow),
                label: Text(_running ? '暂停' : '开始'),
                style: FilledButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(width: 24),
              IconButton(
                iconSize: 32,
                icon: const Icon(Icons.event_repeat),
                tooltip: '跳过',
                onPressed: _remainingSeconds == _totalSeconds
                    ? null
                    : () => _onComplete(),
              ),
            ],
          ),
          const Spacer(),
          // 今日记录
          _HistorySection(taskId: widget.task?.id),
        ],
      ),
    );
  }

  String _fmt(int sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

/// 番茄钟历史记录列表
class _HistorySection extends StatefulWidget {
  final int? taskId;
  const _HistorySection({this.taskId});

  @override
  State<_HistorySection> createState() => _HistorySectionState();
}

class _HistorySectionState extends State<_HistorySection> {
  List<PomodoroSession> _sessions = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    final list = widget.taskId != null
        ? await state.pomodoroSessionsForTask(widget.taskId!)
        : await state.recentPomodoroSessions(limit: 20);
    if (!mounted) return;
    setState(() {
      _sessions = list.where((s) => s.type == PomodoroType.focus).toList();
      _loaded = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_sessions.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Text('暂无完成记录，开始第一个番茄吧',
            style: TextStyle(color: Colors.grey)),
      );
    }
    final focusCount = _sessions.where((s) => s.completed).length;
    final todayStart = DateTime(DateTime.now().year, DateTime.now().month,
            DateTime.now().day)
        .millisecondsSinceEpoch;
    final todayFocus = _sessions
        .where((s) => s.completed && s.startedAt >= todayStart)
        .length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Text('今日记录',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('今日 $todayFocus 个 · 累计 $focusCount 个',
                  style: const TextStyle(fontSize: 13, color: Colors.grey)),
            ],
          ),
        ),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _sessions.length,
            itemBuilder: (ctx, i) => _sessionTile(_sessions[i]),
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _sessionTile(PomodoroSession s) {
    final start = DateTime.fromMillisecondsSinceEpoch(s.startedAt);
    final minutes = (s.durationSeconds / 60).round();
    final status = s.completed ? '完成' : '中断';
    return ListTile(
      dense: true,
      leading: Icon(
        s.completed ? Icons.check_circle : Icons.cancel,
        color: s.completed ? Colors.green : Colors.grey,
      ),
      title: Text(DateFormat('MM-dd HH:mm').format(start)),
      subtitle: Text('$minutes 分钟 · $status'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline, size: 18),
        onPressed: () async {
          final state = context.read<AppState>();
          await state.deletePomodoroSession(s.id!);
          _load();
        },
      ),
    );
  }
}

/// 番茄钟设置对话框
class _SettingsDialog extends StatefulWidget {
  final PomodoroSettings settings;
  const _SettingsDialog({required this.settings});

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late final List<TextEditingController> _ctrls = [
    TextEditingController(text: '${widget.settings.focusMinutes}'),
    TextEditingController(text: '${widget.settings.shortBreakMinutes}'),
    TextEditingController(text: '${widget.settings.longBreakMinutes}'),
    TextEditingController(text: '${widget.settings.longBreakInterval}'),
  ];

  @override
  void dispose() {
    for (final c in _ctrls) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final labels = ['专注时长（分钟）', '短休息（分钟）', '长休息（分钟）', '长休息间隔（个番茄）'];
    return AlertDialog(
      title: const Text('番茄钟设置'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < _ctrls.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: TextField(
                controller: _ctrls[i],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: labels[i],
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消')),
        FilledButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }

  void _save() {
    final focus = int.tryParse(_ctrls[0].text) ?? 25;
    final short = int.tryParse(_ctrls[1].text) ?? 5;
    final long = int.tryParse(_ctrls[2].text) ?? 15;
    final interval = int.tryParse(_ctrls[3].text) ?? 4;
    Navigator.of(context).pop(PomodoroSettings(
      focusMinutes: focus < 1 ? 1 : focus,
      shortBreakMinutes: short < 1 ? 1 : short,
      longBreakMinutes: long < 1 ? 1 : long,
      longBreakInterval: interval < 1 ? 1 : interval,
    ));
  }
}