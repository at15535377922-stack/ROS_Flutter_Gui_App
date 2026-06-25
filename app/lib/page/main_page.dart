import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:ros_flutter_gui_app/display/tile_map.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/ws_channel.dart';
import 'package:ros_flutter_gui_app/basic/action_status.dart';
import 'package:ros_flutter_gui_app/basic/RobotPose.dart';
import 'package:ros_flutter_gui_app/page/map_edit_page.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/basic/topology_map.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';
import 'package:ros_flutter_gui_app/page/gamepad_widget.dart';
import 'package:ros_flutter_gui_app/page/camera_view.dart';
import 'package:ros_flutter_gui_app/basic/diagnostic_status.dart';
import 'package:ros_flutter_gui_app/page/diagnostic_page.dart';
import 'package:ros_flutter_gui_app/provider/diagnostic_manager.dart';
import 'package:ros_flutter_gui_app/language/l10n/gen/app_localizations.dart';
import 'package:ros_flutter_gui_app/page/setting_page.dart';
import 'package:ros_flutter_gui_app/page/ssh_quick_commands_page.dart';
import 'package:ros_flutter_gui_app/page/ssh_terminal_page.dart';
import 'package:ros_flutter_gui_app/page/ssh_widgets.dart';
import 'package:ros_flutter_gui_app/page/waypoint_nav_page.dart';
import 'package:ros_flutter_gui_app/page/mapping_page.dart';
import 'package:ros_flutter_gui_app/page/map_list_page.dart';

class MainFlamePage extends StatefulWidget {
  @override
  _MainFlamePageState createState() => _MainFlamePageState();
}

class _MainFlamePageState extends State<MainFlamePage> {
  final GlobalKey<TileMapState> _tileMapKey = GlobalKey<TileMapState>();
  bool showCamera = false;
  NavPoint? selectedNavPoint;
  TopologyRoute? _selectedRoute;
  RouteInfo? _editingRouteInfo;
  bool _isRecoveringConnection = false;
  bool _sshRailExpanded = false;

  // 地图点选导航
  double? _pickedX;
  double? _pickedY;
  double _pickedTheta = 0.0; // 角度（弧度）
  bool _isNavPickMode = false;
  final List<Map<String, double>> _navTrajectory = []; // 多点轨迹

  // 相机相关变量
  Offset camPosition = Offset(30, 10); // 初始位置
  bool isCamFullscreen = false; // 是否全屏
  Offset camPreviousPosition = Offset(30, 10); // 保存进入全屏前的位置
  late double camWidgetWidth;
  late double camWidgetHeight;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recoverConnectionIfNeeded();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<GlobalState>().loadLayerSettings();
      _setupDiagnosticListener();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      try {
        final httpChannel = context.read<HttpChannel>();
        final mapManager = context.read<WsChannel>().mapManager;
        final topo = await httpChannel.getTopologyMap();
        mapManager.updateTopologyMap(topo);
      } catch (_) {}
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        final screenSize = MediaQuery.of(context).size;
        camWidgetWidth = screenSize.width / 3.5;
        camWidgetHeight = camWidgetWidth / (globalSetting.imageWidth / globalSetting.imageHeight);
      }
    });
  }

  Future<void> _recoverConnectionIfNeeded() async {
    if (!mounted || _isRecoveringConnection) return;
    final wsChannel = context.read<WsChannel>();
    if (wsChannel.rosConnectState_ == Status.connected ||
        wsChannel.rosConnectState_ == Status.connecting) {
      return;
    }

    _isRecoveringConnection = true;
    try {
      final host = globalSetting.robotIp.trim();
      final port = int.tryParse(globalSetting.httpServerPort.trim()) ?? 8080;
      if (host.isEmpty) {
        _redirectToConnectPage();
        return;
      }

      String error = '';
      const maxAttempts = 4;
      for (int i = 0; i < maxAttempts; i++) {
        if (!mounted) return;
        error = await wsChannel.connectBackend(host, port);
        if (error.isEmpty) {
          return;
        }
        if (i < maxAttempts - 1) {
          await Future<void>.delayed(Duration(milliseconds: 350 * (i + 1)));
        }
      }

      if (!mounted) return;
      toastification.show(
        context: context,
        title: Text(AppLocalizations.of(context)!.init_error(error)),
        autoCloseDuration: const Duration(seconds: 4),
      );
      _redirectToConnectPage();
    } finally {
      _isRecoveringConnection = false;
    }
  }

  void _redirectToConnectPage() {
    if (!mounted) return;
    Navigator.pushNamedAndRemoveUntil(context, "/connect", (route) => false);
  }

  Widget _MapToolbarShell(
    ThemeData theme, {
    required Widget child,
    Color? backgroundColor,
  }) {
    final ColorScheme scheme = theme.colorScheme;
    return Material(
      elevation: 0,
      shadowColor: Colors.transparent,
      borderRadius: BorderRadius.circular(14),
      color: backgroundColor ?? scheme.surfaceContainerHigh.withOpacity(0.55),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Future<void> _reloadData() async {
    try {
      final httpChannel = context.read<HttpChannel>();
      final wsChannel = context.read<WsChannel>();
      final topo = await httpChannel.getTopologyMap();
      wsChannel.mapManager.updateTopologyMap(topo);
    } catch (_) {}
    _tileMapKey.currentState?.reloadMeta();
  }

  Future<bool> _pullLatestGuiSettingsForSsh(BuildContext context) async {
    try {
      final s = await HttpChannel().getGuiSettings();
      globalSetting.applyBackendGuiSettings(s);
      return true;
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$e'), duration: const Duration(seconds: 4)),
        );
      }
      return false;
    }
  }

  Future<bool> _ensureSshCredentialsInteractive(BuildContext context) async {
    if (globalSetting.sshCredentialsConfigured) return true;
    final l10n = AppLocalizations.of(context)!;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.ssh_required_title),
        content: Text(l10n.ssh_required_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.ssh_go_configure),
          ),
        ],
      ),
    );
    if (go != true || !context.mounted) return false;
    await ShowSshConfigSheet(context);
    return globalSetting.sshCredentialsConfigured;
  }

  Future<void> _openSSHQuickCommands(BuildContext context) async {
    if (!await _pullLatestGuiSettingsForSsh(context)) return;
    if (!context.mounted) return;
    if (!await _ensureSshCredentialsInteractive(context)) return;
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SSHQuickCommandsPage()),
    );
  }

  Future<void> _openSshTerminal(BuildContext context) async {
    if (!await _pullLatestGuiSettingsForSsh(context)) return;
    if (!context.mounted) return;
    if (!await _ensureSshCredentialsInteractive(context)) return;
    if (!context.mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const SshTerminalPage()),
    );
  }

  void _openLayerSettings(BuildContext context) {
    Navigator.pushNamed(
      context,
      '/setting',
      arguments: kSettingsRouteArgLayers,
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.pushNamed(context, '/setting');
  }

  // 设置诊断数据监听器
  void _setupDiagnosticListener() {
    context.read<WsChannel>().diagnosticManager.setOnNewErrorsWarnings(_onNewErrorsWarnings);
  }


  // 新错误/警告/失活回调
  void _onNewErrorsWarnings(List<Map<String, dynamic>> newErrorsWarnings) {
    for (var errorWarning in newErrorsWarnings) {
      final hardwareId = errorWarning['hardwareId'] as String;
      final componentName = errorWarning['componentName'] as String;
      final state = errorWarning['state'] as DiagnosticState;
      
      // 只对错误、警告和失活状态显示toast
      if (state.level == DiagnosticStatus.ERROR || 
          state.level == DiagnosticStatus.WARN || 
          state.level == DiagnosticStatus.STALE) {
        _showDiagnosticToast(hardwareId, componentName, state);
      }
    }
  }

  // 显示诊断toast通知
  void _showDiagnosticToast(String hardwareId, String componentName, DiagnosticState state) {
    if (!mounted) return;
    
    String levelText;
    Color levelColor;
    ToastificationType toastType;
    IconData iconData;
    
    switch (state.level) {
      case DiagnosticStatus.WARN:
        levelText = AppLocalizations.of(context)!.diagnostic_warning;
        levelColor = Colors.orange;
        toastType = ToastificationType.warning;
        iconData = Icons.warning;
        break;
      case DiagnosticStatus.ERROR:
        levelText = AppLocalizations.of(context)!.diagnostic_error;
        levelColor = Colors.red;
        toastType = ToastificationType.error;
        iconData = Icons.error;
        break;
      case DiagnosticStatus.STALE:
        levelText = AppLocalizations.of(context)!.diagnostic_stale;
        levelColor = Colors.grey;
        toastType = ToastificationType.info;
        iconData = Icons.schedule;
        break;
      default:
        return; // 其他状态不显示toast
    }
    
    final l10n = AppLocalizations.of(context)!;
    final hwId = hardwareId == 'unknown_hardware' ? l10n.unknown_hardware : hardwareId;
    final msg = state.message == 'data_stale' ? l10n.data_stale : state.message;
    toastification.show(
      context: context,
      type: toastType,
      title: Text(l10n.diagnostic_health(levelText, componentName)),
      description: Text(l10n.diagnostic_hardware(hwId, msg)),
      autoCloseDuration: const Duration(seconds: 5),
      icon: Icon(
        iconData,
        color: levelColor,
      ),
    );
  }

    @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    final globalState = Provider.of<GlobalState>(context, listen: true);
    return Scaffold(
          body: ValueListenableBuilder<Mode>(
            valueListenable: globalState.mode,
            builder: (context, mode, _) {
              return Stack(
                children: [
                  TileMap(
                    key: _tileMapKey,
                    onTap: () {
                      setState(() {
                        selectedNavPoint = null;
                        _selectedRoute = null;
                        _editingRouteInfo = null;
                      });
                    },
                    onTapWorld: _isNavPickMode
                        ? (wx, wy) {
                            setState(() {
                              _pickedX = wx;
                              _pickedY = wy;
                            });
                          }
                        : null,
                    onNavPointTap: (NavPoint? point) {
                      setState(() {
                        selectedNavPoint = point;
                        if (point != null) {
                          _selectedRoute = null;
                          _editingRouteInfo = null;
                          _showNavPointDialog(context, point);
                        }
                      });
                    },
                    selectedRoute: _selectedRoute,
                    onRouteTap: (route) {
                      setState(() {
                        _selectedRoute = route;
                        _editingRouteInfo = RouteInfo(controller: route.routeInfo.controller);
                        selectedNavPoint = null;
                      });
                    },
                    selectedNavPointName: selectedNavPoint?.name,
                    enableMapInteraction: mode != Mode.reloc,
                    followRobot: mode == Mode.robotFixedCenter,
                  ),
                  _buildTopMenuBar(context, theme),
                  _buildLeftToolbar(context, theme),
                  _buildRightToolbar(context, theme),
                  Positioned(
                    top: 60,
                    right: 5,
                    child: _buildSelectionPanel(theme),
                  ),
                  _buildBottomControls(context, theme),
                  if (_isNavPickMode) ...[
                    // 地图上的大头针标记层
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
                    _buildNavPickPanel(context, theme),
                  ],
                  _buildCameraWidget(context, theme),
                  _buildGamepadWidget(context, theme),
                  _buildMapLegend(context, theme),
                ],
              );
            },
          ),
        );
  }

  Widget _buildSelectionPanel(ThemeData theme) {
    final route = _selectedRoute;
    if (route != null) {
      final info = _editingRouteInfo ?? route.routeInfo;

      return Card(
        elevation: 3,
        shadowColor: Colors.black.withOpacity(0.08),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: 320,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        AppLocalizations.of(context)!.route_properties,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: AppLocalizations.of(context)!.close,
                      onPressed: () {
                        setState(() {
                          _selectedRoute = null;
                          _editingRouteInfo = null;
                        });
                      },
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(AppLocalizations.of(context)!.direction(route.fromPoint, route.toPoint)),
                const SizedBox(height: 12),
                TextFormField(
                  initialValue: info.controller,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(context)!.controller_readonly,
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildTopMenuBar(BuildContext context, ThemeData theme) {
    final Color chipBackgroundColor =
        theme.colorScheme.surfaceContainerHigh.withOpacity(0.55);
    return Positioned(
      left: 25,
      top: 2,
      child: Container(
        height: 50,
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              // 线速度显示
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: RawChip(
                  avatar: Icon(
                    const IconData(0xe606, fontFamily: "Speed"),
                    color: Colors.green[400],
                  ),
                  backgroundColor: chipBackgroundColor,
                  label: ValueListenableBuilder<RobotSpeed>(
                    valueListenable:
                        Provider.of<WsChannel>(context, listen: true)
                            .robotSpeed_,
                    builder: (context, speed, child) {
                      return Text('${(speed.vx).toStringAsFixed(2)} m/s');
                    },
                  ),
                ),
              ),
              // 角速度显示
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: RawChip(
                  avatar: const Icon(IconData(0xe680, fontFamily: "Speed")),
                  backgroundColor: chipBackgroundColor,
                  label: ValueListenableBuilder<RobotSpeed>(
                    valueListenable:
                        Provider.of<WsChannel>(context, listen: true)
                            .robotSpeed_,
                    builder: (context, speed, child) {
                      return Text(
                          '${rad2deg(speed.vw).toStringAsFixed(2)} deg/s');
                    },
                  ),
                ),
              ),
              // 电池电量显示
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: ValueListenableBuilder<double>(
                  valueListenable:
                      Provider.of<WsChannel>(context, listen: false)
                          .battery_,
                  builder: (context, battery, child) {
                    final bool lowBattery = battery > 0 && battery <= 15;
                    return RawChip(
                      avatar: Icon(
                        const IconData(0xe995, fontFamily: "Battery"),
                        color: lowBattery ? Colors.red : Colors.amber[300],
                      ),
                      backgroundColor: lowBattery
                          ? Colors.red.withOpacity(0.18)
                          : chipBackgroundColor,
                      label: Text(
                        battery == 0
                            ? '-- %'
                            : '${battery.toStringAsFixed(0)} %',
                        style: TextStyle(
                          color: lowBattery ? Colors.red : null,
                          fontWeight: lowBattery ? FontWeight.bold : null,
                        ),
                      ),
                    );
                  },
                ),
              ),
              // 导航状态显示
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: RawChip(
                  avatar: const Icon(
                    Icons.navigation,
                    color: Colors.green,
                    size: 16,
                  ),
                  backgroundColor: chipBackgroundColor,
                  label: ValueListenableBuilder<ActionStatus>(
                    valueListenable:
                        Provider.of<WsChannel>(context, listen: true)
                            .navStatus_,
                    builder: (context, navStatus, child) {
                      return Text('${navStatus.toString()}');
                    },
                  ),
                ),
              ),
              // 诊断状态显示（监听 DiagnosticManager，而非仅 Consumer<WsChannel>）
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4.0),
                child: Builder(
                  builder: (BuildContext context) {
                    final WsChannel ws =
                        Provider.of<WsChannel>(context, listen: false);
                    return ListenableBuilder(
                      listenable: ws.diagnosticManager,
                      builder: (BuildContext context, Widget? child) {
                        final Map<int, int> statusCounts =
                            ws.diagnosticManager.getStatusCounts();
                        final int errorCount =
                            statusCounts[DiagnosticStatus.ERROR] ?? 0;
                        final int warnCount =
                            statusCounts[DiagnosticStatus.WARN] ?? 0;
                        final AppLocalizations l10n =
                            AppLocalizations.of(context)!;

                        Color chipColor = Colors.green;
                        IconData chipIcon = Icons.check_circle;
                        String chipText = l10n.diagnostic_normal;

                        if (errorCount > 0) {
                          chipColor = Colors.red;
                          chipIcon = Icons.error;
                          chipText =
                              l10n.error_count(errorCount.toString());
                        } else if (warnCount > 0) {
                          chipColor = Colors.orange;
                          chipIcon = Icons.warning;
                          chipText =
                              l10n.warn_count(warnCount.toString());
                        }

                        return RawChip(
                          avatar: Icon(
                            chipIcon,
                            color: chipColor,
                            size: 16,
                          ),
                          label: Text(chipText),
                          backgroundColor: chipBackgroundColor,
                          elevation: 0,
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (BuildContext context) =>
                                    const DiagnosticPage(),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLeftToolbar(BuildContext context, ThemeData theme) {
    return Positioned(
      left: 10,
      top: 60,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 280),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.all(10),
              ),
              icon: Icon(Icons.layers_outlined, color: theme.iconTheme.color),
              tooltip: AppLocalizations.of(context)!.layers,
              onPressed: () => _openLayerSettings(context),
            ),
          ),
          const SizedBox(height: 6),
          ValueListenableBuilder(
            valueListenable: Provider.of<GlobalState>(context, listen: false).mode,
            builder: (context, mode, _) {
              return _MapToolbarShell(
                theme,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      style: IconButton.styleFrom(
                        minimumSize: const Size(44, 44),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        padding: const EdgeInsets.all(10),
                      ),
                      onPressed: () {
                        var globalState =
                            Provider.of<GlobalState>(context, listen: false);
                        globalState.mode.value =
                            mode == Mode.reloc ? Mode.normal : Mode.reloc;
                      },
                      icon: Icon(
                        const IconData(0xe60f, fontFamily: "Reloc"),
                        color: mode == Mode.reloc
                            ? Colors.green
                            : theme.iconTheme.color,
                      ),
                    ),
                    if (mode == Mode.reloc) ...[
                      IconButton(
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.all(10),
                        ),
                        onPressed: () {
                          Provider.of<GlobalState>(context, listen: false)
                              .mode
                              .value = Mode.normal;
                          Provider.of<WsChannel>(context, listen: false)
                              .sendRelocPose(
                            _tileMapKey.currentState?.getRelocRobotPose() ??
                                RobotPose.zero(),
                          );
                        },
                        icon: Icon(Icons.check, color: Colors.green),
                      ),
                      IconButton(
                        style: IconButton.styleFrom(
                          minimumSize: const Size(44, 44),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          padding: const EdgeInsets.all(10),
                        ),
                        onPressed: () {
                          Provider.of<GlobalState>(context, listen: false)
                              .mode
                              .value = Mode.normal;
                        },
                        icon: Icon(Icons.close, color: Colors.red),
                      ),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.all(10),
              ),
              icon: Icon(
                Icons.photo_camera_outlined,
                color: showCamera ? Colors.green : theme.iconTheme.color,
              ),
              onPressed: () {
                setState(() {
                  showCamera = !showCamera;
                });
              },
              tooltip: AppLocalizations.of(context)!.camera_image,
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: IconButton.styleFrom(
                minimumSize: const Size(44, 44),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                padding: const EdgeInsets.all(10),
              ),
              icon: Icon(
                const IconData(0xea45, fontFamily: "GamePad"),
                color: Provider.of<GlobalState>(context, listen: false)
                        .isManualCtrl
                        .value
                    ? Colors.green
                    : theme.iconTheme.color,
              ),
              onPressed: () {
                if (Provider.of<GlobalState>(context, listen: false)
                    .isManualCtrl
                    .value) {
                  Provider.of<GlobalState>(context, listen: false)
                      .isManualCtrl
                      .value = false;
                  Provider.of<WsChannel>(context, listen: false)
                      .stopMunalCtrl();
                  setState(() {});
                } else {
                  Provider.of<GlobalState>(context, listen: false)
                      .isManualCtrl
                      .value = true;
                  Provider.of<WsChannel>(context, listen: false)
                      .startMunalCtrl();
                  setState(() {});
                }
              },
            ),
          ),
        ],
      ),
    ),
    );
  }

  void _showNavPointDialog(BuildContext context, NavPoint point) {
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
            Text(AppLocalizations.of(context)!.nav_point_info),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue[50],
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Colors.blue[200]!),
                ),
                child: Row(
                  children: [
                    Icon(Icons.label, color: Colors.blue[700], size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            point.name,
                            style: theme.textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: Colors.blue[800],
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: _getTypeColor(point.type),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _getTypeText(point.type),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _buildInfoSection(ctx, theme, AppLocalizations.of(context)!.position_coords, Icons.gps_fixed, [
                _buildInfoRow(AppLocalizations.of(context)!.coord_x, '${point.x.toStringAsFixed(2)} m'),
                _buildInfoRow(AppLocalizations.of(context)!.coord_y, '${point.y.toStringAsFixed(2)} m'),
                _buildInfoRow(AppLocalizations.of(context)!.heading, '${(point.theta * 180 / 3.14159).toStringAsFixed(1)}°'),
              ]),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(AppLocalizations.of(context)!.cancel),
          ),
          FilledButton.icon(
            onPressed: () {
              if (Provider.of<GlobalState>(context, listen: false).isManualCtrl.value) {
                toastification.show(
                  context: context,
                  title: Text(AppLocalizations.of(context)!.stop_manual_first),
                  autoCloseDuration: const Duration(seconds: 3),
                );
                return;
              }
              Provider.of<WsChannel>(context, listen: false).sendNavigationGoal(
                RobotPose(point.x, point.y, point.theta),
              );
              toastification.show(
                context: context,
                title: Text(AppLocalizations.of(context)!.nav_goal_sent(point.name)),
                autoCloseDuration: const Duration(seconds: 3),
              );
              Navigator.of(ctx).pop();
              setState(() => selectedNavPoint = null);
            },
            icon: const Icon(Icons.navigation, size: 20),
            label: Text(AppLocalizations.of(context)!.send_nav_goal),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.blue[600],
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightToolbar(BuildContext context, ThemeData theme) {
    final AppLocalizations l10n = AppLocalizations.of(context)!;
    final ButtonStyle tbStyle = IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.all(10),
    );
    return Positioned(
      right: 10,
      top: 40,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(Icons.settings, color: theme.iconTheme.color),
              tooltip: l10n.setting,
              onPressed: () => _openSettings(context),
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(Icons.add_chart, color: theme.iconTheme.color),
              tooltip: '建图',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MappingPage()),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(Icons.map_outlined, color: theme.iconTheme.color),
              tooltip: '地图列表',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MapListPage()),
              ),
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(
                Icons.route,
                color: _isNavPickMode
                    ? Colors.orange
                    : theme.iconTheme.color,
              ),
              tooltip: _isNavPickMode ? '退出地图选点导航' : '地图选点导航',
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
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              icon: Icon(
                Icons.edit_document,
                color: (Provider.of<GlobalState>(context, listen: false)
                            .mode
                            .value ==
                        Mode.mapEdit)
                    ? Colors.orange
                    : theme.iconTheme.color,
              ),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => MapEditPage(
                      onExit: () {
                        _reloadData();
                      },
                    ),
                  ),
                );
              },
              tooltip: l10n.map_edit,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.centerRight,
                child: _sshRailExpanded
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _MapToolbarShell(
                            theme,
                            child: IconButton(
                              style: tbStyle,
                              onPressed: () async {
                                setState(() => _sshRailExpanded = false);
                                await _openSSHQuickCommands(context);
                              },
                              icon: Icon(Icons.bolt_rounded,
                                  color: theme.iconTheme.color),
                              tooltip: l10n.ssh_quick_commands_tooltip,
                            ),
                          ),
                          const SizedBox(width: 6),
                          _MapToolbarShell(
                            theme,
                            child: IconButton(
                              style: tbStyle,
                              onPressed: () async {
                                setState(() => _sshRailExpanded = false);
                                await _openSshTerminal(context);
                              },
                              icon: Icon(Icons.terminal_rounded,
                                  color: theme.iconTheme.color),
                              tooltip: l10n.ssh_terminal_tooltip,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                      )
                    : const SizedBox(height: 44),
              ),
              _MapToolbarShell(
                theme,
                child: IconButton(
                  style: tbStyle,
                  onPressed: () {
                    setState(() => _sshRailExpanded = !_sshRailExpanded);
                  },
                  icon: Icon(
                    _sshRailExpanded
                        ? Icons.keyboard_arrow_right_rounded
                        : Icons.hub_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  tooltip: l10n.ssh_remote_section,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              onPressed: () {
                _tileMapKey.currentState?.zoomIn();
              },
              icon: Icon(Icons.zoom_in_rounded, color: theme.iconTheme.color),
              tooltip: l10n.zoom_in,
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              onPressed: () {
                _tileMapKey.currentState?.zoomOut();
              },
              icon: Icon(Icons.zoom_out_rounded, color: theme.iconTheme.color),
              tooltip: l10n.zoom_out,
            ),
          ),
          const SizedBox(height: 6),
          _MapToolbarShell(
            theme,
            child: IconButton(
              style: tbStyle,
              onPressed: () {
                var globalState =
                    Provider.of<GlobalState>(context, listen: false);
                if (globalState.mode.value == Mode.robotFixedCenter) {
                  globalState.mode.value = Mode.normal;
                } else {
                  globalState.mode.value = Mode.robotFixedCenter;
                }
                setState(() {});
              },
              icon: Icon(
                Icons.location_searching_rounded,
                color:
                    Provider.of<GlobalState>(context, listen: false).mode.value ==
                            Mode.robotFixedCenter
                        ? Colors.green
                        : theme.iconTheme.color,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(BuildContext context, ThemeData theme) {
    return Positioned(
      left: 5,
      bottom: 10,
      child: Consumer<GlobalState>(
        builder: (context, globalState, child) {
          return Visibility(
            visible: !globalState.isManualCtrl.value,
            child: Row(
              children: [
                // 停止导航按钮
                Consumer<WsChannel>(
                  builder: (context, wsChannel, child) {
                    return ValueListenableBuilder<ActionStatus>(
                      valueListenable: wsChannel.navStatus_,
                      builder: (context, navStatus, child) {
                        return Visibility(
                          visible: navStatus == ActionStatus.executing ||
                              navStatus == ActionStatus.accepted,
                          child: _MapToolbarShell(
                            theme,
                            backgroundColor: Colors.blue,
                            child: SizedBox(
                              width: 50,
                              height: 50,
                              child: IconButton(
                                style: IconButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                ),
                                icon: const Icon(
                                  Icons.stop_circle_rounded,
                                  size: 30,
                                  color: Colors.white,
                                ),
                                onPressed: () {
                                  Provider.of<WsChannel>(context,
                                          listen: false)
                                      .sendCancelNav();
                                  toastification.show(
                                    context: context,
                                    title: Text(AppLocalizations.of(context)!.nav_stopped),
                                    autoCloseDuration: const Duration(seconds: 3),
                                  );
                                },
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── 地图点选导航浮层 ──────────────────────────────────────────────
  Widget _buildNavPickPanel(BuildContext context, ThemeData theme) {
    final hasPoint = _pickedX != null && _pickedY != null;
    final thetaDeg = _pickedTheta * 180.0 / 3.141592653589793;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: Card(
            elevation: 8,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题栏
                  Row(
                    children: [
                      const Icon(Icons.route, color: Colors.orange, size: 20),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '地图选点导航',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                        ),
                      ),
                      // 提示
                      Text(
                        hasPoint ? '点击地图可重新选点' : '请在地图上点击选择目标点',
                        style: TextStyle(color: Colors.grey[600], fontSize: 12),
                      ),
                      const SizedBox(width: 8),
                      // 关闭
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
                    // 坐标显示行
                    Row(
                      children: [
                        _coordChip('X', _pickedX!.toStringAsFixed(3), Colors.blue),
                        const SizedBox(width: 8),
                        _coordChip('Y', _pickedY!.toStringAsFixed(3), Colors.green),
                        const SizedBox(width: 8),
                        // 朝向滑块
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '朝向: ${thetaDeg.toStringAsFixed(0)}°',
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                              Slider(
                                value: _pickedTheta,
                                min: -3.141592653589793,
                                max: 3.141592653589793,
                                divisions: 72,
                                onChanged: (v) => setState(() => _pickedTheta = v),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    // 控制按钮行
                    Row(
                      children: [
                        // 加入轨迹
                        Expanded(
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.add_location_alt, size: 16),
                            label: Text('加入轨迹 (${_navTrajectory.length})'),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.purple,
                              side: const BorderSide(color: Colors.purple),
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
                                title: Text('已加入轨迹，共 ${_navTrajectory.length} 个点'),
                                autoCloseDuration: const Duration(seconds: 2),
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 直接导航
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.navigation, size: 16),
                            label: const Text('立即导航'),
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.blue,
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            onPressed: () => _sendPickedNavGoal(),
                          ),
                        ),
                      ],
                    ),
                    // 轨迹列表（有轨迹时显示）
                    if (_navTrajectory.isNotEmpty) ...[
                      const Divider(height: 12),
                      Row(
                        children: [
                          const Icon(Icons.linear_scale, size: 16, color: Colors.purple),
                          const SizedBox(width: 6),
                          Text(
                            '轨迹路径 (${_navTrajectory.length} 个点)',
                            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.purple),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            icon: const Icon(Icons.delete_sweep, size: 14),
                            label: const Text('清空', style: TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(foregroundColor: Colors.red, padding: EdgeInsets.zero),
                            onPressed: () => setState(() => _navTrajectory.clear()),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 36,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _navTrajectory.length,
                          separatorBuilder: (_, __) => const Icon(Icons.arrow_forward, size: 14, color: Colors.grey),
                          itemBuilder: (_, i) {
                            final p = _navTrajectory[i];
                            return GestureDetector(
                              onLongPress: () {
                                setState(() => _navTrajectory.removeAt(i));
                              },
                              child: Chip(
                                label: Text(
                                  'P${i + 1}(${p['x']!.toStringAsFixed(1)},${p['y']!.toStringAsFixed(1)})',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                backgroundColor: Colors.purple[50],
                                deleteIcon: const Icon(Icons.close, size: 12),
                                onDeleted: () => setState(() => _navTrajectory.removeAt(i)),
                                padding: EdgeInsets.zero,
                                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      // 按顺序执行轨迹
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.play_arrow, size: 16),
                          label: Text('按顺序执行 ${_navTrajectory.length} 个导航点'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.purple,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          ),
                          onPressed: () => _executeTrajectory(),
                        ),
                      ),
                    ],
                  ] else ...[
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.touch_app, color: Colors.grey[400], size: 28),
                        const SizedBox(width: 8),
                        Text(
                          '点击上方地图任意位置选择目标点',
                          style: TextStyle(color: Colors.grey[500], fontSize: 13),
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
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.bold)),
          Text(value, style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Future<void> _sendPickedNavGoal() async {
    if (_pickedX == null || _pickedY == null) return;
    final httpChannel = context.read<HttpChannel>();
    try {
      final resp = await httpChannel.navigateToWaypoint(
        name: 'map_pick',
        x: _pickedX!,
        y: _pickedY!,
        theta: _pickedTheta,
      );
      if (!mounted) return;
      toastification.show(
        context: context,
        type: resp ? ToastificationType.info : ToastificationType.error,
        title: Text(resp
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
    final httpChannel = context.read<HttpChannel>();
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
        await httpChannel.navigateToWaypoint(
          name: 'traj_${i + 1}',
          x: p['x']!,
          y: p['y']!,
          theta: p['theta']!,
        );
        // 等待到达（轮询状态）
        for (int wait = 0; wait < 60; wait++) {
          await Future.delayed(const Duration(seconds: 1));
          if (!mounted) return;
          final status = await httpChannel.getNavStatus();
          if (status == 'succeeded' || status == 'idle') break;
          if (status == 'failed') {
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

  Widget _buildInfoSection(BuildContext context, ThemeData theme, String title, IconData icon, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: Colors.grey[600], size: 18),
            const SizedBox(width: 8),
            Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: Colors.grey[700],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[50],
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey[200]!),
          ),
          child: Column(
            children: children,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label, 
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Colors.grey[600],
            ),
          ),
          Text(
            value, 
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: Colors.grey[800],
            ),
          ),
        ],
      ),
    );
  }


  Color _getTypeColor(NavPointType type) {
    switch (type) {
      case NavPointType.navGoal:
        return Colors.blue[600]!;
      case NavPointType.chargeStation:
        return Colors.green[600]!;
    }
  }

  String _getTypeText(NavPointType type) {
    switch (type) {
      case NavPointType.navGoal:
        return AppLocalizations.of(context)!.nav_goal;
      case NavPointType.chargeStation:
        return AppLocalizations.of(context)!.charge_station;
    }
  }
  
  // 构建相机显示组件
  Widget _buildCameraWidget(BuildContext context, ThemeData theme) {
    if (!showCamera) return const SizedBox.shrink();
    
    final screenSize = MediaQuery.of(context).size;
    
    return Positioned(
      left: camPosition.dx,
      top: camPosition.dy,
      child: GestureDetector(
        onPanUpdate: (details) {
          if (!isCamFullscreen) {
            setState(() {
              double newX = camPosition.dx + details.delta.dx;
              double newY = camPosition.dy + details.delta.dy;
              // 限制位置在屏幕范围内
              newX = newX.clamp(0.0, screenSize.width - camWidgetWidth);
              newY = newY.clamp(0.0, screenSize.height - camWidgetHeight);
              camPosition = Offset(newX, newY);
            });
          }
        },
        child: Container(
          child: Stack(
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  // 在非全屏状态下，获取屏幕宽高
                  double containerWidth = isCamFullscreen
                      ? screenSize.width
                      : camWidgetWidth;
                  double containerHeight = isCamFullscreen
                      ? screenSize.height
                      : camWidgetHeight;

                  return CameraView(
                    width: containerWidth,
                    height: containerHeight,
                  );
                },
              ),
              Positioned(
                right: 0,
                top: 0,
                child: IconButton(
                  icon: Icon(
                    isCamFullscreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    color: Colors.black,
                  ),
                  constraints: BoxConstraints(), // 移除按钮的默认大小约束，变得更加紧凑
                  onPressed: () {
                    setState(() {
                      isCamFullscreen = !isCamFullscreen;
                      if (isCamFullscreen) {
                        // 进入全屏时，保存当前位置，并将位置设为 (0, 0)
                        camPreviousPosition = camPosition;
                        camPosition = Offset(0, 0);
                      } else {
                        // 退出全屏时，恢复之前的位置
                        camPosition = camPreviousPosition;
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildGamepadWidget(BuildContext context, ThemeData theme) {
    return Positioned.fill(
      child: GamepadWidget(),
    );
  }

  // 构建地图图例组件
  Widget _buildMapLegend(BuildContext context, ThemeData theme) {
    final AppLocalizations? l10n = AppLocalizations.of(context);
    final double maxLegendWidth =
        MediaQuery.sizeOf(context).width * 0.62;
    return Positioned(
      right: 30,
      top: 5,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxLegendWidth),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCompactLegendItem(
                l10n?.legend_free ?? 'Free',
                _getFreeAreaColor(),
              ),
              const SizedBox(width: 12),
              _buildCompactLegendItem(
                l10n?.legend_occupied ?? 'Occupied',
                _getOccupiedAreaColor(),
              ),
              const SizedBox(width: 12),
              _buildCompactLegendItem(
                l10n?.legend_unknown ?? 'Unknown',
                _getUnknownAreaColor(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // 构建精简图例项目
  Widget _buildCompactLegendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
            border: Border.all(
              color: Colors.grey.shade400,
              width: 0.5,
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 7,
            fontWeight: FontWeight.w500,
            color: Colors.grey.shade700,
          ),
        ),
      ],
    );
  }

  Color _getFreeAreaColor() => globalSetting.mapTileFreeColor;

  Color _getOccupiedAreaColor() => globalSetting.mapTileOccColor;

  Color _getUnknownAreaColor() => globalSetting.mapTileUnknownColor;

  @override
  void dispose() {
    super.dispose();
  }
}

// ── 地图选点标记层 ─────────────────────────────────────────────────────────────
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

    // 1. 画轨迹连线 + 轨迹点
    if (trajectory.isNotEmpty) {
      final linePaint = Paint()
        ..color = Colors.purple.withValues(alpha: 0.7)
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final List<Offset> trajOffsets = [];
      for (final p in trajectory) {
        final off = state.worldToScreen(p['x']!, p['y']!);
        if (off != null) trajOffsets.add(off);
      }

      // 连线
      for (int i = 0; i < trajOffsets.length - 1; i++) {
        canvas.drawLine(trajOffsets[i], trajOffsets[i + 1], linePaint);
      }

      // 轨迹点（小圆圈 + 序号）
      for (int i = 0; i < trajOffsets.length; i++) {
        final off = trajOffsets[i];
        canvas.drawCircle(
          off,
          9,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          off,
          9,
          Paint()
            ..color = Colors.purple
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
        // 序号文字
        final tp = TextPainter(
          text: TextSpan(
            text: '${i + 1}',
            style: const TextStyle(
              color: Colors.purple,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, off - Offset(tp.width / 2, tp.height / 2));
      }
    }

    // 2. 画当前选点（大头针效果）
    if (pickedX != null && pickedY != null) {
      final off = state.worldToScreen(pickedX!, pickedY!);
      if (off != null) {
        _drawPin(canvas, off, pickedTheta);
      }
    }
  }

  void _drawPin(Canvas canvas, Offset center, double theta) {
    const pinR = 14.0;

    // 方向箭头：theta 是 ROS yaw（逆时针为正，x 轴朝右为 0）
    // 屏幕坐标系 y 轴朝下，所以 screenDx = cos(theta), screenDy = -sin(theta)
    final dx = pinR * 2.0 * math.cos(theta);
    final dy = pinR * 2.0 * (-math.sin(theta));
    final arrowTip = center + Offset(dx, dy);

    canvas.drawLine(
      center,
      arrowTip,
      Paint()
        ..color = Colors.blue.shade700
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    // 箭头头部小三角
    _drawArrowHead(canvas, center, arrowTip, Colors.blue.shade700);

    // 外圈（白色描边）
    canvas.drawCircle(
      center,
      pinR + 2,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    // 填充圆
    canvas.drawCircle(
      center,
      pinR,
      Paint()
        ..color = Colors.blue.shade600
        ..style = PaintingStyle.fill,
    );
    // 内圆（空心）
    canvas.drawCircle(
      center,
      pinR * 0.45,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    // 脉冲外圈（半透明）
    canvas.drawCircle(
      center,
      pinR + 7,
      Paint()
        ..color = Colors.blue.withValues(alpha: 0.25)
        ..style = PaintingStyle.fill,
    );
  }

  void _drawArrowHead(Canvas canvas, Offset from, Offset to, Color color) {
    final dir = (to - from);
    final len = dir.distance;
    if (len < 1) return;
    final unit = dir / len;
    final perp = Offset(-unit.dy, unit.dx);
    const headLen = 8.0;
    const headWidth = 5.0;
    final p1 = to - unit * headLen + perp * headWidth;
    final p2 = to - unit * headLen - perp * headWidth;
    final path = Path()
      ..moveTo(to.dx, to.dy)
      ..lineTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = color..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(_NavPickPainter oldDelegate) =>
      oldDelegate.pickedX != pickedX ||
      oldDelegate.pickedY != pickedY ||
      oldDelegate.pickedTheta != pickedTheta ||
      oldDelegate.trajectory.length != trajectory.length;
}
