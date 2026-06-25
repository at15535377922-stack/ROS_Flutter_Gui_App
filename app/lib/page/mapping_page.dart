import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/ssh/ssh_remote.dart';
import 'package:ros_flutter_gui_app/page/ssh_widgets.dart';

/// 建图页面：通过 SSH 启动/停止 SLAM，并将地图保存到机器人
class MappingPage extends StatefulWidget {
  const MappingPage({super.key});

  @override
  State<MappingPage> createState() => _MappingPageState();
}

enum _MappingState { idle, mapping, saving }

class _MappingPageState extends State<MappingPage> {
  _MappingState _state = _MappingState.idle;
  String _log = '';
  String _savedMapName = '';

  // SSH 连接是否可用
  bool get _sshAvailable => globalSetting.sshCredentialsConfigured;

  void _appendLog(String msg) {
    setState(() {
      _log = '$_log\n$msg'.trimLeft();
    });
  }

  /// 确保 SSH 凭据已配置
  Future<bool> _ensureSsh() async {
    if (_sshAvailable) return true;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要 SSH 凭据'),
        content: const Text('建图功能需要 SSH 连接到机器人。请先配置 SSH 用户名和密码。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('去配置'),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return false;
    await ShowSshConfigSheet(context);
    return globalSetting.sshCredentialsConfigured;
  }

  /// 通过 SSH 执行命令
  Future<String> _runSsh(String command) async {
    Object? client;
    try {
      client = await sshConnect(
        username: globalSetting.SSHUsername.trim(),
        password: globalSetting.SSHPassword,
      );
      final out = await sshRunRemoteCommand(client, command);
      sshClientClose(client);
      return out;
    } catch (e) {
      if (client != null) sshClientClose(client);
      rethrow;
    }
  }

  /// 开始建图：通过 SSH 启动 SLAM Toolbox
  Future<void> _startMapping() async {
    if (!await _ensureSsh()) return;
    setState(() {
      _state = _MappingState.mapping;
      _log = '';
    });
    _appendLog('▶ 正在启动 SLAM 建图...');
    try {
      // 后台启动 slam_toolbox，nohup 使其在 SSH 断开后继续运行
      const cmd =
          'nohup ros2 launch slam_toolbox online_async_launch.py slam_params_file:=/opt/ros_config/slam_params.yaml '
          '> /tmp/slam_toolbox.log 2>&1 &';
      await _runSsh(cmd);
      _appendLog('✅ SLAM 建图已启动，您现在可以控制小车移动来建图。');
      _appendLog('   建图完成后，点击「保存地图」按钮。');
    } catch (e) {
      _appendLog('❌ 启动失败: $e');
      setState(() => _state = _MappingState.idle);
    }
  }

  /// 保存地图：通过 SSH 调用 map_saver，然后后端重新扫描地图
  Future<void> _saveMap(String mapName) async {
    if (!await _ensureSsh()) return;
    setState(() => _state = _MappingState.saving);
    _appendLog('💾 正在保存地图「$mapName」...');
    try {
      // 1. 获取后端地图存储路径
      final httpChannel = context.read<HttpChannel>();
      // 默认的地图根目录（后端配置中通常为 ~/maps 或 /opt/ros_maps）
      // 先查询后端设置获取 map_root
      String mapRoot = '/root/maps';
      try {
        final settings = await httpChannel.getGuiSettings();
        final mr = settings['map_root'] as String? ?? '';
        if (mr.isNotEmpty) mapRoot = mr;
      } catch (_) {}

      final mapDir = '$mapRoot/$mapName';

      // 2. 创建目录
      await _runSsh('mkdir -p $mapDir');
      _appendLog('   创建目录: $mapDir');

      // 3. 调用 map_saver 保存地图
      final saveCmd = 'ros2 run nav2_map_server map_saver_cli '
          '-f $mapDir/$mapName '
          '--ros-args -p save_map_timeout:=5.0 -p free_thresh_default:=0.25 -p occupied_thresh_default:=0.65';
      _appendLog('   正在保存地图文件...');
      final out = await _runSsh(saveCmd);
      _appendLog('   $out');

      // 4. 停止 slam_toolbox
      _appendLog('   正在停止 SLAM 进程...');
      await _runSsh("pkill -f 'slam_toolbox' || true");

      // 5. 通知后端重新加载地图列表（通过设置当前地图来触发）
      _appendLog('✅ 地图保存完成！');
      setState(() {
        _state = _MappingState.idle;
        _savedMapName = mapName;
      });

      if (mounted) {
        toastification.show(
          context: context,
          type: ToastificationType.success,
          title: Text('地图「$mapName」已保存到机器人'),
          autoCloseDuration: const Duration(seconds: 4),
        );
      }
    } catch (e) {
      _appendLog('❌ 保存失败: $e');
      setState(() => _state = _MappingState.idle);
      if (mounted) {
        toastification.show(
          context: context,
          type: ToastificationType.error,
          title: Text('保存失败: $e'),
          autoCloseDuration: const Duration(seconds: 4),
        );
      }
    }
  }

  /// 停止建图（不保存）
  Future<void> _stopMapping() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('停止建图'),
        content: const Text('确定要停止建图吗？未保存的地图将会丢失。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('停止'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    _appendLog('⏹ 正在停止 SLAM 进程...');
    try {
      await _runSsh("pkill -f 'slam_toolbox' || true");
      _appendLog('✅ 已停止。');
    } catch (e) {
      _appendLog('❌ 停止失败: $e');
    }
    setState(() => _state = _MappingState.idle);
  }

  /// 显示保存地图对话框
  Future<void> _showSaveDialog() async {
    final ctrl = TextEditingController(
      text: 'map_${DateTime.now().millisecondsSinceEpoch ~/ 1000}',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存地图'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '地图名称',
            border: OutlineInputBorder(),
            helperText: '只能包含字母、数字和下划线',
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final n = ctrl.text.trim();
              if (n.isEmpty) return;
              Navigator.pop(ctx, n);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    await _saveMap(name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isMapping = _state == _MappingState.mapping;
    final isSaving = _state == _MappingState.saving;
    final isBusy = isMapping || isSaving;

    return Scaffold(
      appBar: AppBar(
        title: const Text('建图'),
        backgroundColor: theme.colorScheme.primaryContainer,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 状态卡片
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _state == _MappingState.idle
                              ? Icons.stop_circle_outlined
                              : _state == _MappingState.mapping
                                  ? Icons.radio_button_on
                                  : Icons.save,
                          color: _state == _MappingState.idle
                              ? Colors.grey
                              : _state == _MappingState.mapping
                                  ? Colors.green
                                  : Colors.blue,
                          size: 28,
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _state == _MappingState.idle
                              ? '就绪'
                              : _state == _MappingState.mapping
                                  ? '建图中…'
                                  : '正在保存…',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (isBusy) ...[
                          const SizedBox(width: 12),
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ],
                      ],
                    ),
                    if (_savedMapName.isNotEmpty && _state == _MappingState.idle) ...[
                      const SizedBox(height: 8),
                      Text(
                        '上次保存: $_savedMapName',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.green[700],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),

            // 操作说明
            Card(
              color: theme.colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('使用说明', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 6),
                    const Text('1. 点击「开始建图」启动 SLAM 建图'),
                    const Text('2. 通过手柄/键盘控制小车移动以建图'),
                    const Text('3. 建图完成后点击「保存地图」'),
                    const Text('4. 输入地图名称，地图将保存到机器人'),
                    const Text('5. 保存后可在地图列表中选择该地图'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // 操作按钮
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: const Text('开始建图'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: _state == _MappingState.idle ? _startMapping : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    icon: const Icon(Icons.save),
                    label: const Text('保存地图'),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: isMapping ? _showSaveDialog : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.stop, color: Colors.red),
                    label: const Text('停止建图',
                        style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: isMapping ? _stopMapping : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 日志输出
            Expanded(
              child: Card(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '日志输出',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: Colors.grey[400],
                        ),
                      ),
                      const Divider(color: Colors.grey),
                      Expanded(
                        child: SingleChildScrollView(
                          child: SelectableText(
                            _log.isEmpty ? '（暂无日志）' : _log,
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontFamily: 'monospace',
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
