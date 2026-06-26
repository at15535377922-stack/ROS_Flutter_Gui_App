import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';

import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/display/laser.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';

/// 建图实时可视化页面
/// 显示：当前 /map 瓦片 + 实时 /scan 激光点（红色）+ 机器人位置
/// 建图 / 保存由 ROS 后台负责，本页只负责渲染
class SlamViewPage extends StatefulWidget {
  const SlamViewPage({super.key});

  @override
  State<SlamViewPage> createState() => _SlamViewPageState();
}

class _SlamViewPageState extends State<SlamViewPage> {
  final MapController _mapController = MapController();

  // 话题数据超时检测：超过 5s 没收到激光数据视为建图停止
  Timer? _timeoutTimer;
  bool _hasWarnedTimeout = false;
  int _laserCount = 0;

  @override
  void initState() {
    super.initState();
    _startTimeoutCheck();
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    super.dispose();
  }

  void _startTimeoutCheck() {
    _timeoutTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      final ws = context.read<WsChannel>();
      final laser = ws.laserPointData.value;
      final count = laser.laserPoseBaseLink.length;
      if (count != _laserCount) {
        // 有新数据
        _laserCount = count;
        _hasWarnedTimeout = false;
      } else {
        if (!_hasWarnedTimeout) {
          _hasWarnedTimeout = true;
          if (mounted) {
            toastification.show(
              context: context,
              type: ToastificationType.warning,
              title: const Text('建图数据超时'),
              description: const Text('未收到 /scan 数据，请确认建图 Launch 是否正在运行'),
              autoCloseDuration: const Duration(seconds: 5),
            );
          }
        }
      }
    });
  }

  LatLng _worldToLatLng(double worldX, double worldY) {
    // 复用全局瓦片地图坐标系转换，与 tile_map.dart 保持一致
    // 瓦片地图：lat = -worldY, lng = worldX
    return LatLng(-worldY, worldX);
  }

  Widget _buildLaserLayer(WsChannel ws) {
    return ValueListenableBuilder(
      valueListenable: ws.laserPointData,
      builder: (_, laserData, __) {
        return buildLaserLayer(
          ws,
          _worldToLatLng,
          color: Colors.red,
          dotRadius: 2.5,
        );
      },
    );
  }

  Widget _buildRobotLayer(WsChannel ws) {
    return ValueListenableBuilder<RobotPose>(
      valueListenable: ws.robotPoseMap,
      builder: (_, pose, __) {
        final latLng = _worldToLatLng(pose.x, pose.y);
        return MarkerLayer(
          markers: [
            Marker(
              point: latLng,
              width: 40,
              height: 40,
              child: Transform.rotate(
                angle: -(pose.theta),
                child: const Icon(
                  Icons.navigation,
                  color: Colors.blue,
                  size: 32,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.read<WsChannel>();
    final theme = Theme.of(context);
    // 当前地图 tiles URL（复用后端已有的 /tiles/ 接口）
    final tilesUrl =
        '${globalSetting.tileServerUrl}/tiles/{z}/{x}/{y}.png';

    return Scaffold(
      appBar: AppBar(
        title: const Text('建图实时可视化'),
        actions: [
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
      body: Stack(
        children: [
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: const LatLng(0, 0),
              initialZoom: 3,
              minZoom: 1,
              maxZoom: 22,
              interactionOptions: const InteractionOptions(
                flags: InteractiveFlag.all,
              ),
            ),
            children: [
              // 底层地图瓦片（当前地图 /map 内容）
              TileLayer(
                urlTemplate: tilesUrl,
                userAgentPackageName: 'ros_flutter_gui_app',
                errorTileCallback: (tile, error, stackTrace) {},
              ),
              // 实时激光点（红色）
              _buildLaserLayer(ws),
              // 机器人位置
              _buildRobotLayer(ws),
            ],
          ),
          // 说明文字
          Positioned(
            left: 12,
            bottom: 16,
            child: Card(
              color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.85),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(width: 10, height: 10,
                        decoration: const BoxDecoration(color: Colors.red, shape: BoxShape.circle)),
                    const SizedBox(width: 6),
                    const Text('激光点', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 14),
                    const Icon(Icons.navigation, color: Colors.blue, size: 14),
                    const SizedBox(width: 4),
                    const Text('机器人', style: TextStyle(fontSize: 12)),
                    const SizedBox(width: 14),
                    Container(width: 14, height: 8,
                        color: Colors.black87),
                    const SizedBox(width: 4),
                    const Text('/map 障碍', style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.small(
        tooltip: '定位到机器人',
        onPressed: () {
          final pose = ws.robotPoseMap.value;
          _mapController.move(_worldToLatLng(pose.x, pose.y), _mapController.camera.zoom);
        },
        child: const Icon(Icons.my_location),
      ),
    );
  }
}
