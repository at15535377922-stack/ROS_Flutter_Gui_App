import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';

import 'package:ros_flutter_gui_app/display/tile_map.dart';
import 'package:ros_flutter_gui_app/page/gamepad_widget.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';

/// 建图实时可视化页面
///
/// 完全复用 [TileMap] 组件（slamMode=true）：
/// - 不加载已有地图瓦片；底图来自实时 /map 占用栅格
/// - 激光点、机器人位置/朝向、路径、代价图等图层与主页面一致
/// - 支持 Gamepad 遥控、跟随机器人、缩放等工具栏
class SlamViewPage extends StatefulWidget {
  const SlamViewPage({super.key});

  @override
  State<SlamViewPage> createState() => _SlamViewPageState();
}

class _SlamViewPageState extends State<SlamViewPage> {
  final GlobalKey<TileMapState> _tileMapKey = GlobalKey<TileMapState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // 进入建图页时确保不处于地图编辑模式
      final gs = context.read<GlobalState>();
      if (gs.mode.value == Mode.mapEdit) {
        gs.mode.value = Mode.normal;
      }
    });
  }

  @override
  void dispose() {
    // 退出时若处于跟随模式，恢复正常（避免影响主页面）
    if (mounted) {
      final gs = context.read<GlobalState>();
      if (gs.mode.value == Mode.robotFixedCenter) {
        gs.mode.value = Mode.normal;
      }
    }
    super.dispose();
  }

  // ──────────────────────────────── 顶栏 ────────────────────────────────

  Widget _buildTopBar(BuildContext context, ThemeData theme) {
    final ws = context.read<WsChannel>();
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: AppBar(
        title: const Text('建图实时可视化'),
        actions: [
          // 激光点状态指示
          ValueListenableBuilder(
            valueListenable: ws.laserPointData,
            builder: (_, laserData, __) {
              final alive = laserData.laserPoseBaseLink.isNotEmpty;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: alive ? Colors.green : Colors.grey,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      alive ? '建图中' : '等待数据',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────── 右侧工具栏 ────────────────────────────

  Widget _toolbarShell(ThemeData theme, {required Widget child}) {
    return Material(
      elevation: 2,
      shadowColor: Colors.black26,
      borderRadius: BorderRadius.circular(12),
      color: theme.colorScheme.surface,
      child: child,
    );
  }

  Widget _buildRightToolbar(BuildContext context, ThemeData theme) {
    final gs = context.read<GlobalState>();
    final tbStyle = IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.all(10),
    );
    return Positioned(
      right: 10,
      top: 70,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 缩放 +
          _toolbarShell(theme,
              child: IconButton(
                style: tbStyle,
                icon: const Icon(Icons.zoom_in_rounded),
                tooltip: '放大',
                onPressed: () => _tileMapKey.currentState?.zoomIn(),
              )),
          const SizedBox(height: 6),
          // 缩放 -
          _toolbarShell(theme,
              child: IconButton(
                style: tbStyle,
                icon: const Icon(Icons.zoom_out_rounded),
                tooltip: '缩小',
                onPressed: () => _tileMapKey.currentState?.zoomOut(),
              )),
          const SizedBox(height: 6),
          // 跟随机器人
          ValueListenableBuilder<Mode>(
            valueListenable: gs.mode,
            builder: (_, mode, __) => _toolbarShell(
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
                  gs.mode.value = gs.mode.value == Mode.robotFixedCenter
                      ? Mode.normal
                      : Mode.robotFixedCenter;
                },
              ),
            ),
          ),
          const SizedBox(height: 6),
          // 遥控开关
          ValueListenableBuilder<bool>(
            valueListenable: gs.isManualCtrl,
            builder: (_, isManual, __) {
              final ws = context.read<WsChannel>();
              return _toolbarShell(
                theme,
                child: IconButton(
                  style: tbStyle,
                  icon: Icon(
                    const IconData(0xea45, fontFamily: 'GamePad'),
                    color: isManual ? Colors.green : theme.iconTheme.color,
                  ),
                  tooltip: isManual ? '关闭遥控' : '开启遥控',
                  onPressed: () {
                    if (isManual) {
                      gs.isManualCtrl.value = false;
                      ws.stopMunalCtrl();
                    } else {
                      gs.isManualCtrl.value = true;
                      ws.startMunalCtrl();
                      toastification.show(
                        context: context,
                        title: const Text('遥控已开启'),
                        description: const Text('使用左摇杆平移，右摇杆旋转'),
                        autoCloseDuration: const Duration(seconds: 3),
                      );
                    }
                    setState(() {});
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  // ──────────────────────────────── build ────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final gs = context.read<GlobalState>();

    return Scaffold(
      body: ValueListenableBuilder<Mode>(
        valueListenable: gs.mode,
        builder: (context, mode, _) {
          return Stack(
            children: [
              // ── 核心地图（slamMode=true：跳过瓦片底图，实时显示 /map 栅格） ──
              TileMap(
                key: _tileMapKey,
                slamMode: true,
                followRobot: mode == Mode.robotFixedCenter,
                enableMapInteraction: true,
              ),
              // ── 顶栏 ──
              _buildTopBar(context, theme),
              // ── 右侧工具栏 ──
              _buildRightToolbar(context, theme),
              // ── Gamepad 摇杆（与主页面共享 GlobalState.isManualCtrl） ──
              Positioned.fill(child: GamepadWidget()),
            ],
          );
        },
      ),
    );
  }
}