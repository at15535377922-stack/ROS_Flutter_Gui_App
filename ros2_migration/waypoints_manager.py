#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import logging

import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, DurabilityPolicy
from std_msgs.msg import String

logger = logging.getLogger(__name__)


class Waypoint(object):
    def __init__(self, name='', x=0.0, y=0.0, theta=0.0):
        self.name = name
        self.x = float(x)
        self.y = float(y)
        self.theta = float(theta)

    def to_dict(self):
        return {
            'name': self.name,
            'x': self.x,
            'y': self.y,
            'theta': self.theta,
        }

    @classmethod
    def from_dict(cls, data):
        return cls(
            name=data.get('name', ''),
            x=data.get('x', 0.0),
            y=data.get('y', 0.0),
            theta=data.get('theta', 0.0),
        )

    def __eq__(self, other):
        if not isinstance(other, Waypoint):
            return False
        return (
            self.name == other.name
            and self.x == other.x
            and self.y == other.y
            and self.theta == other.theta
        )

    def __hash__(self):
        return hash((self.name, self.x, self.y, self.theta))


class WaypointsManager(object):
    def __init__(self, node):
        self.node = node
        qos_profile = QoSProfile(depth=10)
        qos_profile.durability = DurabilityPolicy.TRANSIENT_LOCAL

        self.pub = self.node.create_publisher(String, '/metamee/waypoints', qos_profile)
        self.sub = self.node.create_subscription(String, '/metamee/waypoints', self.waypoints_callback, qos_profile)

        self.waypoints_cache = []
        self.json_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'map', 'waypoints.json')
        self.load_waypoints()
        self.node.get_logger().info('WaypointsManager initialized with %d waypoints', len(self.waypoints_cache))

    def load_waypoints(self):
        try:
            if os.path.exists(self.json_path):
                with open(self.json_path, 'r', encoding='utf-8') as f:
                    data = json.load(f)
                self.waypoints_cache = [Waypoint.from_dict(wp) for wp in data]
                self._publish_waypoints()
                self.node.get_logger().info('Loaded %d waypoints from %s', len(self.waypoints_cache), self.json_path)
            else:
                self.waypoints_cache = []
                self.node.get_logger().warn('Waypoint file not found: %s', self.json_path)
        except Exception as exc:
            self.node.get_logger().error('Error loading waypoints: %s', str(exc))
            self.waypoints_cache = []

    def save_waypoints(self):
        try:
            os.makedirs(os.path.dirname(self.json_path), exist_ok=True)
            with open(self.json_path, 'w', encoding='utf-8') as f:
                json.dump([wp.to_dict() for wp in self.waypoints_cache], f, indent=4, ensure_ascii=False)
            return True
        except Exception as exc:
            self.node.get_logger().error('Error saving waypoints: %s', str(exc))
            return False

    def waypoints_callback(self, msg):
        try:
            data = json.loads(msg.data)
            new_waypoints = [Waypoint.from_dict(item) for item in data]
            if set(new_waypoints) != set(self.waypoints_cache):
                if not new_waypoints:
                    if self.waypoints_cache:
                        self._publish_waypoints()
                else:
                    self.waypoints_cache = new_waypoints
                    self.save_waypoints()
                    self.node.get_logger().info('Updated waypoints cache with %d entries', len(self.waypoints_cache))
        except Exception as exc:
            self.node.get_logger().error('Error processing waypoint message: %s', str(exc))

    def _publish_waypoints(self):
        msg = String()
        msg.data = json.dumps([wp.to_dict() for wp in self.waypoints_cache])
        self.pub.publish(msg)

    def get_waypoint(self, name):
        for wp in self.waypoints_cache:
            if wp.name == name:
                return wp
        return None


def main():
    rclpy.init()
    node = Node('waypoints_manager_node')
    manager = WaypointsManager(node)
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
