import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/display/tile_map.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/action_status.dart';

/// 地图导航页面：选择某地图后进行重定位 + 选点导航
class MapNavPage extends StatefulWidget {
  final String mapName;

  const MapNavPage({super.key, required this.mapName});

  @override
  State<MapNavPage> createState() => _MapNavPageState();
}

class _MapNavPageState extends State<MapNavPage> {
  final GlobalKey<TileMapState> _tileMapKey = GlobalKey<TileMapState>();

  // 地图选点导航
  double? _pickedX;
  double? _pickedY;
  double _pickedTheta = 0.0;
  bool _isNavPickMode = false;
  final List<Map<String, double>> _navTrajectory = [];

  // 导航点
  NavPoint? _selectedNavPoint;

  late GlobalState _globalState;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _globalState = context.read<GlobalState>();
      // 确保不在建图模式
      if (_globalState.mode.value == Mode.mapEdit) {
        _globalState.mode.value = Mode.normal;
      }
    });
  }

  @override
  void dispose() {
    // 退出时如果还在重定位模式，恢复正常
    if (mounted) {
      final gs = context.read<GlobalState>();
      if (gs.mode.value == Mode.reloc) {
        gs.mode.value = Mode.normal;
      }
    }
    super.dispose();
  }

  Widget _toolbarShell(ThemeData theme, {required Widget child, Color? bg}) {
    return Material(
      elevation: 0,
      borderRadius: BorderRadius.circular(14),
      color: bg ?? theme.colorScheme.surfaceContainerHigh.withOpacity(0.55),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  // ── 重定位工具栏 ─────────────────────────────────────────────────
  Widget _buildRelocToolbar(ThemeData theme) {
    final tbStyle = IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.all(10),
    );

    return Positioned(
      left: 10,
      top: 60,
      child: ValueListenableBuilder<Mode>(
        valueListenable: context.read<GlobalState>().mode,
        builder: (ctx, mode, _) {
          final isReloc = mode == Mode.reloc;
          return _toolbarShell(
            theme,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  style: tbStyle,
                  tooltip: isReloc ? '取消重定位' : '点击进行重定位',
                  icon: Icon(
                    const IconData(0xe60f, fontFamily: "Reloc"),
                    color: isReloc ? Colors.green : theme.iconTheme.color,
                  ),
                  onPressed: () {
                    final gs = context.read<GlobalState>();
                    gs.mode.value = isReloc ? Mode.normal : Mode.reloc;
                  },
                ),
                if (isReloc) ...[
                  IconButton(
                    style: tbStyle,
                    tooltip: '确认重定位位置',
                    icon: const Icon(Icons.check, color: Colors.green),
                    onPressed: () {
                      context.read<GlobalState>().mode.value = Mode.normal;
                      context.read<WsChannel>().sendRelocPose(
                        _tileMapKey.currentState?.getRelocRobotPose() ??
                            RobotPose.zero(),
                      );
                      toastification.show(
                        context: context,
                        type: ToastificationType.success,
                        title: const Text('已发送重定位初始位姿'),
                        autoCloseDuration: const Duration(seconds: 3),
                      );
                    },
                  ),
                  IconButton(
                    style: tbStyle,
                    tooltip: '取消重定位',
                    icon: const Icon(Icons.close, color: Colors.red),
                    onPressed: () {
                      context.read<GlobalState>().mode.value = Mode.normal;
                    },
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 右侧工具栏 ───────────────────────────────────────────────────
  Widget _buildRightToolbar(ThemeData theme) {
    final tbStyle = IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.all(10),
    );

    return Positioned(
      right: 10,
      top: 60,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // 选点导航按钮
          _toolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(
                Icons.route,
                color: _isNavPickMode ? Colors.orange : theme.iconTheme.color,
              ),
              tooltip: _isNavPickMode ? '退出选点导航' : '选点导航',
              onPressed: () {
                setState(() {
                  _isNavPickMode = !_isNavPickMode;
                  if (!_isNavPickMode) {
                    _pickedX = null;
                    _pickedY = null;
                    _navTrajectory.clear();
                  }
                });
              },
            ),
          ),
          const SizedBox(height: 6),
          // 放大
          _toolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: const Icon(Icons.zoom_in_rounded),
              tooltip: '放大',
              onPressed: () => _tileMapKey.currentState?.zoomIn(),
            ),
          ),
          const SizedBox(height: 6),
          // 缩小
          _toolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: const Icon(Icons.zoom_out_rounded),
              tooltip: '缩小',
              onPressed: () => _tileMapKey.currentState?.zoomOut(),
            ),
          ),
          const SizedBox(height: 6),
          // 跟随机器人
          ValueListenableBuilder<Mode>(
            valueListenable: context.read<GlobalState>().mode,
            builder: (ctx, mode, _) => _toolbarShell(
              theme,
              child: IconButton(
                style: tbStyle,
                icon: Icon(
                  Icons.location_searching_rounded,
                  color: mode == Mode.robotFixedCenter
                      ? Colors.green
                      : theme.iconTheme.color,
                ),
                tooltip: '跟随机器人',
                onPressed: () {
                  final gs = context.read<GlobalState>();
                  gs.mode.value = gs.mode.value == Mode.robotFixedCenter
                      ? Mode.normal
                      : Mode.robotFixedCenter;
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── 停止导航按钮 ─────────────────────────────────────────────────
  Widget _buildStopNavButton(ThemeData theme) {
    return Positioned(
      left: 10,
      bottom: 10,
      child: Consumer<WsChannel>(
        builder: (ctx, ws, _) => ValueListenableBuilder<ActionStatus>(
          valueListenable: ws.navStatus_,
          builder: (ctx, status, _) {
            final active = status == ActionStatus.executing ||
                status == ActionStatus.accepted;
            if (!active) return const SizedBox.shrink();
            return Material(
              elevation: 0,
              borderRadius: BorderRadius.circular(14),
              color: Colors.blue,
              child: IconButton(
                icon: const Icon(Icons.stop_circle_rounded,
                    size: 30, color: Colors.white),
                onPressed: () {
                  context.read<WsChannel>().sendCancelNav();
                  toastification.show(
                    context: context,
                    title: const Text('已发送停止导航指令'),
                    autoCloseDuration: const Duration(seconds: 3),
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  // ── 选点导航浮层 ─────────────────────────────────────────────────
  Widget _buildNavPickPanel(ThemeData theme) {
    final hasPoint = _pickedX != null && _pickedY != null;
    final thetaDeg = _pickedTheta * 180.0 / math.pi;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      const Icon(Icons.route,
                          color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '地图选点导航',
                          style: TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      Text(
                        hasPoint ? '点击地图可重新选点' : '请在地图上点击选择目标点',
                        style: TextStyle(
                            color: Colors.grey[600], fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                        onPressed: () {
                          setState(() {
                            _isNavPickMode = false;
                            _pickedX = null;
                            _pickedY = null;
                            _navTrajectory.clear();
                          });
                        },
                      ),
                    ],
                  ),
                  if (hasPoint) ...[
                    const Divider(height: 12),
                    Row(
                      children: [
                        _coordChip(
                            'X', _pickedX!.toStringAsFixed(3), Colors.blue),
                        const SizedBox(width: 8),
                        _coordChip(
                            'Y', _pickedY!.toStringAsFixed(3), Colors.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '朝向: ${thetaDeg.toStringAsFixed(0)}°',
                                style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                              Slider(
                                value: _pickedTheta,
                                min: -math.pi,
                                max: math.pi,
                                divisions: 72,
                                onChanged: (v) =>
                                    setState(() => _pickedTheta = v),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add_location_alt, size: 16),
                            label: Text('加入轨迹 (${_navTrajectory.length})'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.purple,
                              side: const BorderSide(color: Colors.purple),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () {
                              setState(() {
                                _navTrajectory.add({
                                  'x': _pickedX!,
                                  'y': _pickedY!,
                                  'theta': _pickedTheta,
                                });
                              });
                              toastification.show(
                                context: context,
                                type: ToastificationType.info,
                                title: Text(
                                    '已加入轨迹，共 ${_navTrajectory.length} 个点'),
                                autoCloseDuration:
                                    const Duration(seconds: 2),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.navigation, size: 16),
                            label: const Text('立即导航'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.blue,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: _sendPickedNavGoal,
                          ),
                        ),
                      ],
                    ),
                    if (_navTrajectory.isNotEmpty) ...[
                      const Divider(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.linear_scale,
                              size: 16, color: Colors.purple),
                          const SizedBox(width: 6),
                          Text(
                            '轨迹路径 (${_navTrajectory.length} 个点)',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: Colors.purple),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            icon: const Icon(Icons.delete_sweep, size: 14),
                            label: const Text('清空',
                                style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.red,
                                padding: EdgeInsets.zero),
                            onPressed: () =>
                                setState(() => _navTrajectory.clear()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _navTrajectory.length,
                          separatorBuilder: (_, __) => const Icon(
                              Icons.arrow_forward,
                              size: 14,
                              color: Colors.grey),
                          itemBuilder: (_, i) {
                            final p = _navTrajectory[i];
                            return Chip(
                              label: Text(
                                'P${i + 1}(${p['x']!.toStringAsFixed(1)},${p['y']!.toStringAsFixed(1)})',
                                style: const TextStyle(fontSize: 11),
                              ),
                              backgroundColor: Colors.purple[50],
                              deleteIcon: const Icon(Icons.close, size: 12),
                              onDeleted: () =>
                                  setState(() => _navTrajectory.removeAt(i)),
                              padding: EdgeInsets.zero,
                              materialTapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: Text(
                              '按顺序执行 ${_navTrajectory.length} 个导航点'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.purple,
                            padding:
                                const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: _executeTrajectory,
                        ),
                      ),
                    ],
                  ] else ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.touch_app,
                            color: Colors.grey[400], size: 28),
                        const SizedBox(width: 8),
                        Text(
                          '点击上方地图任意位置选择目标点',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 13),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _coordChip(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: TextStyle(
                  fontSize: 10,
                  color: color,
                  fontWeight: FontWeight.bold)),
          Text(value,
              style: TextStyle(
                  fontSize: 13,
                  color: color,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _sendPickedNavGoal() async {
    if (_pickedX == null || _pickedY == null) return;
    try {
      final ok = await context.read<HttpChannel>().navigateToWaypoint(
            name: 'map_pick',
            x: _pickedX!,
            y: _pickedY!,
            theta: _pickedTheta,
          );
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ok ? ToastificationType.info : ToastificationType.error,
        title: Text(ok
            ? '导航指令已发送 (${_pickedX!.toStringAsFixed(2)}, ${_pickedY!.toStringAsFixed(2)})'
            : '导航失败，请检查 Nav2 是否运行'),
        autoCloseDuration: const Duration(seconds: 3),
      );
    } catch (e) {
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('导航请求失败: $e'),
        autoCloseDuration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _executeTrajectory() async {
    if (_navTrajectory.isEmpty) return;
    final http = context.read<HttpChannel>();
    toastification.show(
      context: context,
      type: ToastificationType.info,
      title: Text('开始执行 ${_navTrajectory.length} 点轨迹导航'),
      autoCloseDuration: const Duration(seconds: 3),
    );
    for (int i = 0; i < _navTrajectory.length; i++) {
      final p = _navTrajectory[i];
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.info,
        title: Text('导航至第 ${i + 1}/${_navTrajectory.length} 点'),
        autoCloseDuration: const Duration(seconds: 2),
      );
      try {
        await http.navigateToWaypoint(
          name: 'traj_${i + 1}',
          x: p['x']!,
          y: p['y']!,
          theta: p['theta']!,
        );
        // 等待到达
        for (int w = 0; w < 60; w++) {
          await Future.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final status = await http.getNavStatus();
          if (status == 'succeeded' || status == 'idle') break;
          if (status == 'failed') {
            if (!mounted) return;
            toastification.show(
              context: context,
              type: ToastificationType.error,
              title: Text('第 ${i + 1} 个点导航失败，终止轨迹'),
              autoCloseDuration: const Duration(seconds: 3),
            );
            return;
          }
        }
      } catch (e) {
        if (!mounted) return;
        toastification.show(
          context: context,
          type: ToastificationType.error,
          title: Text('第 ${i + 1} 个点执行失败: $e'),
          autoCloseDuration: const Duration(seconds: 3),
        );
        return;
      }
    }
    if (!mounted) return;
    toastification.show(
      context: context,
      type: ToastificationType.success,
      title: Text('轨迹执行完成，共 ${_navTrajectory.length} 个点'),
      autoCloseDuration: const Duration(seconds: 3),
    );
  }

  // ── 导航点弹窗 ───────────────────────────────────────────────────
  void _showNavPointDialog(NavPoint point) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(Icons.location_on, color: Colors.blue[700], size: 24),
            const SizedBox(width: 10),
            const Text('导航点'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(point.name,
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(
                'X: ${point.x.toStringAsFixed(3)}  Y: ${point.y.toStringAsFixed(3)}  θ: ${(point.theta * 180 / math.pi).toStringAsFixed(1)}°'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.navigation, size: 18),
            label: const Text('导航至此'),
            style: FilledButton.styleFrom(backgroundColor: Colors.blue[600]),
            onPressed: () {
              context.read<WsChannel>().sendNavigationGoal(
                    RobotPose(point.x, point.y, point.theta),
                  );
              toastification.show(
                context: context,
                title: Text('导航指令已发送: ${point.name}'),
                autoCloseDuration: const Duration(seconds: 3),
              );
              Navigator.of(ctx).pop();
              setState(() => _selectedNavPoint = null);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return WillPopScope(
      onWillPop: () async {
        final gs = context.read<GlobalState>();
        if (gs.mode.value == Mode.reloc) {
          gs.mode.value = Mode.normal;
        }
        return true;
      },
      child: Scaffold(
        appBar: AppBar(
          title: Row(
            children: [
              const Icon(Icons.map, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.mapName,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          backgroundColor: theme.colorScheme.primaryContainer,
          actions: [
            // 重定位提示按钮
            ValueListenableBuilder<Mode>(
              valueListenable: context.read<GlobalState>().mode,
              builder: (ctx, mode, _) {
                if (mode != Mode.reloc) return const SizedBox.shrink();
                return Chip(
                  avatar: const Icon(Icons.info_outline,
                      size: 16, color: Colors.white),
                  label: const Text('重定位模式',
                      style: TextStyle(color: Colors.white, fontSize: 12)),
                  backgroundColor: Colors.green,
                );
              },
            ),
            const SizedBox(width: 8),
          ],
        ),
        body: ValueListenableBuilder<Mode>(
          valueListenable: context.read<GlobalState>().mode,
          builder: (ctx, mode, _) {
            return Stack(
              children: [
                // 地图
                TileMap(
                  key: _tileMapKey,
                  mapName: widget.mapName,
                  onTap: () {
                    setState(() => _selectedNavPoint = null);
                  },
                  onTapWorld: _isNavPickMode
                      ? (wx, wy) {
                          setState(() {
                            _pickedX = wx;
                            _pickedY = wy;
                          });
                        }
                      : null,
                  onNavPointTap: (p) {
                    setState(() => _selectedNavPoint = p);
                    if (p != null) _showNavPointDialog(p);
                  },
                  selectedNavPointName: _selectedNavPoint?.name,
                  enableMapInteraction: mode != Mode.reloc,
                  followRobot: mode == Mode.robotFixedCenter,
                  editMode: false,
                ),

                // 重定位工具栏（左侧）
                _buildRelocToolbar(theme),

                // 右侧工具栏
                _buildRightToolbar(theme),

                // 停止导航按钮
                _buildStopNavButton(theme),

                // 重定位提示横幅
                if (mode == Mode.reloc)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        color: Colors.green.withOpacity(0.85),
                        child: const Text(
                          '拖动机器人图标到正确位置，旋转调整朝向，然后点击 ✓ 确认',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),

                // 选点导航标记层
                if (_isNavPickMode) ...[
                  Positioned.fill(
                    child: IgnorePointer(
                      child: _NavPickMarkerLayer(
                        tileMapKey: _tileMapKey,
                        pickedX: _pickedX,
                        pickedY: _pickedY,
                        pickedTheta: _pickedTheta,
                        trajectory: _navTrajectory,
                      ),
                    ),
                  ),
                  _buildNavPickPanel(theme),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

// ── 地图选点标记层 ─────────────────────────────────────────────────
class _NavPickMarkerLayer extends StatelessWidget {
  final GlobalKey<TileMapState> tileMapKey;
  final double? pickedX;
  final double? pickedY;
  final double pickedTheta;
  final List<Map<String, double>> trajectory;

  const _NavPickMarkerLayer({
    required this.tileMapKey,
    required this.pickedX,
    required this.pickedY,
    required this.pickedTheta,
    required this.trajectory,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _NavPickPainter(
        tileMapKey: tileMapKey,
        pickedX: pickedX,
        pickedY: pickedY,
        pickedTheta: pickedTheta,
        trajectory: trajectory,
      ),
    );
  }
}

class _NavPickPainter extends CustomPainter {
  final GlobalKey<TileMapState> tileMapKey;
  final double? pickedX;
  final double? pickedY;
  final double pickedTheta;
  final List<Map<String, double>> trajectory;

  _NavPickPainter({
    required this.tileMapKey,
    required this.pickedX,
    required this.pickedY,
    required this.pickedTheta,
    required this.trajectory,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final state = tileMapKey.currentState;
    if (state == null) return;

    if (trajectory.isNotEmpty) {
      final linePaint = Paint()
        ..color = Colors.purple.withOpacity(0.7)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final List<Offset> offsets = [];
      for (final p in trajectory) {
        final off = state.worldToScreen(p['x']!, p['y']!);
        if (off != null) offsets.add(off);
      }
      for (int i = 0; i < offsets.length - 1; i++) {
        canvas.drawLine(offsets[i], offsets[i + 1], linePaint);
      }
      for (int i = 0; i < offsets.length; i++) {
        final off = offsets[i];
        canvas.drawCircle(
            off, 9, Paint()..color = Colors.white..style = PaintingStyle.fill);
        canvas.drawCircle(
            off,
            9,
            Paint()
              ..color = Colors.purple
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2);
        final tp = TextPainter(
          text: TextSpan(
              text: '${i + 1}',
              style: const TextStyle(
                  color: Colors.purple,
                  fontSize: 10,
                  fontWeight: FontWeight.bold)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, off - Offset(tp.width / 2, tp.height / 2));
      }
    }

    if (pickedX != null && pickedY != null) {
      final off = state.worldToScreen(pickedX!, pickedY!);
      if (off != null) _drawPin(canvas, off, pickedTheta);
    }
  }

  void _drawPin(Canvas canvas, Offset center, double theta) {
    const pinR = 14.0;
    final dx = pinR * 2.0 * math.cos(theta);
    final dy = pinR * 2.0 * (-math.sin(theta));
    final tip = center + Offset(dx, dy);

    canvas.drawLine(
        center,
        tip,
        Paint()
          ..color = Colors.blue.shade700
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round);
    _drawArrowHead(canvas, center, tip, Colors.blue.shade700);

    canvas.drawCircle(
        center, pinR + 2, Paint()..color = Colors.white..style = PaintingStyle.fill);
    canvas.drawCircle(
        center, pinR, Paint()..color = Colors.blue.shade600..style = PaintingStyle.fill);
    canvas.drawCircle(
        center,
        pinR * 0.45,
        Paint()..color = Colors.white..style = PaintingStyle.fill);
    canvas.drawCircle(
        center,
        pinR + 7,
        Paint()
          ..color = Colors.blue.withOpacity(0.25)
          ..style = PaintingStyle.fill);
  }

  void _drawArrowHead(Canvas canvas, Offset from, Offset to, Color color) {
    final dir = to - from;
    final len = dir.distance;
    if (len < 1) return;
    final unit = dir / len;
    final perp = Offset(-unit.dy, unit.dx);
    const headLen = 8.0;
    const headW = 5.0;
    final p1 = to - unit * headLen + perp * headW;
    final p2 = to - unit * headLen - perp * headW;
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_NavPickPainter old) =>
      old.pickedX != pickedX ||
      old.pickedY != pickedY ||
      old.pickedTheta != pickedTheta ||
      old.trajectory.length != trajectory.length;
}
