import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:ros_flutter_gui_app/basic/nav_point.dart';
import 'package:ros_flutter_gui_app/provider/http_channel.dart';

/// 导航状态枚举
enum WaypointNavStatus {
  idle,
  navigating,
  succeeded,
  failed,
  cancelling,
  unknown,
}

WaypointNavStatus _parseStatus(String s) {
  switch (s) {
    case 'idle':
      return WaypointNavStatus.idle;
    case 'navigating':
      return WaypointNavStatus.navigating;
    case 'succeeded':
      return WaypointNavStatus.succeeded;
    case 'failed':
      return WaypointNavStatus.failed;
    case 'cancelling':
      return WaypointNavStatus.cancelling;
    default:
      return WaypointNavStatus.unknown;
  }
}

/// 导航点管理 & 导航状态管理
class NavigationManager extends ChangeNotifier {
  final HttpChannel _http;

  NavigationManager(this._http);

  List<NavPoint> _waypoints = [];
  NavPoint? _activeWaypoint;
  WaypointNavStatus _navStatus = WaypointNavStatus.idle;
  String _errorMessage = '';
  bool _isLoading = false;
  Timer? _statusPollTimer;

  List<NavPoint> get waypoints => List.unmodifiable(_waypoints);
  NavPoint? get activeWaypoint => _activeWaypoint;
  WaypointNavStatus get navStatus => _navStatus;
  String get errorMessage => _errorMessage;
  bool get isLoading => _isLoading;
  bool get isNavigating =>
      _navStatus == WaypointNavStatus.navigating ||
      _navStatus == WaypointNavStatus.cancelling;

  // ─── Waypoints 管理 ────────────────────────────────────────────────────

  /// 从服务器加载当前地图的导航点
  Future<void> loadWaypoints() async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _http.getWaypoints();
      _waypoints = data.map((e) => NavPoint.fromJson(e)).toList();
      _errorMessage = '';
    } catch (e) {
      _errorMessage = e.toString();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// 保存导航点到服务器
  Future<bool> saveWaypoints() async {
    try {
      await _http.saveWaypoints(
          _waypoints.map((p) => p.toJson()).toList());
      return true;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 添加或更新一个导航点（本地 + 自动同步服务器）
  Future<bool> addOrUpdateWaypoint(NavPoint point) async {
    final idx = _waypoints.indexWhere((p) => p.name == point.name);
    if (idx >= 0) {
      _waypoints[idx] = point;
    } else {
      _waypoints.add(point);
    }
    notifyListeners();
    return saveWaypoints();
  }

  /// 删除导航点（本地 + 自动同步服务器）
  Future<bool> removeWaypoint(String name) async {
    _waypoints.removeWhere((p) => p.name == name);
    notifyListeners();
    return saveWaypoints();
  }

  // ─── 导航控制 ────────────────────────────────────────────────────────────

  /// 发起导航到指定 waypoint（通过 Nav2 Action）
  Future<bool> navigateTo(NavPoint point) async {
    _errorMessage = '';
    try {
      final ok = await _http.navigateToWaypoint(
        name: point.name,
        x: point.x,
        y: point.y,
        theta: point.theta,
      );
      if (ok) {
        _activeWaypoint = point;
        _navStatus = WaypointNavStatus.navigating;
        notifyListeners();
        _startStatusPolling();
      } else {
        _errorMessage = 'navigation request failed';
        notifyListeners();
      }
      return ok;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  /// 取消当前导航
  Future<bool> cancelNavigation() async {
    try {
      final ok = await _http.cancelWaypointNav();
      if (ok) {
        _navStatus = WaypointNavStatus.cancelling;
        notifyListeners();
      }
      return ok;
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
      return false;
    }
  }

  // ─── 状态轮询 ─────────────────────────────────────────────────────────────

  void _startStatusPolling() {
    _stopStatusPolling();
    _statusPollTimer =
        Timer.periodic(const Duration(milliseconds: 800), (_) async {
      await _pollNavStatus();
    });
  }

  void _stopStatusPolling() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
  }

  Future<void> _pollNavStatus() async {
    try {
      final statusStr = await _http.getNavStatus();
      final newStatus = _parseStatus(statusStr);
      if (newStatus != _navStatus) {
        _navStatus = newStatus;
        if (newStatus == WaypointNavStatus.idle ||
            newStatus == WaypointNavStatus.succeeded ||
            newStatus == WaypointNavStatus.failed) {
          _activeWaypoint = null;
          _stopStatusPolling();
        }
        notifyListeners();
      }
    } catch (_) {
      // 网络异常时静默忽略
    }
  }

  @override
  void dispose() {
    _stopStatusPolling();
    super.dispose();
  }
}
