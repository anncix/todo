# 清单 TODO（Flutter）

一个功能完整的清单 / 待办应用，支持 **本地存储**、**WebDAV 云同步**、**本地通知提醒**、**重复任务**、**标签**、**子任务**、**拖拽排序**、**全文搜索**、**今日/智能视图**、**番茄钟专注**、**深色模式**与**数据备份**。

> 当前版本：**v0.0.1** · 平台：Android / iOS / macOS / Windows / Linux

## 功能

- 多清单管理：新建 / 重命名 / 删除，每个清单独立颜色
- 任务管理：新增 / 编辑 / 删除 / 勾选，支持备注、截止日期、优先级
- 收件箱：未分配清单的任务统一收纳
- 今日视图：逾期 / 今天到期 / 今日完成一目了然
- 智能视图：高优先级、未来 7 天到期与本周汇总
- 番茄钟：专注 / 短休息 / 长休息计时，可关联任务，记录完成历史
- 拖拽排序：长按并拖动任务调整顺序
- 全文搜索：按标题 / 备注即时筛选
- 标签系统：给任务打多个标签，按标签筛选
- 子任务：大任务拆分小项，随时勾选
- 重复任务：每天 / 每周 / 每月 / 每年，勾选完成后自动推进到期日
- 本地通知：任务截止前可提前提醒（提前 5 分钟~1 天可选，应用关闭也能响应）
- 深色模式：浅色 / 深色 / 跟随系统
- 数据备份：一键导出 / 导入本地 JSON 文件
- **本地存储**：SQLite（sqflite）持久化，离线可用
- **WebDAV 同步**：全量数据打包为 JSON 上传到任意 WebDAV 服务器（坚果云、Nextcloud 等），多端按修改时间合并，且数据变更后自动同步

## 技术栈

| 模块 | 方案 |
|---|---|
| 状态管理 | provider（ChangeNotifier） |
| 本地数据库 | sqflite |
| WebDAV | webdav_client |
| 本地通知 | flutter_local_notifications + timezone |
| 配置存储 | shared_preferences |

## 运行

```bash
cd flutter_todo

# 生成平台目录（android / ios / macos / windows / linux）
flutter create .

flutter pub get
flutter run
```

> 项目已包含 `lib/` 源码与 `pubspec.yaml`。首次运行前执行 `flutter create .` 生成各平台骨架，它不会覆盖 `lib/` 与 `pubspec.yaml`。

平台：Android / iOS / macOS / Windows / Linux。

### Android 通知权限

`flutter create .` 生成平台目录后，在 `android/app/src/main/AndroidManifest.xml` 的 `<manifest>` 内添加：

```xml
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
```

并在 `flutter_local_notifications` 中注册 BootReceiver（Android 重启后恢复提醒）：

```xml
<receiver android:name="com.dexterous.flutterlocalnotifications.ScheduledNotificationBootReceiver"
    android:exported="false">
    <intent-filter>
        <action android:name="android.intent.action.BOOT_COMPLETED"/>
        <action android:name="android.intent.action.MY_PACKAGE_REPLACED"/>
        <action android:name="android.intent.action.QUICKBOOT_POWERON"/>
    </intent-filter>
</receiver>
```

### 明文 HTTP 说明

若使用 `http://` 而非 `https://`，Android 默认禁止明文流量。在 `<application>` 标签内添加：

```xml
android:usesCleartextTraffic="true"
```

## 配置 WebDAV 同步

1. 打开应用右上角「设置」
2. 填写服务器地址（含协议，如 `https://dav.jianguoyun.com/dav/`）、用户名、密码
3. 「测试连接」确认可访问
4. 「保存配置」后，任何数据变更会自动上传；也可点「立即同步」手动拉取合并

同步文件名为 `flutter_todo_sync.json`，位于服务器根目录。

## 目录结构

```
lib/
├── main.dart                    # 入口（含主题）
├── models/
│   ├── todo_list.dart           # 清单模型
│   ├── todo_task.dart           # 任务模型（含子任务/重复/提前提醒）
│   ├── todo_tag.dart            # 标签模型
│   └── pomodoro.dart            # 番茄钟模型（会话/设置/计时状态）
├── database/
│   └── db_helper.dart           # SQLite（含 v3 迁移 + 标签/番茄钟表）
├── services/
│   ├── webdav_sync.dart         # WebDAV 同步 + 合并
│   ├── notification_service.dart# 本地通知（支持提前提醒）
│   └── backup_service.dart      # 数据备份
├── providers/
│   └── app_state.dart           # 全局状态（含视图筛选与番茄钟数据）
├── widgets/
│   └── task_tile.dart           # 可复用任务行组件
└── screens/
    ├── home_screen.dart         # 主界面（清单/标签/搜索/拖拽/视图入口）
    ├── task_screen.dart         # 任务编辑（提醒/标签/子任务/重复/番茄钟）
    ├── today_view.dart          # 今日视图
    ├── smart_view.dart          # 智能视图
    ├── pomodoro_screen.dart     # 番茄钟
    └── settings_screen.dart     # WebDAV/主题/备份
```

## 同步与备份机制

- 同步：拉取远端 JSON → 与本地按 `updatedAt` 取较新者合并（清单/任务/标签/关联）→ 写回本地 → 上传
- 自动同步：数据变更后 2 秒防抖自动上传；启动时自动同步一次
- 删除采用「逻辑删除」（`deleted_at`），保证跨端删除正确同步
- 备份：导出为 `flutter_todo_backup_时间戳.json`，导入为整体覆盖恢复

## 更新日志

### v0.0.1
- 首个版本：完成清单、任务、标签、子任务、重复任务、全文搜索、今日/智能视图、番茄钟、本地通知提醒、WebDAV 同步与数据备份
- 支持浅色 / 深色 / 跟随系统主题