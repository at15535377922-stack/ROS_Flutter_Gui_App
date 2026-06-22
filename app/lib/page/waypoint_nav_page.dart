import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/provider/navigation_manager.dart';
import 'package:ros_flutter_gui_app/provider/global_state.dart';
import 'dart:math' as math;

class WaypointNavPage extends StatefulWidget {
  const WaypointNavPage({super.key});

  @override
  State<WaypointNavPage> createState() => _WaypointNavPageState();
}

class _WaypointNavPageState extends State<WaypointNavPage> {
  late NavigationManager _navManager;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navManager = NavigationManager(context.read<HttpChannel>());
      _navManager.addListener(() {
        if (mounted) setState(() {});
      });
      _navManager.loadWaypoints();
    });
  }

  @override
  void dispose() {
    _navManager.dispose();
    super.dispose();
  }

  Color _statusColor(WaypointNavStatus status) {
    switch (status) {
      case WaypointNavStatus.navigating:
        return Colors.blue;
      case WaypointNavStatus.succeeded:
        return Colors.green;
      case WaypointNavStatus.failed:
        return Colors.red;
      case WaypointNavStatus.cancelling:
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  String _statusText(WaypointNavStatus status) {
    switch (status) {
      case WaypointNavStatus.idle:
        return '空闲';
      case WaypointNavStatus.navigating:
        return '导航中';
      case WaypointNavStatus.succeeded:
        return '已到达';
      case WaypointNavStatus.failed:
        return '导航失败';
      case WaypointNavStatus.cancelling:
        return '取消中';
      default:
        return '未知';
    }
  }

  IconData _statusIcon(WaypointNavStatus status) {
    switch (status) {
      case WaypointNavStatus.navigating:
        return Icons.navigation;
      case WaypointNavStatus.succeeded:
        return Icons.check_circle;
      case WaypointNavStatus.failed:
        return Icons.error;
      case WaypointNavStatus.cancelling:
        return Icons.cancel;
      default:
        return Icons.radio_button_unchecked;
    }
  }

  Future<void> _sendNavigation(NavPoint point) async {
    final globalState = context.read<GlobalState>();
    if (globalState.isManualCtrl.value) {
      toastification.show(
        context: context,
        type: ToastificationType.warning,
        title: const Text('请先关闭手动控制模式'),
        autoCloseDuration: const Duration(seconds: 3),
      );
      return;
    }

    final ok = await _navManager.navigateTo(point);
    if (!mounted) return;
    if (ok) {
      toastification.show(
        context: context,
        type: ToastificationType.info,
        title: Text('正在导航至: ${point.name}'),
        autoCloseDuration: const Duration(seconds: 3),
      );
    } else {
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('导航请求失败: ${_navManager.errorMessage}'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _cancelNavigation() async {
    final ok = await _navManager.cancelNavigation();
    if (!mounted) return;
    if (ok) {
      toastification.show(
        context: context,
        type: ToastificationType.warning,
        title: const Text('已发送取消导航请求'),
        autoCloseDuration: const Duration(seconds: 3),
      );
    }
  }

  Future<void> _showAddEditDialog({NavPoint? existing}) async {
    final nameCtrl =
        TextEditingController(text: existing?.name ?? '');
    final xCtrl = TextEditingController(
        text: existing?.x.toStringAsFixed(3) ?? '');
    final yCtrl = TextEditingController(
        text: existing?.y.toStringAsFixed(3) ?? '');
    final thetaCtrl = TextEditingController(
        text: existing != null
            ? (existing.theta * 180.0 / math.pi).toStringAsFixed(1)
            : '');

    final isEdit = existing != null;
    final formKey = GlobalKey<FormState>();

    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(isEdit ? Icons.edit_location : Icons.add_location,
                color: Colors.blue[700]),
            const SizedBox(width: 8),
            Text(isEdit ? '编辑导航点' : '添加导航点'),
          ],
        ),
        content: SizedBox(
          width: 320,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '名称',
                    prefixIcon: Icon(Icons.label),
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? '名称不能为空' : null,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: xCtrl,
                        decoration: const InputDecoration(
                          labelText: 'X (m)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        validator: (v) =>
                            double.tryParse(v ?? '') == null ? '请输入数字' : null,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextFormField(
                        controller: yCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Y (m)',
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        validator: (v) =>
                            double.tryParse(v ?? '') == null ? '请输入数字' : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: thetaCtrl,
                  decoration: const InputDecoration(
                    labelText: '朝向角度 (°)',
                    prefixIcon: Icon(Icons.rotate_right),
                    border: OutlineInputBorder(),
                    hintText: '0 ~ 360',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true, signed: true),
                  validator: (v) =>
                      double.tryParse(v ?? '') == null ? '请输入数字' : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: Text(isEdit ? '保存' : '添加'),
          ),
        ],
      ),
    );

    if (result != true || !mounted) return;

    final thetaDeg = double.parse(thetaCtrl.text);
    final point = NavPoint(
      name: nameCtrl.text.trim(),
      x: double.parse(xCtrl.text),
      y: double.parse(yCtrl.text),
      theta: thetaDeg * math.pi / 180.0,
      type: existing?.type ?? NavPointType.navGoal,
    );

    final ok = await _navManager.addOrUpdateWaypoint(point);
    if (!mounted) return;
    toastification.show(
      context: context,
      type: ok ? ToastificationType.success : ToastificationType.error,
      title: Text(ok ? '已${isEdit ? "更新" : "添加"}导航点: ${point.name}' : '保存失败'),
      autoCloseDuration: const Duration(seconds: 3),
    );
  }

  Future<void> _deleteWaypoint(NavPoint point) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除导航点「${point.name}」吗？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    final ok = await _navManager.removeWaypoint(point.name);
    if (!mounted) return;
    toastification.show(
      context: context,
      type: ok ? ToastificationType.success : ToastificationType.error,
      title: Text(ok ? '已删除: ${point.name}' : '删除失败'),
      autoCloseDuration: const Duration(seconds: 3),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('定点导航'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新导航点',
            onPressed: _navManager.loadWaypoints,
          ),
          IconButton(
            icon: const Icon(Icons.add_location_alt),
            tooltip: '手动添加导航点',
            onPressed: () => _showAddEditDialog(),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── 状态横幅 ──────────────────────────────────
          _buildStatusBanner(theme),
          // ── 导航点列表 ────────────────────────────────
          Expanded(child: _buildWaypointList(theme)),
        ],
      ),
    );
  }

  Widget _buildStatusBanner(ThemeData theme) {
    final status = _navManager.navStatus;
    final color = _statusColor(status);
    final icon = _statusIcon(status);
    final text = _statusText(status);
    final active = _navManager.activeWaypoint;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: color.withOpacity(0.12),
      child: Row(
        children: [
          Icon(icon, color: color, size: 22),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '导航状态: $text',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: color, fontWeight: FontWeight.bold),
                ),
                if (active != null)
                  Text(
                    '目标: ${active.name}  (${active.x.toStringAsFixed(2)}, ${active.y.toStringAsFixed(2)})',
                    style: theme.textTheme.bodySmall,
                  ),
              ],
            ),
          ),
          if (_navManager.isNavigating)
            FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.red[50],
                foregroundColor: Colors.red[700],
              ),
              icon: const Icon(Icons.stop, size: 18),
              label: const Text('取消'),
              onPressed: _cancelNavigation,
            ),
        ],
      ),
    );
  }

  Widget _buildWaypointList(ThemeData theme) {
    if (_navManager.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_navManager.waypoints.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text('暂无导航点', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey)),
            const SizedBox(height: 8),
            Text('可在地图编辑页面添加，或点击右上角手动添加',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: _navManager.waypoints.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (ctx, i) {
        final point = _navManager.waypoints[i];
        final isActive = _navManager.activeWaypoint?.name == point.name;
        final thetaDeg = point.theta * 180.0 / math.pi;

        return Card(
          elevation: isActive ? 4 : 1,
          color: isActive ? Colors.blue[50] : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isActive
                ? BorderSide(color: Colors.blue[300]!, width: 1.5)
                : BorderSide.none,
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: isActive ? Colors.blue : Colors.blueGrey[100],
              child: Icon(
                Icons.location_on,
                color: isActive ? Colors.white : Colors.blueGrey[700],
                size: 20,
              ),
            ),
            title: Text(
              point.name,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: isActive ? Colors.blue[800] : null,
              ),
            ),
            subtitle: Text(
              'X: ${point.x.toStringAsFixed(3)}  Y: ${point.y.toStringAsFixed(3)}  θ: ${thetaDeg.toStringAsFixed(1)}°',
              style: theme.textTheme.bodySmall,
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.edit, size: 20),
                  tooltip: '编辑',
                  onPressed: () => _showAddEditDialog(existing: point),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除',
                  color: Colors.red[400],
                  onPressed: () => _deleteWaypoint(point),
                ),
                const SizedBox(width: 4),
                FilledButton.icon(
                  icon: const Icon(Icons.navigation, size: 16),
                  label: const Text('导航'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(80, 36),
                    backgroundColor: isActive ? Colors.blue[700] : null,
                  ),
                  onPressed: _navManager.isNavigating
                      ? null
                      : () => _sendNavigation(point),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
