import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';

import 'package:ros_flutter_gui_app/basic/action_status.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/display/grid.dart' show WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/path.dart';
import 'package:ros_flutter_gui_app/display/tile_map.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';

/// 多点巡航导航状态
enum WaypointNavState { idle, running }

/// 多点巡航导航页面
class WaypointNavPage extends StatefulWidget {
  const WaypointNavPage({super.key});

  @override
  State<WaypointNavPage> createState() => _WaypointNavPageState();
}

class _WaypointNavPageState extends State<WaypointNavPage> {
  final GlobalKey<TileMapState> _tileMapKey = GlobalKey<TileMapState>();

  List<NavPoint> _waypoints = [];
  WaypointNavState _navState = WaypointNavState.idle;
  int _currentIndex = 0;
  String _currentMapName = '';

  static const _kNavTimeoutSec = 60;
  Timer? _navTimeoutTimer;
  StreamSubscription<ActionStatus>? _navStatusSub;

  // 缓存 WsChannel，避免 async gap 后使用 context
  late WsChannel _ws;

  @override
  void initState() {
    super.initState();
    _initLoad();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ws = context.read<WsChannel>();
  }

  @override
  void dispose() {
    _navTimeoutTimer?.cancel();
    _navStatusSub?.cancel();
    super.dispose();
  }

  Future<void> _initLoad() async {
    try {
      final http = context.read<HttpChannel>();
      _currentMapName = await http.getCurrentMap();
      if (_currentMapName.isEmpty) return;
      final raw = await http.getWaypoints(_currentMapName);
      if (!mounted) return;
      setState(() {
        _waypoints = raw.map((m) {
          return NavPoint(
            x: (m['x'] as num).toDouble(),
            y: (m['y'] as num).toDouble(),
            theta: (m['theta'] as num).toDouble(),
            name: m['name'] as String? ?? '导航点',
            type: NavPointType.navGoal,
          );
        }).toList();
      });
    } catch (_) {}
  }

  Future<void> _saveWaypoints() async {
    if (_currentMapName.isEmpty) return;
    try {
      final list = _waypoints
          .map((p) => {
                'name': p.name,
                'x': p.x,
                'y': p.y,
                'theta': p.theta,
                'type': 'NavGoal',
              })
          .toList();
      await context.read<HttpChannel>().saveWaypoints(_currentMapName, list);
      if (!mounted) return;
      toastification.show(
        context: context,
        title: const Text('导航点已保存'),
        autoCloseDuration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('保存失败：$e'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _startNav() async {
    if (_waypoints.isEmpty) {
      toastification.show(
        context: context,
        type: ToastificationType.warning,
        title: const Text('请先在地图上长按添加导航点'),
        autoCloseDuration: const Duration(seconds: 3),
      );
      return;
    }
    setState(() {
      _navState = WaypointNavState.running;
      _currentIndex = 0;
    });
    await _sendCurrentGoal();
  }

  Future<void> _sendCurrentGoal() async {
    if (_currentIndex >= _waypoints.length) {
      _finishNav('所有导航点已到达！');
      return;
    }
    final p = _waypoints[_currentIndex];
    _ws.sendNavigationGoal(RobotPose(p.x, p.y, p.theta));

    if (mounted) {
      final label = '正在前往：${p.name} (${_currentIndex + 1}/${_waypoints.length})';
      toastification.show(
        context: context,
        title: Text(label),
        autoCloseDuration: const Duration(seconds: 2),
      );
    }

    // 超时定时器
    _navTimeoutTimer?.cancel();
    _navTimeoutTimer = Timer(const Duration(seconds: _kNavTimeoutSec), () {
      if (_navState == WaypointNavState.running && mounted) {
        _cancelNav(reason: '导航超时（>60s），已停止');
      }
    });

    // 监听 action_status
    _navStatusSub?.cancel();
    _navStatusSub = Stream.periodic(const Duration(milliseconds: 500))
        .map((_) => _ws.navStatus_.value)
        .distinct()
        .listen((status) {
      if (_navState != WaypointNavState.running) return;
      switch (status) {
        case ActionStatus.succeeded:
          _navTimeoutTimer?.cancel();
          _navStatusSub?.cancel();
          setState(() => _currentIndex++);
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted && _navState == WaypointNavState.running) {
              _sendCurrentGoal();
            }
          });
          break;
        case ActionStatus.aborted:
          _navTimeoutTimer?.cancel();
          _navStatusSub?.cancel();
          final failMsg = '第${_currentIndex + 1}个导航点失败（aborted）';
          _cancelNav(reason: failMsg);
          break;
        case ActionStatus.canceled:
          _navTimeoutTimer?.cancel();
          _navStatusSub?.cancel();
          if (_navState == WaypointNavState.running) {
            _finishNav('导航已取消');
          }
          break;
        default:
          break;
      }
    });
  }

  Future<void> _cancelNav({String reason = '导航已取消，小车停在当前位置'}) async {
    _navTimeoutTimer?.cancel();
    _navStatusSub?.cancel();
    setState(() => _navState = WaypointNavState.idle);
    try {
      await context.read<HttpChannel>().postRobotCancelNav();
    } catch (_) {}
    if (!mounted) return;
    toastification.show(
      context: context,
      type: ToastificationType.warning,
      title: Text(reason),
      autoCloseDuration: const Duration(seconds: 4),
    );
    setState(() => _currentIndex = 0);
  }

  void _finishNav(String msg) {
    _navTimeoutTimer?.cancel();
    _navStatusSub?.cancel();
    if (!mounted) return;
    setState(() {
      _navState = WaypointNavState.idle;
      _currentIndex = 0;
    });
    toastification.show(
      context: context,
      type: ToastificationType.success,
      title: Text(msg),
      autoCloseDuration: const Duration(seconds: 4),
    );
  }

  // ── 坐标转换 (已移至 extraLayerBuilder 回调参数中使用) ──────────────────────────

  // ── 图层构建 ────────────────────────────────────────────────────────────────

  Widget _buildWaypointLine(WorldToLatLngFn toLatLng) {
    if (_waypoints.length < 2) return const SizedBox.shrink();
    final points = _waypoints.map((p) => toLatLng(p.x, p.y)).toList();
    return PolylineLayer(
      polylines: [
        Polyline(
          points: points,
          color: Colors.orange.withValues(alpha: 0.8),
          strokeWidth: 2.5,
          pattern: StrokePattern.dashed(segments: const [10, 6]),
        ),
      ],
    );
  }

  Widget _buildWaypointMarkers(WorldToLatLngFn toLatLng) {
    return MarkerLayer(
      markers: List.generate(_waypoints.length, (i) {
        final p = _waypoints[i];
        final isCurrent =
            _navState == WaypointNavState.running && i == _currentIndex;
        final isDone =
            _navState == WaypointNavState.running && i < _currentIndex;
        return Marker(
          point: toLatLng(p.x, p.y),
          width: 36,
          height: 36,
          child: Tooltip(
            message: p.name,
            child: Container(
              decoration: BoxDecoration(
                color: isDone
                    ? Colors.green
                    : isCurrent
                        ? Colors.blue
                        : Colors.orange,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: const [
                  BoxShadow(blurRadius: 4, color: Colors.black26)
                ],
              ),
              child: Center(
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTracePath(WsChannel ws, WorldToLatLngFn toLatLng) {
    return ValueListenableBuilder(
      valueListenable: ws.tracePath,
      builder: (_, pts, __) {
        if (pts.length < 2) return const SizedBox.shrink();
        return buildPathLayer(
          pts.map((p) => toLatLng(p.x, p.y)).toList(),
          Colors.blue.withValues(alpha: 0.6),
          strokeWidth: 2,
        );
      },
    );
  }

  Widget _buildGlobalPath(WsChannel ws, WorldToLatLngFn toLatLng) {
    return ValueListenableBuilder(
      valueListenable: ws.globalPath,
      builder: (_, pts, __) {
        if (pts.length < 2) return const SizedBox.shrink();
        return buildPathLayer(
          pts.map((p) => toLatLng(p.x, p.y)).toList(),
          Colors.green.withValues(alpha: 0.7),
          strokeWidth: 2,
        );
      },
    );
  }

  Widget _buildRobot(WsChannel ws, WorldToLatLngFn toLatLng) {
    return ValueListenableBuilder<RobotPose>(
      valueListenable: ws.robotPoseMap,
      builder: (_, pose, __) {
        return MarkerLayer(
          markers: [
            Marker(
              point: toLatLng(pose.x, pose.y),
              width: 40,
              height: 40,
              child: Transform.rotate(
                angle: -(pose.theta),
                child: const Icon(Icons.navigation,
                    color: Colors.blue, size: 32),
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _buildExtraLayers(WorldToLatLngFn toLatLng) {
    final ws = _ws;
    return [
      _buildTracePath(ws, toLatLng),
      _buildGlobalPath(ws, toLatLng),
      _buildWaypointLine(toLatLng),
      _buildWaypointMarkers(toLatLng),
      _buildRobot(ws, toLatLng),
    ];
  }

  // ── 底部控制栏 ──────────────────────────────────────────────────────────────

  Widget _buildBottomBar(ThemeData theme) {
    final running = _navState == WaypointNavState.running;
    final statusText = running
        ? '巡航中：${_currentIndex + 1} / ${_waypoints.length}  →  ${_waypoints[_currentIndex].name}'
        : '共 ${_waypoints.length} 个导航点  |  长按地图添加';
    return Container(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.95),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(
              child: Text(
                statusText,
                style: theme.textTheme.bodySmall,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            if (!running)
              TextButton.icon(
                onPressed: _waypoints.isEmpty ? null : _saveWaypoints,
                icon: const Icon(Icons.save_outlined, size: 18),
                label: const Text('保存'),
              ),
            const SizedBox(width: 4),
            if (!running)
              FilledButton.icon(
                onPressed: _waypoints.isEmpty ? null : _startNav,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('开始巡航'),
              )
            else
              FilledButton.icon(
                style:
                    FilledButton.styleFrom(backgroundColor: Colors.red),
                onPressed: () => _cancelNav(),
                icon: const Icon(Icons.stop_rounded),
                label: const Text('取消'),
              ),
          ],
        ),
      ),
    );
  }

  // ── 导航点列表面板 ──────────────────────────────────────────────────────────

  void _showWaypointListPanel() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.5,
            maxChildSize: 0.85,
            builder: (_, scrollCtrl) => Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(vertical: 8),
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Text(
                        '导航点列表（${_waypoints.length}）',
                        style: Theme.of(ctx).textTheme.titleMedium,
                      ),
                      const Spacer(),
                      TextButton(
                        onPressed: () {
                          setState(() => _waypoints.clear());
                          setModalState(() {});
                        },
                        child: const Text('清空',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: _waypoints.isEmpty
                      ? const Center(child: Text('长按地图添加导航点'))
                      : ReorderableListView.builder(
                          scrollController: scrollCtrl,
                          itemCount: _waypoints.length,
                          onReorderItem: (oldIndex, newIndex) {
                            setState(() {
                              final item = _waypoints.removeAt(oldIndex);
                              _waypoints.insert(newIndex, item);
                            });
                            setModalState(() {});
                          },
                          itemBuilder: (_, i) {
                            final p = _waypoints[i];
                            final degStr =
                                (p.theta * 180 / 3.14159).toStringAsFixed(1);
                            return ListTile(
                              key: ValueKey('wp_$i'),
                              leading: CircleAvatar(
                                backgroundColor: Colors.orange,
                                child: Text(
                                  '${i + 1}',
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                              title: Text(p.name),
                              subtitle: Text(
                                  'x: ${p.x.toStringAsFixed(2)}  y: ${p.y.toStringAsFixed(2)}  θ: $degStr°'),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline,
                                        color: Colors.red),
                                    onPressed: () {
                                      setState(() => _waypoints.removeAt(i));
                                      setModalState(() {});
                                    },
                                  ),
                                  const Icon(Icons.drag_handle,
                                      color: Colors.grey),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final globalState = context.read<GlobalState>();

    return WillPopScope(
      onWillPop: () async {
        // 退出页面时如果处于重定位模式，自动取消
        if (globalState.mode.value == Mode.reloc) {
          globalState.mode.value = Mode.normal;
        }
        return true;
      },
      child: ValueListenableBuilder<Mode>(
        valueListenable: globalState.mode,
        builder: (context, mode, _) {
          final isReloc = mode == Mode.reloc;
          return Scaffold(
            appBar: AppBar(
              title: const Text('多点巡航导航'),
              actions: [
                // 重定位按钮
                IconButton(
                  icon: Icon(
                    const IconData(0xe60f, fontFamily: "Reloc"),
                    color: isReloc ? Colors.green : null,
                  ),
                  tooltip: isReloc ? '退出重定位' : '重定位',
                  onPressed: () {
                    globalState.mode.value =
                        isReloc ? Mode.normal : Mode.reloc;
                  },
                ),
                // 重定位确认 / 取消（仅在重定位模式下显示）
                if (isReloc) ...[
                  IconButton(
                    icon: const Icon(Icons.check, color: Colors.green),
                    tooltip: '确认重定位',
                    onPressed: () {
                      globalState.mode.value = Mode.normal;
                      context.read<WsChannel>().sendRelocPose(
                            _tileMapKey.currentState?.getRelocRobotPose() ??
                                RobotPose.zero(),
                          );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red),
                    tooltip: '取消重定位',
                    onPressed: () {
                      globalState.mode.value = Mode.normal;
                    },
                  ),
                ],
                IconButton(
                  icon: const Icon(Icons.list_alt_rounded),
                  tooltip: '导航点列表',
                  onPressed: isReloc ? null : _showWaypointListPanel,
                ),
                IconButton(
                  icon: const Icon(Icons.my_location),
                  tooltip: '定位到机器人',
                  onPressed: () => _tileMapKey.currentState?.moveToRobot(),
                ),
              ],
            ),
            body: Column(
              children: [
                // 重定位模式提示条
                if (isReloc)
                  Container(
                    color: Colors.green.withValues(alpha: 0.15),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    child: Row(
                      children: [
                        const Icon(Icons.info_outline,
                            size: 16, color: Colors.green),
                        const SizedBox(width: 8),
                        const Expanded(
                          child: Text(
                            '重定位模式：拖动地图上的机器人图标对齐实际位置，旋转调整朝向，确认后发布',
                            style: TextStyle(
                                fontSize: 12, color: Colors.green),
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  Container(
                    color: theme.colorScheme.surfaceContainerLow,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 6),
                    child: Row(
                      children: [
                        _legendItem(Colors.orange, '待导航连线'),
                        const SizedBox(width: 16),
                        _legendItem(Colors.green, '规划路径'),
                        const SizedBox(width: 16),
                        _legendItem(
                            Colors.blue.withValues(alpha: 0.6), '历史轨迹'),
                        const Spacer(),
                        const Text('长按地图添加点',
                            style:
                                TextStyle(fontSize: 11, color: Colors.grey)),
                      ],
                    ),
                  ),
                Expanded(
                  child: TileMap(
                    key: _tileMapKey,
                    enableMapInteraction: !isReloc,
                    onLongPressWorld: isReloc
                        ? null
                        : (wx, wy) {
                            if (_navState == WaypointNavState.running) return;
                            final idx = _waypoints.length + 1;
                            setState(() {
                              _waypoints.add(NavPoint(
                                x: wx,
                                y: wy,
                                theta: 0,
                                name: '导航点$idx',
                                type: NavPointType.navGoal,
                              ));
                            });
                          },
                    extraLayerBuilder:
                        isReloc ? null : _buildExtraLayers,
                  ),
                ),
                if (!isReloc) _buildBottomBar(theme),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _legendItem(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 14, height: 3, color: color),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11)),
      ],
    );
  }
}
