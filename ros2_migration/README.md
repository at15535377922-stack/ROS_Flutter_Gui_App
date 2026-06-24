# ROS2 Humble Navigation Migration Examples

这个目录包含用于将当前项目导航逻辑迁移到 ROS2 Humble 的独立示例文件。

## 文件说明

- `nav_manager.py`
  - ROS2 Humble 版本的导航管理器。
  - 使用 `rclpy` 和 `nav2_msgs.action.NavigateToPose` 发送导航目标。

- `waypoints_manager.py`
  - ROS2 Humble 版本的导航点管理器。
  - 支持从 `map/waypoints.json` 加载导航点，并通过 `/metamee/waypoints` 话题发布/订阅。

- `plan_manager.py`
  - ROS2 版本的计划管理示例。
  - 包含计划执行、导航步骤与暂停/继续/停止逻辑。

## 使用方法

1. 在 ROS2 Humble 环境中运行：

```bash
cd d:/UserFiles/Downloads/metamee/ros2_migration
source /opt/ros/humble/setup.bash
python3 plan_manager.py
```

2. 运行之前请确保：
   - ROS2 Humble 环境已经激活。
   - Nav2 的 `navigate_to_pose` action server 已经可用。
   - `map/waypoints.json` 文件存在并包含导航点。

## 迁移建议

- 先单独测试 `nav_manager.py` 是否可以与 Nav2 连接。
- 然后测试 `waypoints_manager.py` 能否正确加载并发布导航点。
- 最后测试 `plan_manager.py` 在 ROS2 环境中的计划执行流程。

## 注意

- 目前 `plan_manager.py` 示例中只实现了 `navigation` 和 `sleep` 步骤。
- `speech` 步骤在此示例中未迁移。
