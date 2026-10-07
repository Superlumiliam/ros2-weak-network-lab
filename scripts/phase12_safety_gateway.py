#!/usr/bin/env python3
"""Jetson-side, disarmed-by-default /cmd_vel safety gateway for Phase 12."""

import math
import time

import rclpy
from geometry_msgs.msg import Twist
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_srvs.srv import SetBool


class Phase12SafetyGateway(Node):
    def __init__(self):
        super().__init__("phase12_safety_gateway")
        self.declare_parameter("input_topic", "/cmd_vel_remote")
        self.declare_parameter("output_topic", "/cmd_vel")
        self.declare_parameter("publish_rate_hz", 20.0)
        self.declare_parameter("command_timeout_s", 0.75)
        self.declare_parameter("max_linear_x", 0.25)
        self.declare_parameter("max_linear_y", 0.25)
        self.declare_parameter("max_angular_z", 0.5)

        self.input_topic = self.get_parameter("input_topic").value
        output_topic = self.get_parameter("output_topic").value
        publish_rate = float(self.get_parameter("publish_rate_hz").value)
        self.command_timeout = float(self.get_parameter("command_timeout_s").value)
        self.max_linear_x = float(self.get_parameter("max_linear_x").value)
        self.max_linear_y = float(self.get_parameter("max_linear_y").value)
        self.max_angular_z = float(self.get_parameter("max_angular_z").value)

        if not self.input_topic or not output_topic:
            raise ValueError("input_topic and output_topic must not be empty")
        if not math.isfinite(publish_rate) or publish_rate <= 0:
            raise ValueError("publish_rate_hz must be finite and positive")
        if not math.isfinite(self.command_timeout) or self.command_timeout <= 0:
            raise ValueError("command_timeout_s must be finite and positive")
        for name, value in (
            ("max_linear_x", self.max_linear_x),
            ("max_linear_y", self.max_linear_y),
            ("max_angular_z", self.max_angular_z),
        ):
            if not math.isfinite(value) or value <= 0:
                raise ValueError(f"{name} must be finite and positive")

        qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
            reliability=ReliabilityPolicy.RELIABLE,
        )
        self.publisher = self.create_publisher(Twist, output_topic, qos)
        self.subscription = self.create_subscription(
            Twist, self.input_topic, self._on_command, qos
        )
        self.arm_service = self.create_service(
            SetBool, "/phase12_safety_gateway/arm", self._on_arm
        )
        self.armed = False
        self.armed_at = None
        self.latest_command = Twist()
        self.last_command_time = None
        self.timer = self.create_timer(1.0 / publish_rate, self._publish_tick)
        self._publish_zero()
        self.get_logger().warning(
            f"DISARMED: forwarding {self.input_topic} to {output_topic} only after "
            "explicit arm service; watchdog and velocity limits are active"
        )

    def _on_command(self, message):
        values = (
            message.linear.x,
            message.linear.y,
            message.angular.z,
        )
        if not all(math.isfinite(value) for value in values):
            self.latest_command = Twist()
            self.last_command_time = None
            self.get_logger().error("rejected non-finite velocity command")
            return
        self.latest_command = message
        self.last_command_time = time.monotonic()

    def _on_arm(self, request, response):
        self.armed = bool(request.data)
        # Never replay a command received before the explicit arm action.
        self.latest_command = Twist()
        self.last_command_time = None
        self.armed_at = time.monotonic() if self.armed else None
        if not self.armed:
            self._publish_zero()
            response.message = "disarmed; zero Twist published"
        else:
            response.message = (
                "armed; waiting for a fresh command (limits and watchdog active)"
            )
        response.success = True
        self.get_logger().warning(response.message)
        return response

    def _publish_zero(self):
        self._publish(Twist())

    def _publish(self, message):
        self.publisher.publish(message)

    def _publish_tick(self):
        if not self.armed:
            self._publish_zero()
            return

        now = time.monotonic()
        reference_time = self.last_command_time or self.armed_at
        if now - reference_time > self.command_timeout:
            self.armed = False
            self.armed_at = None
            self.last_command_time = None
            self.latest_command = Twist()
            self.get_logger().error(
                "command watchdog expired; latched disarmed, explicit re-arm required"
            )
            self._publish_zero()
            return

        command = Twist()
        command.linear.x = max(
            -self.max_linear_x,
            min(self.max_linear_x, self.latest_command.linear.x),
        )
        command.linear.y = max(
            -self.max_linear_y,
            min(self.max_linear_y, self.latest_command.linear.y),
        )
        command.angular.z = max(
            -self.max_angular_z,
            min(self.max_angular_z, self.latest_command.angular.z),
        )
        self._publish(command)


def main():
    rclpy.init()
    node = None
    try:
        node = Phase12SafetyGateway()
        rclpy.spin(node)
    except (KeyboardInterrupt, ValueError) as error:
        if isinstance(error, ValueError):
            print(f"phase12_safety_gateway: {error}")
    finally:
        if node is not None:
            # Best effort on orderly shutdown; the setup script disarms before stopping.
            try:
                node._publish_zero()
            except Exception:
                pass
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
