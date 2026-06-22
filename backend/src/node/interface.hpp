#pragma once

#include "common/config/config.hpp"
#include "core/map/occupancy_grid.hpp"

#include <string>
#include <vector>

namespace ros_gui_backend {

// Waypoint 数据结构
struct WaypointData {
  std::string name;
  double x;
  double y;
  double theta;
};

class IRosGuiNode {
 public:
  virtual ~IRosGuiNode() = default;
  virtual bool Init(const AppConfig& app_config) = 0;
  virtual void Run() = 0;
  virtual void Shutdown() = 0;
  virtual bool SetRobotStreamImageSubscription(
      const std::string& topic, bool subscribe, std::string* error_message) = 0;
  virtual bool ReloadGuiStreams(const AppConfig& settings) = 0;
  virtual bool PublishCmdVel(double vx, double vy, double vw) = 0;
  virtual bool PublishNavGoal(double x, double y, double roll, double pitch, double yaw) = 0;
  virtual bool PublishInitialPose(double x, double y, double roll, double pitch, double yaw) = 0;
  virtual bool PublishNavCancel() = 0;
  virtual bool PublishMap(const OccupancyGridData& map, const std::string& frame_id) = 0;
  virtual bool LookupTransform(const std::string& target_frame, const std::string& source_frame,
      std::string* json_out, std::string* err) = 0;

  // 定点导航接口
  virtual bool NavigateToWaypoint(const WaypointData& waypoint, std::string* error_message) = 0;
  virtual bool CancelNavigation(std::string* error_message) = 0;
  virtual std::string GetNavigationStatus() = 0;
};

}  // namespace ros_gui_backend
