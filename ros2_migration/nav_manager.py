#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import threading

import rclpy
from rclpy.action import ActionClient
from action_msgs.msg import GoalStatus
from nav2_msgs.action import NavigateToPose
from geometry_msgs.msg import PoseStamped, Quaternion
from tf_transformations import quaternion_from_euler


class NavigationManager:
    """ROS2 Humble navigation manager for Nav2 NavigateToPose."""

    def __init__(self, node):
        self.node = node
        self._action_client = ActionClient(self.node, NavigateToPose, 'navigate_to_pose')
        self.node.get_logger().info('Waiting for navigate_to_pose action server...')
        self._action_client.wait_for_server()
        self.node.get_logger().info('navigate_to_pose action server is ready')

        self.current_goal_handle = None
        self.is_navigating = False
        self.should_pause = False
        self._lock = threading.Lock()

    def navigate_to_goal(self, x, y, theta):
        """Navigate the robot to a target (x, y, theta) in the map frame."""
        with self._lock:
            self.is_navigating = True
            self.should_pause = False

        goal_msg = NavigateToPose.Goal()
        pose = PoseStamped()
        pose.header.frame_id = 'map'
        pose.header.stamp = self.node.get_clock().now().to_msg()
        pose.pose.position.x = float(x)
        pose.pose.position.y = float(y)
        pose.pose.position.z = 0.0

        q = quaternion_from_euler(0.0, 0.0, float(theta))
        pose.pose.orientation = Quaternion(x=q[0], y=q[1], z=q[2], w=q[3])
        goal_msg.pose = pose

        self.node.get_logger().info('Sending navigation goal: x=%s, y=%s, theta=%s', x, y, theta)

        send_goal_future = self._action_client.send_goal_async(goal_msg)
        while rclpy.ok() and not send_goal_future.done():
            if self.should_pause:
                self.node.get_logger().info('Navigation pause requested before goal was accepted')
                break
            time.sleep(0.05)

        if not send_goal_future.done():
            self.node.get_logger().error('Failed to send goal to action server')
            self._reset_navigation_state()
            return False

        goal_handle = send_goal_future.result()
        if not goal_handle.accepted:
            self.node.get_logger().error('Navigation goal was rejected')
            self._reset_navigation_state()
            return False

        self.current_goal_handle = goal_handle
        self.node.get_logger().info('Navigation goal accepted, waiting for result...')

        result_future = goal_handle.get_result_async()
        while rclpy.ok() and self.is_navigating:
            if self.should_pause:
                self.node.get_logger().info('Cancelling navigation goal...')
                cancel_future = goal_handle.cancel_goal_async()
                while rclpy.ok() and not cancel_future.done():
                    time.sleep(0.05)
                self.node.get_logger().info('Navigation goal cancelled')
                self._reset_navigation_state()
                return False

            if result_future.done():
                result = result_future.result()
                status = result.status
                if status == GoalStatus.STATUS_SUCCEEDED:
                    self.node.get_logger().info('Navigation completed successfully')
                    self._reset_navigation_state()
                    return True
                self.node.get_logger().error('Navigation failed with status: %s', status)
                self._reset_navigation_state()
                return False

            time.sleep(0.05)

        self.node.get_logger().warn('Navigation loop exited unexpectedly')
        self._reset_navigation_state()
        return False

    def pause_navigation(self):
        """Request that the current navigation goal be cancelled."""
        with self._lock:
            if not self.is_navigating:
                return False
            self.should_pause = True
            self.node.get_logger().info('Navigation pause requested')
            return True

    def cancel_navigation(self):
        """Cancel the current navigation goal immediately."""
        with self._lock:
            if not self.is_navigating or self.current_goal_handle is None:
                return False
            self.node.get_logger().info('Cancelling current navigation goal')
            cancel_future = self.current_goal_handle.cancel_goal_async()
            while rclpy.ok() and not cancel_future.done():
                time.sleep(0.05)
            self._reset_navigation_state()
            return True

    def navigate_to_goals(self, goals):
        """Navigate through multiple goals in sequence."""
        for x, y, theta in goals:
            if not self.navigate_to_goal(x, y, theta):
                self.node.get_logger().warn('Skipping remaining goals after failure or pause')
                return False
            time.sleep(1.0)
        return True

    def _reset_navigation_state(self):
        with self._lock:
            self.is_navigating = False
            self.should_pause = False
            self.current_goal_handle = None


def main():
    rclpy.init()
    node = rclpy.create_node('navigation_manager_node')
    nav_manager = NavigationManager(node)
    try:
        # Example usage can be added here for a simple CLI test.
        node.get_logger().info('NavigationManager is ready')
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
