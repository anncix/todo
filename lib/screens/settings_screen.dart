import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/webdav_sync.dart';

/// 设置页：WebDAV 配置、主题、数据备份、同步操作。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _urlCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppState>().config;
    _urlCtrl.text = cfg.url;
    _userCtrl.text = cfg.username;
    _passCtrl.text = cfg.password;
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    await state.saveConfig(WebDavConfig(
      url: _urlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text.trim(),
    ));
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('配置已保存')));
    }
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    final state = context.read<AppState>();
    final ok = await state.testConfig(WebDavConfig(
      url: _urlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text.trim(),
    ));
    setState(() => _testing = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(ok ? '连接成功：服务器可访问' : '连接失败：请检查地址与账号'),
      backgroundColor: ok ? Colors.green : Colors.red,
    ));
  }

  Future<void> _sync(WebDavConfig config) async {
    final state = context.read<AppState>();
    await state.saveConfig(config);
    await state.sync();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(state.syncStatus == 'synced'
          ? '同步完成'
          : (state.syncError ?? '同步未知')),
    ));
  }

  Future<void> _exportBackup() async {
    final state = context.read<AppState>();
    final path = await state.exportBackup();
    if (!mounted) return;
    final name = p.basename(path);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已导出备份：$name')),
    );
  }

  Future<void> _importBackup() async {
    final state = context.read<AppState>();
    final dir = await getApplicationDocumentsDirectory();
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));

    if (files.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('文档目录中没有可导入的备份文件')),
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('选择要导入的备份'),
        children: [
          for (final f in files)
            ListTile(
              title: Text(p.basename(f.path)),
              onTap: () => Navigator.of(ctx).pop(f.path),
            ),
        ],
      ),
    );
    if (selected == null) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('导入备份'),
        content: const Text('导入将覆盖当前所有数据，确定继续吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('导入')),
        ],
      ),
    );
    if (ok != true) return;

    final success = await state.importBackup(selected);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(success ? '导入成功' : '导入失败：备份文件格式不正确'),
      backgroundColor: success ? Colors.green : Colors.red,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final config = WebDavConfig(
      url: _urlCtrl.text.trim(),
      username: _userCtrl.text.trim(),
      password: _passCtrl.text.trim(),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('WebDAV 服务器',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: '服务器地址（含协议）',
              hintText: 'https://dav.example.com/dav',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _userCtrl,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _testing ? null : _save,
                  icon: const Icon(Icons.save_outlined),
                  label: const Text('保存配置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _test,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering),
                  label: const Text('测试连接'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          _cardListTile(
            icon: Icons.sync,
            title: '立即同步',
            subtitle: _statusText(state),
            trailing: state.syncStatus == 'syncing'
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
            onTap: config.isConfigured ? () => _sync(config) : null,
          ),
          const SizedBox(height: 12),
          const Text(
            '同步说明：应用会把所有清单、任务、标签打包为一个 JSON 文件上传到服务器。'
            '每次同步会拉取远端数据并按修改时间合并，多端编辑不会互相覆盖。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text('外观',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(
                  value: ThemeMode.light,
                  label: Text('浅色'),
                  icon: Icon(Icons.light_mode)),
              ButtonSegment(
                  value: ThemeMode.system,
                  label: Text('跟随系统'),
                  icon: Icon(Icons.brightness_auto)),
              ButtonSegment(
                  value: ThemeMode.dark,
                  label: Text('深色'),
                  icon: Icon(Icons.dark_mode)),
            ],
            selected: {state.themeMode},
            onSelectionChanged: (s) => state.setThemeMode(s.first),
          ),
          const SizedBox(height: 24),
          const Divider(),
          const SizedBox(height: 8),
          const Text('数据',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
          const SizedBox(height: 8),
          _cardListTile(
            icon: Icons.upload_file,
            title: '导出备份',
            subtitle: '将当前全部数据保存为本地 JSON 文件',
            onTap: _exportBackup,
          ),
          const SizedBox(height: 12),
          _cardListTile(
            icon: Icons.download,
            title: '导入备份',
            subtitle: '从本地 JSON 文件恢复数据（会覆盖当前数据）',
            onTap: _importBackup,
          ),
        ],
      ),
    );
  }

  Widget _cardListTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback? onTap,
    Widget? trailing,
  }) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: trailing ?? const Icon(Icons.chevron_right),
      onTap: onTap,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: Theme.of(context).dividerColor),
      ),
    );
  }

  String _statusText(AppState state) {
    switch (state.syncStatus) {
      case 'syncing':
        return '正在同步…';
      case 'synced':
        return '上次同步成功';
      case 'error':
        return state.syncError ?? '同步出错';
      default:
        return '尚未同步';
    }
  }
}