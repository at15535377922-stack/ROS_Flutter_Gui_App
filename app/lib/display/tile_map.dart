import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import 'package:vector_math/vector_math_64.dart' as vm;
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/basic/tile_map_meta.dart';
import 'package:ros_flutter_gui_app/basic/topology_map.dart';
import 'package:ros_flutter_gui_app/basic/layer_config.dart';
import 'package:ros_flutter_gui_app/basic/occupancy_map.dart';
import 'package:ros_flutter_gui_app/display/costmap.dart';
import 'package:ros_flutter_gui_app/display/grid.dart' show WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/laser.dart' hide WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/path.dart';
import 'package:ros_flutter_gui_app/display/pointcloud.dart' hide WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/polygon.dart' hide WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/robot.dart' hide WorldToLatLngFn;
import 'package:ros_flutter_gui_app/display/topology_line.dart' hide WorldToLatLngFn;
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';
import 'package:ros_flutter_gui_app/language/l10n/gen/app_localizations.dart';

enum ObstacleEditTool {
  None,
  Brush,
  Eraser,
}

class TileMap extends StatefulWidget {
  final Function(NavPoint?)? onNavPointTap;
  final ValueChanged<TopologyRoute>? onRouteTap;
  final TopologyRoute? selectedRoute;
  final VoidCallback? onTap;
  final void Function(double worldX, double worldY)? onTapWorld;
  final bool enableMapInteraction;
  final bool editMode;
  final ObstacleEditTool obstacleEditTool;
  final double obstacleBrushSizeMeters;
  final void Function(NavPoint oldPoint, NavPoint newPoint)? onNavPointEditEnd;
  final void Function(Map<int, int> oldEdits, Map<int, int> newEdits)? onObstacleEditEnd;
  final String? selectedNavPointName;
  final bool followRobot;
  final bool enlargeNavPointMarkers;
  final String mapName;
  /// 额外叠加在地图上的图层（追加在内置图层之后）
  final List<Widget> extraLayers;
  /// 额外图层构建器，回调将提供坐标转换函数，可正确将世界坐标转为地图 LatLng
  final List<Widget> Function(WorldToLatLngFn toLatLng)? extraLayerBuilder;
  /// 长按地图时的世界坐标回调
  final void Function(double worldX, double worldY)? onLongPressWorld;
  /// 建图模式：跳过 tile 底图加载，直接从 ws.map_（/map topic）实时渲染占用栅格
  final bool slamMode;

  const TileMap({
    super.key,
    this.onNavPointTap,
    this.onRouteTap,
    this.selectedRoute,
    this.onTap,
    this.onTapWorld,
    this.enableMapInteraction = true,
    this.editMode = false,
    this.obstacleEditTool = ObstacleEditTool.None,
    this.obstacleBrushSizeMeters = 0.25,
    this.onNavPointEditEnd,
    this.onObstacleEditEnd,
    this.selectedNavPointName,
    this.followRobot = false,
    this.enlargeNavPointMarkers = false,
    this.mapName = '',
    this.extraLayers = const [],
    this.extraLayerBuilder,
    this.onLongPressWorld,
    this.slamMode = false,
  });

  @override
  State<TileMap> createState() => TileMapState();
}

class TileMapState extends State<TileMap> {
  MapMeta? _meta;
  String? _error;
  final MapController _mapController = MapController();
  final ValueNotifier<TopologyMap> _topologyMap = ValueNotifier(TopologyMap(points: []));
  bool _slamMetaInitialized = false; // 防止 didChangeDependencies 重复初始化
  String _currentMapName = '';
  bool _isLoadingMeta = false;
  double _currentZoom = 2.0;
  RobotPose? _relocPose;
  final Map<String, NavPoint> _draggingNavPoints = {};
  final Map<String, NavPoint> _draggingNavPointsStart = {};
  final Map<int, int> _obstacleEdits = {};
  final Map<int, int> _obstacleStrokeOldEdits = {};
  final Map<int, int> _obstacleStrokeNewEdits = {};
  Offset? _lastObstaclePaintLocal;
  WsChannel? _wsChannelRef;
  GlobalState? _globalStateRef;
  ValueNotifier<TopologyMap>? _mapManagerTopologyRef;
  ValueNotifier<bool>? _manualCtrlRef;
  bool _robotFollowListenerAttached = false;
  bool _topologyListenerAttached = false;
  bool _manualRefreshListenerAttached = false;
  bool _mapTileStyleListenerAttached = false;
  Timer? _autoRefreshTimer;
  int _tileCacheBuster = DateTime.now().millisecondsSinceEpoch ~/ 5000;

  @override
  void initState() {
    super.initState();
    // slamMode 下必须等 didChangeDependencies 后 context.read 可用再初始化
    if (!widget.slamMode) {
      _syncMapDataFromWidget();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wsChannelRef ??= context.read<WsChannel>();
    _globalStateRef ??= context.read<GlobalState>();
    _syncRobotFollowListener();
    _syncTopologyListener();
    _syncManualRefreshListener();
    _syncMapTileStyleListener();
    // slamMode 在这里做一次性初始化（context.read 此时已可用）
    if (widget.slamMode && !_slamMetaInitialized) {
      _slamMetaInitialized = true;
      _initSlamMeta();
    }
  }

  @override
  void didUpdateWidget(TileMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncRobotFollowListener();
    _syncTopologyListener();
    _syncManualRefreshListener();
    if (oldWidget.mapName != widget.mapName) {
      _syncMapDataFromWidget();
    }
    if (widget.followRobot && !oldWidget.followRobot) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _snapCameraToRobot(zoom: 6.0));
    }
  }

  void _syncMapDataFromWidget() {
    if (widget.slamMode) {
      _initSlamMeta();
    } else {
      _loadMetaByMapName();
    }
  }

  /// 建图模式：从 ws.map_ 的当前帧构建 MapMeta，并监听后续更新
  void _initSlamMeta() {
    final ws = _wsChannelRef ?? context.read<WsChannel>();
    // 防止重复添加监听器
    ws.map_.removeListener(_onSlamMapUpdate);
    ws.map_.addListener(_onSlamMapUpdate);
    _wsChannelRef = ws;
    _buildSlamMeta(ws.map_.value);
  }

  void _onSlamMapUpdate() {
    final ws = _wsChannelRef;
    if (!mounted || ws == null) return;
    _buildSlamMeta(ws.map_.value);
  }

  void _buildSlamMeta(OccupancyMap occ) {
    final cfg = occ.mapConfig;
    if (cfg.width <= 0 || cfg.height <= 0) return;
    // 使用一个足够大的 maxZoom，使图层可以正常渲染
    const int kSlamMaxZoom = 8;
    const int kExtraZoom = 0;
    final meta = MapMeta(
      resolution: cfg.resolution > 0 ? cfg.resolution : 0.05,
      originX: cfg.originX,
      originY: cfg.originY,
      width: cfg.width,
      height: cfg.height,
      maxZoom: kSlamMaxZoom,
      extraZoomLevels: kExtraZoom,
    );
    if (!mounted) return;
    setState(() {
      _meta = meta;
      _error = null;
    });
  }

  Future<void> _loadMetaByMapName() async {
    if (_isLoadingMeta || !mounted) return;
    _isLoadingMeta = true;
    try {
      final httpChannel = context.read<HttpChannel>();
      var targetMapName = widget.mapName;
      if (targetMapName.isEmpty) {
        targetMapName = await httpChannel.getCurrentMap();
      }
      final topologyMap = await httpChannel.getTopologyMap(
        mapName: targetMapName.isEmpty ? null : targetMapName,
      );
      final meta = await MapMeta.fetch(
        globalSetting.tileServerUrl,
        mapName: targetMapName.isEmpty ? null : targetMapName,
      );
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _error = null;
        _currentMapName = targetMapName;
      });
      _topologyMap.value = topologyMap;
      if (widget.followRobot) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _snapCameraToRobot(zoom: 6.0));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _meta = null;
        _error = e.toString();
        _currentMapName = widget.mapName;
      });
      _topologyMap.value = TopologyMap(points: []);
    } finally {
      _isLoadingMeta = false;
    }
  }

  void _syncRobotFollowListener() {
    final ws = _wsChannelRef;
    if (ws == null) return;
    final want = widget.followRobot;
    if (want && !_robotFollowListenerAttached) {
      _robotFollowListenerAttached = true;
      ws.robotPoseMap.addListener(_onRobotPoseForFollow);
    } else if (!want && _robotFollowListenerAttached) {
      ws.robotPoseMap.removeListener(_onRobotPoseForFollow);
      _robotFollowListenerAttached = false;
    }
  }

  void _syncTopologyListener() {
    final ws = _wsChannelRef;
    if (ws == null) return;
    final notifier = ws.mapManager.topologyMap;
    if (_mapManagerTopologyRef != notifier) {
      if (_topologyListenerAttached && _mapManagerTopologyRef != null) {
        _mapManagerTopologyRef!.removeListener(_onMapManagerTopologyChanged);
      }
      _mapManagerTopologyRef = notifier;
      _topologyListenerAttached = false;
    }
    if (!_topologyListenerAttached) {
      notifier.addListener(_onMapManagerTopologyChanged);
      _topologyListenerAttached = true;
    }
  }

  void _onMapManagerTopologyChanged() {
    final notifier = _mapManagerTopologyRef;
    if (!mounted || notifier == null) return;
    _topologyMap.value = notifier.value;
  }

  void _syncMapTileStyleListener() {
    if (!_mapTileStyleListenerAttached) {
      globalSetting.MapTileStyleEpoch.addListener(_onMapTileStyleChanged);
      _mapTileStyleListenerAttached = true;
    }
  }

  void _onMapTileStyleChanged() {
    if (!mounted) return;
    setState(() {
      _tileCacheBuster = DateTime.now().millisecondsSinceEpoch;
    });
  }

  @override
  void dispose() {
    _autoRefreshTimer?.cancel();
    _autoRefreshTimer = null;
    if (_manualRefreshListenerAttached && _manualCtrlRef != null) {
      _manualCtrlRef!.removeListener(_onManualControlChanged);
      _manualRefreshListenerAttached = false;
    }
    if (_mapTileStyleListenerAttached) {
      globalSetting.MapTileStyleEpoch.removeListener(_onMapTileStyleChanged);
      _mapTileStyleListenerAttached = false;
    }
    if (_robotFollowListenerAttached && _wsChannelRef != null) {
      _wsChannelRef!.robotPoseMap.removeListener(_onRobotPoseForFollow);
      _robotFollowListenerAttached = false;
    }
    if (_topologyListenerAttached && _mapManagerTopologyRef != null) {
      _mapManagerTopologyRef!.removeListener(_onMapManagerTopologyChanged);
      _topologyListenerAttached = false;
    }
    if (widget.slamMode) {
      _wsChannelRef?.map_.removeListener(_onSlamMapUpdate);
    }
    _topologyMap.dispose();
    super.dispose();
  }

  void _syncManualRefreshListener() {
    final gs = _globalStateRef;
    if (gs == null) return;
    final notifier = gs.isManualCtrl;
    if (_manualCtrlRef != notifier) {
      if (_manualRefreshListenerAttached && _manualCtrlRef != null) {
        _manualCtrlRef!.removeListener(_onManualControlChanged);
      }
      _manualCtrlRef = notifier;
      _manualRefreshListenerAttached = false;
    }
    if (!_manualRefreshListenerAttached) {
      notifier.addListener(_onManualControlChanged);
      _manualRefreshListenerAttached = true;
    }
    _setAutoRefreshEnabled(notifier.value);
  }

  void _onManualControlChanged() {
    final notifier = _manualCtrlRef;
    if (notifier == null) return;
    _setAutoRefreshEnabled(notifier.value);
  }

  void _setAutoRefreshEnabled(bool enabled) {
    if (!enabled) {
      _autoRefreshTimer?.cancel();
      _autoRefreshTimer = null;
      return;
    }
    if (_autoRefreshTimer != null) {
      return;
    }
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted) return;
      final manualCtrl = _manualCtrlRef?.value ?? false;
      if (!manualCtrl) {
        _autoRefreshTimer?.cancel();
        _autoRefreshTimer = null;
        return;
      }
      final next = DateTime.now().millisecondsSinceEpoch ~/ 5000;
      if (next != _tileCacheBuster) {
        setState(() {
          _tileCacheBuster = next;
        });
      }
    });
  }

  void _onRobotPoseForFollow() {
    if (!mounted || !widget.followRobot || _meta == null) return;
    final zoom = _mapController.camera.zoom;
    _snapCameraToRobot(zoom: zoom);
  }

  void _snapCameraToRobot({required double zoom}) {
    final meta = _meta;
    final ws = _wsChannelRef;
    if (!mounted || meta == null || ws == null) return;
    final pose = ws.robotPoseMap.value;
    _mapController.move(
      worldToLatLng(meta, pose.x, pose.y),
      zoom,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _syncMapDataFromWidget(),
              child: Text(AppLocalizations.of(context)!.retry),
            ),
          ],
        ),
      );
    }
    if (_meta == null) {
      if (widget.slamMode) {
        // 建图模式：等待后端推送第一帧 /map 数据
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text('等待建图数据…', style: TextStyle(color: Colors.grey)),
            ],
          ),
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    final meta = _meta!;
    final crs = createLocalMapCrs(meta);
    final sw = worldToLatLng(
      meta,
      meta.originX,
      meta.originY + meta.height * meta.resolution,
    );
    final ne = worldToLatLng(
      meta,
      meta.originX + meta.width * meta.resolution,
      meta.originY,
    );
    final mapBounds = LatLngBounds(sw, ne);

    return ValueListenableBuilder<Mode>(
      valueListenable: context.read<GlobalState>().mode,
      builder: (context, mode, _) {
        final enableObstacleEdit = widget.obstacleEditTool != ObstacleEditTool.None;
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) {
            if (!enableObstacleEdit) return;
            _obstacleStrokeOldEdits.clear();
            _obstacleStrokeNewEdits.clear();
            _lastObstaclePaintLocal = e.localPosition;
            _paintObstacleAtLocal(e.localPosition);
          },
          onPointerMove: (e) {
            if (!enableObstacleEdit) return;
            final prev = _lastObstaclePaintLocal;
            _lastObstaclePaintLocal = e.localPosition;
            if (prev != null) {
              const stepPx = 6.0;
              final d = (e.localPosition - prev).distance;
              final steps = (d / stepPx).ceil().clamp(1, 64);
              for (var i = 1; i <= steps; i++) {
                final t = i / steps;
                _paintObstacleAtLocal(Offset(
                  prev.dx + (e.localPosition.dx - prev.dx) * t,
                  prev.dy + (e.localPosition.dy - prev.dy) * t,
                ));
              }
            } else {
              _paintObstacleAtLocal(e.localPosition);
            }
          },
          onPointerUp: (_) {
            if (!enableObstacleEdit) return;
            _lastObstaclePaintLocal = null;
            if (widget.onObstacleEditEnd != null &&
                _obstacleStrokeNewEdits.isNotEmpty) {
              widget.onObstacleEditEnd!(
                Map<int, int>.from(_obstacleStrokeOldEdits),
                Map<int, int>.from(_obstacleStrokeNewEdits),
              );
            }
            _obstacleStrokeOldEdits.clear();
            _obstacleStrokeNewEdits.clear();
          },
          onPointerCancel: (_) {
            _lastObstaclePaintLocal = null;
            _obstacleStrokeOldEdits.clear();
            _obstacleStrokeNewEdits.clear();
          },
          child: FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              backgroundColor: globalSetting.mapTileUnknownColor,
              crs: crs,
              initialCameraFit: CameraFit.bounds(
                bounds: mapBounds,
                padding: const EdgeInsets.all(24),
                maxZoom: meta.maxZoom.toDouble(),
              ),
              minZoom: 0,
              maxZoom: meta.maxZoom.toDouble(),
              cameraConstraint: const CameraConstraint.unconstrained(),
              onMapEvent: (event) {
                if (event is MapEventWithMove) {
                  _currentZoom = event.camera.zoom;
                }
              },
              onTap: (tapPosition, latLng) {
                widget.onTap?.call();
                _handleTap(latLng);
              },
              onLongPress: (tapPosition, latLng) {
                if (widget.onLongPressWorld != null) {
                  final world = latLngToWorld(meta, latLng);
                  widget.onLongPressWorld!(world.x, world.y);
                }
              },
              interactionOptions: InteractionOptions(
                flags: !widget.enableMapInteraction
                    ? InteractiveFlag.none
                    : InteractiveFlag.all,
              ),
            ),
            children: [
              if (!widget.slamMode) ...[  
                TileLayer(
                  key: ValueKey('tile_layer_${_currentMapName}_$_tileCacheBuster'),
                  urlTemplate: _currentMapName.isNotEmpty
                      ? '${globalSetting.tileServerUrl}/tiles/{map_name}/{z}/{x}/{y}.png?_ts=$_tileCacheBuster'
                      : '${globalSetting.tileServerUrl}/tiles/{z}/{x}/{y}.png?_ts=$_tileCacheBuster',
                  additionalOptions: {'map_name': _currentMapName},
                  userAgentPackageName: 'ros_flutter_gui_app',
                  tileBounds: getTileBounds(),
                  tileProvider: NetworkTileProvider(
                    cachingProvider: const DisabledMapCachingProvider(),
                  ),
                  tileBuilder: (context, child, tileImage) {
                    if (tileImage.imageInfo?.image != null && !tileImage.loadError) {
                      return RawImage(
                        image: tileImage.imageInfo!.image,
                        fit: BoxFit.fill,
                        filterQuality: FilterQuality.none,
                        opacity: tileImage.opacity == 1
                            ? null
                            : AlwaysStoppedAnimation(tileImage.opacity),
                      );
                    }
                    return child;
                  },
                ),
              ] else ...[  
                // 建图模式：实时渲染 /map topic 的占用栅格作为底图
                Consumer<WsChannel>(
                  builder: (ctx, ws, _) => ValueListenableBuilder<OccupancyMap>(
                    valueListenable: ws.map_,
                    builder: (_, occ, __) => buildLocalCostMapOverlayLayer(
                      occ,
                      1.0,
                      _worldToLatLng(meta),
                      LocalCostmapMapStyle.raw,
                    ),
                  ),
                ),
              ],
              _buildOverlayLayers(meta),
              ...widget.extraLayers,
              if (widget.extraLayerBuilder != null)
                ...widget.extraLayerBuilder!(_worldToLatLng(meta)),
            ],
          ),
        );
      },
    );
  }

  void _handleTap(LatLng latLng) {
    if (_meta == null) return;
    final world = latLngToWorld(_meta!, latLng);
    final worldX = world.x;
    final worldY = world.y;
    widget.onTapWorld?.call(worldX, worldY);

    final navPoints = _topologyMap.value.points;
    const hitRadius = 0.5;
    for (final p in navPoints) {
      if ((p.x - worldX).abs() < hitRadius && (p.y - worldY).abs() < hitRadius) {
        widget.onNavPointTap?.call(p);
        return;
      }
    }
    widget.onNavPointTap?.call(null);
  }

  WorldToLatLngFn _worldToLatLng(MapMeta meta) => (x, y) => worldToLatLng(meta, x, y);

  Map<int, int> getObstacleEdits() => Map.unmodifiable(_obstacleEdits);

  void clearObstacleEdits() {
    if (_obstacleEdits.isEmpty) return;
    setState(() {
      _obstacleEdits.clear();
    });
  }

  void applyObstacleEdits(Map<int, int> edits) {
    if (edits.isEmpty) return;
    setState(() {
      for (final entry in edits.entries) {
        final key = entry.key;
        final value = entry.value;
        // value 0 表示清除；100 表示障碍物。
        // 为了让“原图障碍”也能被覆盖，这里要显式存储 0。
        if (value == 0 || value > 0) {
          _obstacleEdits[key] = value;
        }
      }
    });
  }

  void _paintObstacleAtLocal(Offset localPosition) {
    final meta = _meta;
    if (meta == null) return;
    final tool = widget.obstacleEditTool;
    if (tool == ObstacleEditTool.None) return;
    final camera = _mapController.camera;

    final latLng = camera.unprojectAtZoom(localPosition + camera.pixelOrigin);
    final world = latLngToWorld(meta, latLng);
    _applyObstacleBrush(world.x, world.y);
  }

  void _applyObstacleBrush(double worldX, double worldY) {
    final meta = _meta;
    if (meta == null) return;

    final tool = widget.obstacleEditTool;
    if (tool == ObstacleEditTool.None) return;
    // 障碍物编辑值语义：
    // 100: 有障碍物（黑色单元）
    // 0: 无障碍物（白色单元，表示清除）
    // 100: 有障碍（黑色）；0: 无障碍（白色，覆盖原障碍）
    final value = tool == ObstacleEditTool.Brush ? 100 : 0;

    final res = meta.resolution;
    final radius = widget.obstacleBrushSizeMeters;
    final rCells = (radius / res).ceil();
    final centerCol = ((worldX - meta.originX) / res).floor();
    final centerRow = ((worldY - meta.originY) / res).floor();

    bool changed = false;
    for (var dy = -rCells; dy <= rCells; dy++) {
      for (var dx = -rCells; dx <= rCells; dx++) {
        final col = centerCol + dx;
        final row = centerRow + dy;
        if (col < 0 || col >= meta.width || row < 0 || row >= meta.height) continue;
        final cx = meta.originX + (col + 0.5) * res;
        final cy = meta.originY + (row + 0.5) * res;
        final ddx = cx - worldX;
        final ddy = cy - worldY;
        if (ddx * ddx + ddy * ddy > radius * radius) continue;

        final key = row * meta.width + col;
        final hasPrev = _obstacleEdits.containsKey(key);
        final prev = hasPrev ? (_obstacleEdits[key] as int) : 0;
        if (hasPrev && prev == value) continue;

        _obstacleStrokeOldEdits[key] ??= prev;
        _obstacleEdits[key] = value;
        _obstacleStrokeNewEdits[key] = value;
        changed = true;
      }
    }
    if (changed && mounted) setState(() {});
  }

  Widget _buildOverlayLayers(MapMeta meta) {
    final toLatLng = _worldToLatLng(meta);
    return Consumer2<WsChannel, GlobalState>(
      builder: (context, wsChannel, globalState, _) {
        final layers = <Widget>[];

        if (globalState.isLayerVisible('localCostmap')) {
          layers.add(ValueListenableBuilder(
            valueListenable: wsChannel.localCostmap,
            builder: (_, cm, ___) => buildLocalCostMapOverlayLayer(
                  cm,
                  0.5,
                  toLatLng,
                  globalState.localCostmapMapStyle(),
                ),
          ));
        }
        if (_obstacleEdits.isNotEmpty) {
          layers.add(_buildObstacleEditLayer(meta, toLatLng));
        }

        if (!widget.editMode && globalState.isLayerVisible('globalPath')) {
          final pathColor = globalState.layerColorFor(
              'globalPath', const Color(0xFF2196F3));
          layers.add(ValueListenableBuilder<List<vm.Vector2>>(
            valueListenable: wsChannel.globalPath,
            builder: (_, path, __) => buildPathLayer(
              path.map((p) => worldToLatLng(meta, p.x, p.y)).toList(),
              pathColor,
            ),
          ));
        }

        if (!widget.editMode && globalState.isLayerVisible('localPath')) {
          final pathColor =
              globalState.layerColorFor('localPath', Colors.green);
          layers.add(ValueListenableBuilder<List<vm.Vector2>>(
            valueListenable: wsChannel.localPath,
            builder: (_, path, __) => buildPathLayer(
              path.map((p) => worldToLatLng(meta, p.x, p.y)).toList(),
              pathColor,
            ),
          ));
        }

        if (!widget.editMode && globalState.isLayerVisible('tracePath')) {
          final pathColor =
              globalState.layerColorFor('tracePath', Colors.yellow);
          layers.add(ValueListenableBuilder<List<vm.Vector2>>(
            valueListenable: wsChannel.tracePath,
            builder: (_, path, __) => buildPathLayer(
              path.map((p) => worldToLatLng(meta, p.x, p.y)).toList(),
              pathColor,
            ),
          ));
        }

        if (!widget.editMode && globalState.isLayerVisible('laser')) {
          final laserColor =
              globalState.layerColorFor('laser', Colors.red);
          final dotR = globalState.layerLaserDotRadius();
          layers.add(ValueListenableBuilder<Mode>(
            valueListenable: globalState.mode,
            builder: (_, mode, __) => ValueListenableBuilder(
              valueListenable: wsChannel.laserPointData,
              builder: (_, ___, ____) => buildLaserLayer(
                wsChannel,
                toLatLng,
                robotPoseOverride: mode == Mode.reloc ? _relocPose : null,
                color: laserColor,
                dotRadius: dotR,
              ),
            ),
          ));
        }
        if (globalState.isLayerVisible('pointCloud')) {
          layers.add(ValueListenableBuilder(
            valueListenable: wsChannel.pointCloud2Data,
            builder: (_, __, ___) => buildPointCloudLayer(wsChannel, toLatLng),
          ));
        }
        if (!widget.editMode &&
            globalState.isLayerVisible('robotFootprint')) {
          layers.add(ValueListenableBuilder<List<vm.Vector2>>(
            valueListenable: wsChannel.robotFootprint,
            builder: (_, __, ___) => buildRobotFootprintLayer(wsChannel, toLatLng),
          ));
        }
        if (globalState.isLayerVisible('topology')) {
          layers.add(ValueListenableBuilder(
            valueListenable: _topologyMap,
            builder: (_, topologyMap, ___) {
              final navPoints = topologyMap.points
                  .map((p) => _draggingNavPoints[p.name] ?? p)
                  .toList();
              return buildTopologyLineLayer(
                navPoints,
                topologyMap.routes,
                toLatLng,
                onNavPointTap: widget.onNavPointTap,
                onRouteTap: widget.onRouteTap,
                isEditMode: widget.editMode,
                enlargeNavPointMarkers: widget.enlargeNavPointMarkers,
                selectedNavPointName: widget.selectedNavPointName,
                selectedRoute: widget.selectedRoute,
                onNavPointChanged: widget.editMode
                    ? (updated) {
                        final base = _draggingNavPoints[updated.name] ?? updated;
                        final dragging = NavPoint(
                          name: updated.name,
                          x: base.x,
                          y: base.y,
                          theta: updated.theta,
                          type: base.type,
                        );
                        _draggingNavPoints[updated.name] = dragging;
                        _draggingNavPointsStart[updated.name] ??=
                            wsChannel.mapManager.getNavPoint(updated.name) ?? updated;
                        setState(() {});
                      }
                    : null,
                onNavPointMoveDelta: widget.editMode
                    ? (point, delta) {
                        final meta = _meta;
                        if (meta == null) return;
                        final camera = _mapController.camera;
                        final base = _draggingNavPoints[point.name] ?? point;
                        final currentLatLng = toLatLng(base.x, base.y);
                        final currentOffset =
                            camera.getOffsetFromOrigin(currentLatLng);
                        final newLatLng = camera.unprojectAtZoom(
                          currentOffset + delta + camera.pixelOrigin,
                        );
                        final world = latLngToWorld(meta, newLatLng);
                        final newX = world.x;
                        final newY = world.y;
                        final dragging = NavPoint(
                          name: point.name,
                          x: newX,
                          y: newY,
                          theta: base.theta,
                          type: base.type,
                        );
                        _draggingNavPoints[point.name] = dragging;
                        _draggingNavPointsStart[point.name] ??= point;
                        widget.onNavPointTap?.call(dragging);
                        setState(() {});
                      }
                    : null,
                onNavPointThetaEnd: widget.editMode
                    ? (p) {
                        final start = _draggingNavPointsStart[p.name];
                        final current = _draggingNavPoints[p.name] ?? p;
                        if (start != null) {
                          widget.onNavPointEditEnd?.call(start, current);
                        }
                        _draggingNavPoints.remove(p.name);
                        _draggingNavPointsStart.remove(p.name);
                        setState(() {});
                      }
                    : null,
                onNavPointMoveEnd: widget.editMode
                    ? (p) {
                        final start = _draggingNavPointsStart[p.name];
                        final current = _draggingNavPoints[p.name] ?? p;
                        if (start != null) {
                          widget.onNavPointEditEnd?.call(start, current);
                        }
                        _draggingNavPoints.remove(p.name);
                        _draggingNavPointsStart.remove(p.name);
                        setState(() {});
                      }
                    : null,
              );
            },
          ));
        }

        if(!widget.editMode) {

        layers.add(ValueListenableBuilder(
          valueListenable: wsChannel.robotPoseMap,
          builder: (_, __, ___) => ValueListenableBuilder(
            valueListenable: globalState.mode,
            builder: (_, mode, ___) {
              final isReloc = mode == Mode.reloc;
              if (isReloc) {
                _relocPose ??= wsChannel.robotPoseMap.value;
              } else {
                _relocPose = null;
              }
              return buildRobotMarkerLayer(
                wsChannel,
                toLatLng,
                poseOverride: isReloc ? _relocPose : null,
                isEditMode: isReloc,
                sizeScale: isReloc ? 1.5 : 1.0,
                onThetaChanged: isReloc
                    ? (theta) {
                        final current = _relocPose ?? wsChannel.robotPoseMap.value;
                        _relocPose = RobotPose(current.x, current.y, theta);
                        print('TileMapState _relocPose=$_relocPose');
                        setState(() {});
                      }
                    : null,
                onMoveDelta: isReloc
                    ? (delta) {
                        final meta = _meta;
                        if (meta == null) return;
                        final current = _relocPose ?? wsChannel.robotPoseMap.value;
                        final camera = _mapController.camera;
                        final currentLatLng = toLatLng(current.x, current.y);
                        final currentPx = camera.projectAtZoom(currentLatLng);
                        final newLatLng = camera.unprojectAtZoom(currentPx + delta);
                        final world = latLngToWorld(meta, newLatLng);
                        _relocPose = RobotPose(world.x, world.y, current.theta);
                        setState(() {});
                      }
                    : null,
              );
            },
          ),
        ));
        }

        return Stack(children: layers);
      },
    );
  }

  Widget _buildObstacleEditLayer(MapMeta meta, WorldToLatLngFn toLatLng) {
    final res = meta.resolution;
    final polygons = <Polygon>[];
    _obstacleEdits.forEach((key, value) {
      final col = key % meta.width;
      final row = key ~/ meta.width;
      final cx = meta.originX + col * res;
      final cy = meta.originY + row * res;
      final color = value > 0
          ? const Color(0xFF000000)
          : const Color(0xFFFFFFFF);
      polygons.add(Polygon(
        points: [
          toLatLng(cx, cy),
          toLatLng(cx + res, cy),
          toLatLng(cx + res, cy + res),
          toLatLng(cx, cy + res),
        ],
        color: color,
        borderColor: color,
        borderStrokeWidth: 0,
      ));
    });

    if (polygons.isEmpty) return const SizedBox.shrink();
    return PolygonLayer(polygons: polygons);
  }

  void moveToRobot() {
    if (_meta != null) {
      _snapCameraToRobot(zoom: 6.0);
    }
  }

  void zoomIn() {
    _mapController.move(_mapController.camera.center, _currentZoom + 0.5);
  }

  void zoomOut() {
    _mapController.move(_mapController.camera.center, _currentZoom - 0.5);
  }

  Future<void> reloadMeta() async {
    await _loadMetaByMapName();
  }


  RobotPose getRelocRobotPose() {
    return _relocPose ?? context.read<WsChannel>().robotPoseMap.value;
  }

  void flushDraggingNavPoints() {
    if (_draggingNavPoints.isEmpty) return;
    final wsChannel = context.read<WsChannel>();
    final mapManager = wsChannel.mapManager;
    _draggingNavPoints.forEach((name, navPoint) {
      mapManager.updateNavPoint(name, navPoint);
    });
    _draggingNavPoints.clear();
  }
}

