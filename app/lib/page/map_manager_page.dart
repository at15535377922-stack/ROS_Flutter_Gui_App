import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';

import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/page/map_edit_page.dart';
import 'package:ros_flutter_gui_app/page/slam_view_page.dart';

/// 地图管理页面
/// 显示 ~/.maps/ 下所有地图目录，支持切换、删除、编辑、查看建图
class MapManagerPage extends StatefulWidget {
  final VoidCallback? onMapChanged;

  const MapManagerPage({super.key, this.onMapChanged});

  @override
  State<MapManagerPage> createState() => _MapManagerPageState();
}

class _MapManagerPageState extends State<MapManagerPage> {
  List<String> _mapList = [];
  String _currentMap = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final http = context.read<HttpChannel>();
      final results = await Future.wait([
        http.getAllMapList(),
        http.getCurrentMap(),
      ]);
      if (!mounted) return;
      setState(() {
        _mapList = results[0] as List<String>;
        _currentMap = results[1] as String;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _switchMap(String name) async {
    if (name == _currentMap) return;
    try {
      await context.read<HttpChannel>().setCurrentMap(name);
      if (!mounted) return;
      setState(() => _currentMap = name);
      // 通知主页刷新瓦片
      widget.onMapChanged?.call();
      toastification.show(
        context: context,
        title: Text('已切换到地图：$name'),
        autoCloseDuration: const Duration(seconds: 2),
      );
    } catch (e) {
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('切换失败：$e'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _deleteMap(String name) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除地图「$name」吗？此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    try {
      await context.read<HttpChannel>().deleteMap(name);
      if (!mounted) return;
      toastification.show(
        context: context,
        title: Text('已删除地图：$name'),
        autoCloseDuration: const Duration(seconds: 2),
      );
      await _loadData();
      widget.onMapChanged?.call();
    } catch (e) {
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('删除失败：$e'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  void _editMap(String name) async {
    // 先切换到该地图再进编辑页
    if (name != _currentMap) {
      try {
        await context.read<HttpChannel>().setCurrentMap(name);
        if (!mounted) return;
        setState(() => _currentMap = name);
      } catch (e) {
        if (!mounted) return;
        toastification.show(
          context: context,
          type: ToastificationType.error,
          title: Text('切换地图失败：$e'),
          autoCloseDuration: const Duration(seconds: 4),
        );
        return;
      }
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => MapEditPage(
          onExit: () {
            _loadData();
            widget.onMapChanged?.call();
          },
        ),
      ),
    );
  }

  void _openSlamView() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const SlamViewPage()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('地图管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新列表',
            onPressed: _loadData,
          ),
          IconButton(
            icon: const Icon(Icons.map_outlined),
            tooltip: '进入建图模式',
            onPressed: _openSlamView,
          ),
        ],
      ),
      body: _buildBody(theme),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: Colors.red[300]),
            const SizedBox(height: 12),
            Text('加载失败：$_error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadData,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (_mapList.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.map_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无地图', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey[600])),
            const SizedBox(height: 8),
            Text('请先启动建图 Launch 并保存地图', style: theme.textTheme.bodySmall),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSlamView,
              icon: const Icon(Icons.radar),
              label: const Text('进入建图可视化'),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(12),
      itemCount: _mapList.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final name = _mapList[index];
        final isCurrent = name == _currentMap;
        return Card(
          elevation: isCurrent ? 3 : 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isCurrent
                ? BorderSide(color: theme.colorScheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(
                  Icons.map,
                  color: isCurrent ? theme.colorScheme.primary : Colors.grey[500],
                  size: 32,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: isCurrent ? theme.colorScheme.primary : null,
                        ),
                      ),
                      if (isCurrent)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Container(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '当前使用',
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                // 切换
                IconButton(
                  icon: Icon(
                    Icons.check_circle_outline,
                    color: isCurrent ? theme.colorScheme.primary : Colors.grey[400],
                  ),
                  tooltip: isCurrent ? '当前地图' : '切换到此地图',
                  onPressed: isCurrent ? null : () => _switchMap(name),
                ),
                // 编辑
                IconButton(
                  icon: Icon(Icons.edit_outlined, color: Colors.orange[600]),
                  tooltip: '编辑地图',
                  onPressed: () => _editMap(name),
                ),
                // 删除
                IconButton(
                  icon: Icon(Icons.delete_outline, color: Colors.red[400]),
                  tooltip: '删除地图',
                  onPressed: () => _deleteMap(name),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
