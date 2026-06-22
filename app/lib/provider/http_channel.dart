import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ros_flutter_gui_app/basic/topology_map.dart';
import 'package:ros_flutter_gui_app/global/setting.dart';

class AppException implements Exception {
  final String key;
  AppException(this.key);
  @override
  String toString() => key;
}

class HttpChannel {
  Uri _buildUri(String path, {Map<String, String>? queryParameters}) {
    final base = globalSetting.tileServerUrl;
    return Uri.parse('$base$path').replace(queryParameters: queryParameters);
  }

  Future<List<String>> getAllMapList() async {
    final uri = _buildUri('/getAllMapList');
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('getAllMapList failed: ${res.statusCode} ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((e) => e.toString()).toList();
  }

  Future<String> getCurrentMap() async {
    final uri = _buildUri('/currentMap');
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('getCurrentMap failed: ${res.statusCode} ${res.body}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return j['current_map'] as String? ?? '';
  }

  Future<void> setCurrentMap(String name) async {
    final uri = _buildUri('/setCurrentMap', queryParameters: {'name': name});
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('setCurrentMap failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<void> deleteMap(String mapName) async {
    final uri = _buildUri('/deleteMap', queryParameters: {'map_name': mapName});
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('deleteMap failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<TopologyMap> getTopologyMap({String? mapName}) async {
    final uri = mapName != null && mapName.isNotEmpty
        ? _buildUri('/getTopologyMap', queryParameters: {'map_name': mapName})
        : _buildUri('/getTopologyMap');
    final res = await http.get(uri);
    if (res.statusCode == 404) {
      return TopologyMap(points: []);
    }
    if (res.statusCode != 200) {
      throw Exception('getTopologyMap failed: ${res.statusCode} ${res.body}');
    }
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return TopologyMap.fromJson(j);
  }

  Future<void> saveMapEdit({
    required String editSessionId,
    required TopologyMap topologyMap,
    required Map<int, int> obstacleEdits,
    String? mapName,
    String? sourceMapName,
  }) async {
    final name = mapName ?? await getCurrentMap();
    if (name.isEmpty) {
      throw AppException('no_map_available');
    }
    final obstacleEditsJson = obstacleEdits
        .map((cellIndex, value) => MapEntry(cellIndex.toString(), value));
    final topologyJson = topologyMap.toJson();
    topologyJson['map_name'] = name;
    final uri = _buildUri(
      '/saveMapEdit',
      queryParameters: <String, String>{
        'session_id': editSessionId,
        'map_name': name,
        'source_map_name': sourceMapName ?? name,
        'topology_json': jsonEncode(topologyJson),
        'obstacle_edits_json': jsonEncode(obstacleEditsJson),
      },
    );
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('saveMapEdit failed: ${res.statusCode} ${res.body}');
    }
  }

  Future<Map<String, dynamic>> getGuiSettings() async {
    final uri = _buildUri('/api/settings');
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('api/settings ${res.statusCode} ${res.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<Map<String, dynamic>> saveGuiSettings(Map<String, dynamic> body) async {
    final uri = _buildUri('/api/settings');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(body),
    );
    if (res.statusCode != 200) {
      throw Exception('api/settings POST ${res.statusCode} ${res.body}');
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  Future<bool> postRobotNavGoal(double x, double y, double yaw,
      {double roll = 0, double pitch = 0}) async {
    final uri = _buildUri('/robot/nav_goal');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(
          {'x': x, 'y': y, 'yaw': yaw, 'roll': roll, 'pitch': pitch}),
    );
    return res.statusCode == 200;
  }

  Future<bool> postRobotInitialPose(double x, double y, double yaw,
      {double roll = 0, double pitch = 0}) async {
    final uri = _buildUri('/robot/initial_pose');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(
          {'x': x, 'y': y, 'yaw': yaw, 'roll': roll, 'pitch': pitch}),
    );
    return res.statusCode == 200;
  }

  Future<bool> postRobotCancelNav() async {
    final uri = _buildUri('/robot/cancel_nav');
    final res =
        await http.post(uri, headers: {'Content-Type': 'application/json; charset=utf-8'});
    return res.statusCode == 200;
  }

  Future<void> postSubImage(String topic, bool subscribe) async {
    final uri = _buildUri('/subImage');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({'topic': topic, 'subscribe': subscribe}),
    );
    if (res.statusCode != 200) {
      throw Exception('subImage ${res.statusCode} ${res.body}');
    }
  }

  Future<Map<String, dynamic>?> getTf(
      {required String targetFrame, required String sourceFrame}) async {
    final uri = _buildUri('/api/tf',
        queryParameters: {'target_frame': targetFrame, 'source_frame': sourceFrame});
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      return null;
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  // ─── Waypoints API ────────────────────────────────────────────────────────

  /// 获取当前地图的所有导航点列表
  Future<List<Map<String, dynamic>>> getWaypoints() async {
    final uri = _buildUri('/api/waypoints');
    final res = await http.get(uri);
    if (res.statusCode != 200) {
      throw Exception('getWaypoints failed: ${res.statusCode} ${res.body}');
    }
    final list = jsonDecode(res.body) as List<dynamic>;
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// 保存导航点列表到服务器（覆盖当前地图的 waypoints.json）
  Future<void> saveWaypoints(List<Map<String, dynamic>> waypoints) async {
    final uri = _buildUri('/api/waypoints');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode(waypoints),
    );
    if (res.statusCode != 200) {
      throw Exception('saveWaypoints failed: ${res.statusCode} ${res.body}');
    }
  }

  /// 通过 Nav2 Action 导航到指定 waypoint
  Future<bool> navigateToWaypoint(
      {required String name,
      required double x,
      required double y,
      required double theta}) async {
    final uri = _buildUri('/robot/navigate_to_waypoint');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
      body: jsonEncode({'name': name, 'x': x, 'y': y, 'theta': theta}),
    );
    return res.statusCode == 200;
  }

  /// 取消当前 Nav2 Action Goal
  Future<bool> cancelWaypointNav() async {
    final uri = _buildUri('/robot/cancel_waypoint_nav');
    final res = await http.post(
      uri,
      headers: {'Content-Type': 'application/json; charset=utf-8'},
    );
    return res.statusCode == 200;
  }

  /// 查询当前导航状态: "idle" | "navigating" | "succeeded" | "failed" | "cancelling"
  Future<String> getNavStatus() async {
    final uri = _buildUri('/robot/nav_status');
    final res = await http.get(uri);
    if (res.statusCode != 200) return 'unknown';
    final j = jsonDecode(res.body) as Map<String, dynamic>;
    return j['status'] as String? ?? 'unknown';
  }
}
