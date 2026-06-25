import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/basic/pointcloud2.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';
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
    context.read<WsChannel>().mapManager.clearAll();
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
      try {
        await httpChannel.setCurrentMap(mapName);
      } catch (e) {
        _appendLog('   地图已保存，但设置为当前地图失败: $e');
      }
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
              if (!RegExp(r'^[A-Za-z0-9_]+$').hasMatch(n)) return;
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

    return Scaffold(
      appBar: AppBar(
        title: const Text('建图'),
        backgroundColor: theme.colorScheme.primaryContainer,
        actions: [
          TextButton.icon(
            onPressed: isMapping ? _showSaveDialog : null,
            icon: const Icon(Icons.save),
            label: const Text('保存地图'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
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
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _state == _MappingState.idle
                            ? '就绪：点击开始建图后，下面的地图会实时显示小车、雷达和建图结果。'
                            : _state == _MappingState.mapping
                                ? '建图中：请继续遥控小车移动，观察地图覆盖范围。'
                                : '正在保存地图，请稍候。',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    if (_savedMapName.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      Chip(
                        label: Text('上次保存: $_savedMapName'),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: _MappingPreview(isMapping: isMapping),
                    ),
                    Positioned(
                      left: 12,
                      top: 12,
                      child: _buildFloatingHint(theme, isMapping),
                    ),
                    Positioned(
                      right: 12,
                      top: 12,
                      child: _buildLiveDataPanel(theme),
                    ),
                  ],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
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
                    label: const Text('停止建图', style: TextStyle(color: Colors.red)),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Colors.red),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                    onPressed: isMapping ? _stopMapping : null,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SizedBox(
              height: 180,
              child: Card(
                color: Colors.black87,
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('日志输出', style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey[400])),
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
          ),
        ],
      ),
    );
  }

  Widget _buildFloatingHint(ThemeData theme, bool isMapping) {
    return Card(
      elevation: 2,
      color: Colors.black.withOpacity(0.55),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Text(
          isMapping
              ? '建图中 · 仅显示本次 SLAM /map，不加载旧地图'
              : '未开始建图 · 不显示旧地图，开始后生成新地图',
          style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildLiveDataPanel(ThemeData theme) {
    final ws = context.read<WsChannel>();
    return Card(
      elevation: 2,
      color: Colors.black.withOpacity(0.55),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              ws.rosConnectState_ == Status.connected ? '后端已连接' : '后端未连接',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
            ),
            ValueListenableBuilder(
              valueListenable: ws.map_,
              builder: (_, map, __) => Text(
                '地图: ${map.data.isEmpty ? 0 : map.mapConfig.width}×${map.data.isEmpty ? 0 : map.mapConfig.height}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: ws.robotPoseMap,
              builder: (_, pose, __) => Text(
                '小车: ${pose.x.toStringAsFixed(2)}, ${pose.y.toStringAsFixed(2)}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: ws.laserPointData,
              builder: (_, laser, __) => Text(
                '雷达点: ${laser.laserPoseBaseLink.length}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
            ValueListenableBuilder(
              valueListenable: ws.pointCloud2Data,
              builder: (_, points, __) => Text(
                '点云点: ${points.length}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MappingPreview extends StatelessWidget {
  const _MappingPreview({required this.isMapping});

  final bool isMapping;

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<WsChannel>();
    return AnimatedBuilder(
      animation: Listenable.merge([
        ws.map_,
        ws.robotPoseMap,
        ws.laserPointData,
        ws.pointCloud2Data,
      ]),
      builder: (context, _) {
        final map = isMapping ? ws.map_.value : OccupancyMap();
        final laser = isMapping ? ws.laserPointData.value : null;
        final pointCloud = isMapping ? ws.pointCloud2Data.value : const <Point3D>[];
        final robotPose = isMapping ? ws.robotPoseMap.value : RobotPose(0, 0, 0);
        return Container(
          color: const Color(0xFF111827),
          child: CustomPaint(
            painter: _MappingPreviewPainter(
              map: map,
              robotPose: robotPose,
              laserPointsBase: laser?.laserPoseBaseLink ?? const <vm.Vector2>[],
              pointCloud: pointCloud,
              isMapping: isMapping,
            ),
            child: Center(
              child: (!isMapping || map.data.isEmpty)
                  ? _buildEmptyState(context, isMapping)
                  : const SizedBox.shrink(),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmptyState(BuildContext context, bool isMapping) {
    final theme = Theme.of(context);
    return Card(
      color: Colors.black.withOpacity(0.5),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isMapping ? Icons.radar : Icons.add_location_alt_outlined,
              color: Colors.white70,
              size: 36,
            ),
            const SizedBox(height: 8),
            Text(
              isMapping ? '等待 SLAM 发布新的 /map...' : '这里不会显示之前保存的地图',
              style: theme.textTheme.bodyMedium?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 4),
            Text(
              isMapping ? '移动小车后会逐步出现新地图' : '点击开始建图后生成新的 .pgm 和 .yaml',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _MappingPreviewPainter extends CustomPainter {
  _MappingPreviewPainter({
    required this.map,
    required this.robotPose,
    required this.laserPointsBase,
    required this.pointCloud,
    required this.isMapping,
  });

  final OccupancyMap map;
  final RobotPose robotPose;
  final List<vm.Vector2> laserPointsBase;
  final List<Point3D> pointCloud;
  final bool isMapping;

  @override
  void paint(Canvas canvas, Size size) {
    _drawGrid(canvas, size);
    if (!isMapping) return;

    final bounds = _computeBounds();
    if (bounds == null) return;

    final transform = _WorldTransform(bounds, size);
    if (map.data.isNotEmpty) _drawMap(canvas, transform);
    _drawPointCloud(canvas, transform);
    _drawLaser(canvas, transform);
    _drawRobot(canvas, transform);
  }

  void _drawGrid(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.06)
      ..strokeWidth = 1;
    const step = 40.0;
    for (double x = 0; x <= size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y <= size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  _WorldBounds? _computeBounds() {
    double minX = robotPose.x - 2;
    double maxX = robotPose.x + 2;
    double minY = robotPose.y - 2;
    double maxY = robotPose.y + 2;

    if (map.data.isNotEmpty) {
      minX = math.min(minX, map.mapConfig.originX);
      minY = math.min(minY, map.mapConfig.originY);
      maxX = math.max(maxX, map.mapConfig.originX + map.mapConfig.width * map.mapConfig.resolution);
      maxY = math.max(maxY, map.mapConfig.originY + map.mapConfig.height * map.mapConfig.resolution);
    }

    for (final p in pointCloud) {
      if (!p.x.isFinite || !p.y.isFinite) continue;
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }

    for (final lp in laserPointsBase) {
      final p = absoluteSum(robotPose, RobotPose(lp.x, lp.y, 0));
      minX = math.min(minX, p.x);
      maxX = math.max(maxX, p.x);
      minY = math.min(minY, p.y);
      maxY = math.max(maxY, p.y);
    }

    if (!minX.isFinite || !maxX.isFinite || !minY.isFinite || !maxY.isFinite) return null;
    return _WorldBounds(minX, maxX, minY, maxY);
  }

  void _drawMap(Canvas canvas, _WorldTransform transform) {
    final resolution = map.mapConfig.resolution;
    if (resolution <= 0) return;
    final cellSize = math.max(1.0, transform.scale * resolution);
    final paint = Paint();
    final height = math.min(map.mapConfig.height, map.data.length);
    for (var row = 0; row < height; row++) {
      final width = math.min(map.mapConfig.width, map.data[row].length);
      for (var col = 0; col < width; col++) {
        final value = map.data[row][col];
        if (value < 0) continue;
        paint.color = value >= 65 ? Colors.black87 : Colors.white.withOpacity(0.88);
        final worldX = map.mapConfig.originX + col * resolution;
        final worldY = map.mapConfig.originY + (height - row - 1) * resolution;
        final p = transform.toCanvas(worldX, worldY);
        canvas.drawRect(Rect.fromLTWH(p.dx, p.dy, cellSize, cellSize), paint);
      }
    }
  }

  void _drawPointCloud(Canvas canvas, _WorldTransform transform) {
    if (pointCloud.isEmpty) return;
    final paint = Paint()..color = Colors.orangeAccent.withOpacity(0.8);
    for (final p in pointCloud) {
      if (!p.x.isFinite || !p.y.isFinite) continue;
      canvas.drawCircle(transform.toCanvas(p.x, p.y), 1.5, paint);
    }
  }

  void _drawLaser(Canvas canvas, _WorldTransform transform) {
    if (laserPointsBase.isEmpty) return;
    final paint = Paint()..color = Colors.redAccent.withOpacity(0.85);
    for (final lp in laserPointsBase) {
      final p = absoluteSum(robotPose, RobotPose(lp.x, lp.y, 0));
      canvas.drawCircle(transform.toCanvas(p.x, p.y), 2, paint);
    }
  }

  void _drawRobot(Canvas canvas, _WorldTransform transform) {
    final center = transform.toCanvas(robotPose.x, robotPose.y);
    final bodyPaint = Paint()..color = const Color(0xFF38BDF8);
    final headingPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, 9, bodyPaint);
    final heading = Offset(
      center.dx + math.cos(robotPose.theta) * 18,
      center.dy - math.sin(robotPose.theta) * 18,
    );
    canvas.drawLine(center, heading, headingPaint);
  }

  @override
  bool shouldRepaint(covariant _MappingPreviewPainter oldDelegate) {
    return oldDelegate.map != map ||
        oldDelegate.robotPose != robotPose ||
        oldDelegate.laserPointsBase != laserPointsBase ||
        oldDelegate.pointCloud != pointCloud ||
        oldDelegate.isMapping != isMapping;
  }
}

class _WorldBounds {
  const _WorldBounds(this.minX, this.maxX, this.minY, this.maxY);

  final double minX;
  final double maxX;
  final double minY;
  final double maxY;
}

class _WorldTransform {
  _WorldTransform(_WorldBounds bounds, Size size)
      : _minX = bounds.minX,
        _minY = bounds.minY,
        _size = size,
        scale = _computeScale(bounds, size);

  final double _minX;
  final double _minY;
  final Size _size;
  final double scale;

  static double _computeScale(_WorldBounds bounds, Size size) {
    final worldWidth = math.max(1.0, bounds.maxX - bounds.minX);
    final worldHeight = math.max(1.0, bounds.maxY - bounds.minY);
    return math.min(size.width / worldWidth, size.height / worldHeight) * 0.86;
  }

  Offset toCanvas(double worldX, double worldY) {
    final worldWidthPx = (worldX - _minX) * scale;
    final worldHeightPx = (worldY - _minY) * scale;
    return Offset(
      (_size.width - (_size.width * 0.86)) / 2 + worldWidthPx,
      _size.height - ((_size.height - (_size.height * 0.86)) / 2 + worldHeightPx),
    );
  }
}
