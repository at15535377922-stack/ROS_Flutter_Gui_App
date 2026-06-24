#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import json
import threading
import time

import rclpy
from rclpy.node import Node
from std_msgs.msg import String

from nav_manager import NavigationManager
from waypoints_manager import WaypointsManager


class PlanStep(object):
    def __init__(self, step_type, name, params=None):
        self.step_type = step_type
        self.name = name
        self.params = params or {}
        self.status = 'pending'
        self.error = None

    def to_dict(self):
        return {
            'step_type': self.step_type,
            'name': self.name,
            'params': self.params,
        }

    def to_dict_with_status(self):
        return {
            'step_type': self.step_type,
            'name': self.name,
            'params': self.params,
            'status': self.status,
            'error': self.error,
        }

    @classmethod
    def from_dict(cls, data):
        step = cls(
            step_type=data['step_type'],
            name=data['name'],
            params=data.get('params', {}),
        )
        step.status = 'pending'
        step.error = None
        return step


class PlanManager(Node):
    def __init__(self):
        super().__init__('plan_manager')
        self.nav_manager = NavigationManager(self)
        self.waypoints_manager = WaypointsManager(self)

        self.status_pub = self.create_publisher(String, '/metamee/status_command', 10)

        self.current_plan = []
        self.current_step_index = -1
        self.is_running = False
        self.is_paused = False
        self.force_stop_requested = False
        self.pause_condition = threading.Condition()
        self.plan_thread = None
        self.lock = threading.Lock()

        self.plans_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plans')
        os.makedirs(self.plans_dir, exist_ok=True)

        self._spin_thread = threading.Thread(target=self._spin_loop, daemon=True)
        self._spin_active = True
        self._spin_thread.start()

    def _spin_loop(self):
        while self._spin_active and rclpy.ok():
            rclpy.spin_once(self, timeout_sec=0.1)
            time.sleep(0.01)

    def pub_status(self, status):
        msg = String()
        msg.data = status
        self.status_pub.publish(msg)

    def execute_step(self, step):
        if self.is_paused:
            step.status = 'paused'
            return False

        if step.step_type == 'navigation':
            step.status = 'running'
            self.pub_status('NAVIGATING')
            waypoint_name = step.params.get('waypoint_name')
            waypoint = self.waypoints_manager.get_waypoint(waypoint_name)
            if not waypoint:
                step.status = 'failed'
                step.error = f'Waypoint not found: {waypoint_name}'
                return False

            success = self.nav_manager.navigate_to_goal(waypoint.x, waypoint.y, waypoint.theta)
            if not success:
                if self.is_paused:
                    step.status = 'paused'
                else:
                    step.status = 'failed'
                    step.error = 'Navigation failed'
                    self.pub_status('FAILED')
                return False

        elif step.step_type == 'sleep':
            step.status = 'running'
            self.pub_status('SLEEPING')
            duration = float(step.params.get('duration', 0))
            if duration < 0:
                step.status = 'failed'
                step.error = 'Invalid sleep duration'
                return False
            start_time = time.time()
            while time.time() - start_time < duration:
                if self.is_paused or self.force_stop_requested:
                    step.status = 'paused'
                    return False
                time.sleep(0.1)

        elif step.step_type == 'speech':
            step.status = 'failed'
            step.error = 'Speech step is not implemented in the ROS2 migration example'
            self.pub_status('FAILED')
            return False

        else:
            step.status = 'failed'
            step.error = f'Unknown step type: {step.step_type}'
            return False

        step.status = 'completed'
        self.pub_status('RUNNING')
        return True

    def load_plan(self, plan_name):
        plan_path = os.path.join(self.plans_dir, f'{plan_name}.json')
        try:
            with open(plan_path, 'r', encoding='utf-8') as f:
                data = json.load(f)
            return [PlanStep.from_dict(item) for item in data]
        except Exception as exc:
            self.get_logger().error('Failed to load plan %s: %s', plan_name, str(exc))
            return []

    def save_plan(self, plan_name, steps):
        plan_path = os.path.join(self.plans_dir, f'{plan_name}.json')
        try:
            with open(plan_path, 'w', encoding='utf-8') as f:
                json.dump([step.to_dict() for step in steps], f, indent=4, ensure_ascii=False)
            return True
        except Exception as exc:
            self.get_logger().error('Failed to save plan %s: %s', plan_name, str(exc))
            return False

    def _run_plan_internal(self, start_index):
        self.force_stop_requested = False
        self.is_running = True
        self.is_paused = False
        self.current_step_index = start_index

        for index in range(start_index, len(self.current_plan)):
            self.current_step_index = index
            step = self.current_plan[index]
            with self.pause_condition:
                while self.is_paused and not self.force_stop_requested:
                    self.pub_status('PAUSED')
                    self.pause_condition.wait()
                if self.force_stop_requested:
                    return False, 'Force stop requested'

            if not self.execute_step(step):
                if step.status == 'paused':
                    with self.pause_condition:
                        while self.is_paused and not self.force_stop_requested:
                            self.pause_condition.wait()
                        if self.force_stop_requested:
                            return False, 'Force stop requested'
                        if step.status == 'paused':
                            step.status = 'pending'
                            step.error = None
                            continue
                return False, step.error or 'Step failed'

        return True, 'Plan completed successfully'

    def run_plan(self, plan_name, start_index=0):
        with self.lock:
            if self.is_running and not self.is_paused:
                return False, 'Plan already running'
            if self.is_running and self.is_paused:
                return self.resume_plan()
            self.current_plan = self.load_plan(plan_name)
            if not self.current_plan:
                return False, 'Plan load failed or empty'
            self.current_step_index = start_index
            self.plan_thread = threading.Thread(target=self._run_plan_internal, args=(start_index,), daemon=True)
            self.plan_thread.start()
            return True, 'Plan started'

    def pause_plan(self):
        with self.lock:
            if not self.is_running or self.is_paused:
                return False, 'No running plan to pause'
            self.is_paused = True
            self.nav_manager.pause_navigation()
            with self.pause_condition:
                self.pause_condition.notify_all()
            self.pub_status('PAUSED')
            return True, 'Plan paused'

    def resume_plan(self):
        with self.lock:
            if not self.is_running or not self.is_paused:
                return False, 'No paused plan to resume'
            self.is_paused = False
            with self.pause_condition:
                self.pause_condition.notify_all()
            self.pub_status('RUNNING')
            return True, 'Plan resumed'

    def force_stop_plan(self):
        with self.lock:
            if not self.is_running:
                return False, 'No running plan to stop'
            self.force_stop_requested = True
            self.is_paused = False
            self.nav_manager.cancel_navigation()
            with self.pause_condition:
                self.pause_condition.notify_all()
            self.pub_status('STOPPED')
            self.is_running = False
            return True, 'Plan force stopped'

    def get_status(self):
        return {
            'is_running': self.is_running,
            'is_paused': self.is_paused,
            'current_step_index': self.current_step_index,
            'current_plan': [step.to_dict_with_status() for step in self.current_plan],
        }

    def destroy(self):
        self._spin_active = False
        if self.plan_thread and self.plan_thread.is_alive():
            self.plan_thread.join(timeout=1.0)
        self.destroy_node()


def main():
    rclpy.init()
    plan_manager = PlanManager()
    try:
        plan_manager.get_logger().info('PlanManager ROS2 node started')
        while rclpy.ok():
            time.sleep(0.1)
    except KeyboardInterrupt:
        pass
    finally:
        plan_manager.destroy()
        rclpy.shutdown()


if __name__ == '__main__':
    main()
