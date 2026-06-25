import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:toastification/toastification.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';
import 'package:ros_flutter_gui_app/page/map_nav_page.dart';

/// 地图列表页面：列出机器人上所有地图，选择后可进行重定位和导航
class MapListPage extends StatefulWidget {
  const MapListPage({super.key});

  @override
  State<MapListPage> createState() => _MapListPageState();
}

class _MapListPageState extends State<MapListPage> {
  List<String> _maps = [];
  String _currentMap = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadMaps());
  }

  Future<void> _loadMaps() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final http = context.read<HttpChannel>();
      final maps = await http.getAllMapList();
      final current = await http.getCurrentMap();
      if (!mounted) return;
      setState(() {
        _maps = maps;
        _currentMap = current;
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

  Future<void> _selectMap(String mapName) async {
    // 显示确认对话框
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换地图'),
        content: Text('是否切换到地图「$mapName」？\n切换后将进入重定位和导航页面。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    // 显示加载
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('正在加载地图...'),
          ],
        ),
      ),
    );

    try {
      final http = context.read<HttpChannel>();
      await http.setCurrentMap(mapName);
      if (!mounted) return;
      Navigator.pop(context); // 关闭加载对话框
      setState(() => _currentMap = mapName);

      // 导航到地图导航页
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MapNavPage(mapName: mapName),
        ),
      );
      // 返回时刷新地图列表（当前地图可能已更改）
      _loadMaps();
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context); // 关闭加载对话框
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('切换地图失败: $e'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  Future<void> _deleteMap(String mapName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除地图'),
        content: Text('确定要删除地图「$mapName」吗？此操作不可撤销。'),
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
      await context.read<HttpChannel>().deleteMap(mapName);
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.success,
        title: Text('已删除地图「$mapName」'),
        autoCloseDuration: const Duration(seconds: 3),
      );
      _loadMaps();
    } catch (e) {
      if (!mounted) return;
      toastification.show(
        context: context,
        type: ToastificationType.error,
        title: Text('删除失败: $e'),
        autoCloseDuration: const Duration(seconds: 4),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('地图列表'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadMaps,
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
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
            const SizedBox(height: 12),
            Text('加载失败', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(_error!, style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
            const SizedBox(height: 16),
            FilledButton.icon(
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              onPressed: _loadMaps,
            ),
          ],
        ),
      );
    }

    if (_maps.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.map_outlined, size: 72, color: Colors.grey[400]),
            const SizedBox(height: 16),
            Text('暂无地图', style: theme.textTheme.titleMedium?.copyWith(color: Colors.grey)),
            const SizedBox(height: 8),
            Text(
              '请先使用「建图」功能创建地图',
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      itemCount: _maps.length,
      separatorBuilder: (_, __) => const SizedBox(height: 6),
      itemBuilder: (ctx, i) {
        final name = _maps[i];
        final isCurrent = name == _currentMap;
        return Card(
          elevation: isCurrent ? 3 : 1,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isCurrent
                ? BorderSide(color: theme.colorScheme.primary, width: 2)
                : BorderSide.none,
          ),
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            leading: CircleAvatar(
              backgroundColor: isCurrent
                  ? theme.colorScheme.primaryContainer
                  : theme.colorScheme.surfaceContainerHigh,
              child: Icon(
                Icons.map,
                color: isCurrent
                    ? theme.colorScheme.primary
                    : theme.iconTheme.color,
              ),
            ),
            title: Text(
              name,
              style: theme.textTheme.bodyLarge?.copyWith(
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: isCurrent
                ? Text(
                    '当前地图',
                    style: TextStyle(color: theme.colorScheme.primary, fontSize: 12),
                  )
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 删除按钮
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: Colors.red[400],
                  tooltip: '删除地图',
                  onPressed: isCurrent
                      ? null // 不允许删除当前地图
                      : () => _deleteMap(name),
                ),
                const SizedBox(width: 4),
                // 进入按钮
                FilledButton.icon(
                  icon: const Icon(Icons.arrow_forward, size: 16),
                  label: const Text('进入'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(80, 36),
                    backgroundColor: isCurrent
                        ? theme.colorScheme.primary
                        : null,
                  ),
                  onPressed: () => _selectMap(name),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
