import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/todo_task.dart';

/// 本地通知服务：负责截止日期前的提醒调度与取消。
class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;

  /// 初始化通知插件并申请权限。
  Future<void> init() async {
    if (_initialized) return;

    tzdata.initializeTimeZones();
    tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings = InitializationSettings(android: android, iOS: ios);
    await _plugin.initialize(settings);

    // Android 13+ 需运行时申请通知权限
    await _plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();

    _initialized = true;
  }

  /// 为任务调度一条截止提醒（任务 id 作为通知 id，便于更新/取消）。
  ///
  /// 支持 `reminderMinutes`：截止前提前提醒；0 表示准时提醒。
  Future<void> scheduleTaskReminder(TodoTask task) async {
    if (!_initialized) await init();
    if (task.dueDate == null) return;

    // 提醒时间 = 截止时间 - 提前分钟数
    final due = DateTime.fromMillisecondsSinceEpoch(task.dueDate!);
    final remind = due.subtract(Duration(minutes: task.reminderMinutes));
    final now = DateTime.now();
    // 只对未来的提醒时间调度
    if (!remind.isAfter(now)) {
      await cancelReminder(task.id!);
      return;
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'task_reminders',
        '任务提醒',
        channelDescription: '任务截止日期前的提醒',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(),
    );

    await _plugin.zonedSchedule(
      task.id!,
      task.reminderMinutes > 0 ? '任务即将到期' : '任务提醒',
      task.reminderMinutes > 0
          ? '「${task.title}」将在 ${_fmtDue(due)} 到期'
          : '「${task.title}」已到截止日期',
      tz.TZDateTime.from(remind, tz.local),
      details,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
    );
  }

  String _fmtDue(DateTime due) {
    final now = DateTime.now();
    final hm = '${due.hour.toString().padLeft(2, '0')}:'
        '${due.minute.toString().padLeft(2, '0')}';
    if (due.year == now.year &&
        due.month == now.month &&
        due.day == now.day) {
      return '今天 ${hm}';
    }
    return '${due.month}月${due.day}日 ${hm}';
  }

  /// 取消某任务的提醒。
  Future<void> cancelReminder(int taskId) async {
    if (!_initialized) await init();
    await _plugin.cancel(taskId);
  }

  /// 取消所有提醒（清空时使用）。
  Future<void> cancelAll() async {
    if (!_initialized) await init();
    await _plugin.cancelAll();
  }
}

/// 供调用方触达通知实例
NotificationService get notifications => NotificationService.instance;