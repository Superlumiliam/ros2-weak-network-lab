"""Loopback-only functional test for the Jetson safety gateway."""

import importlib.util
import pathlib
import threading
import time
import unittest

import rclpy
from geometry_msgs.msg import Twist
from rclpy.executors import MultiThreadedExecutor
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, HistoryPolicy
from std_srvs.srv import SetBool


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "phase12_safety_gateway", ROOT / "scripts/phase12_safety_gateway.py"
)
GATEWAY_MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATEWAY_MODULE)


class SafetyGatewayTest(unittest.TestCase):
    def test_disarmed_clamped_watchdog_and_disarm(self):
        rclpy.init()
        gateway = GATEWAY_MODULE.Phase12SafetyGateway()
        probe = Node("phase12_safety_gateway_test")
        qos = QoSProfile(
            history=HistoryPolicy.KEEP_LAST,
            depth=1,
            reliability=ReliabilityPolicy.RELIABLE,
        )
        received = []
        probe.create_subscription(
            Twist,
            "/cmd_vel",
            lambda message: received.append((time.monotonic(), message)),
            qos,
        )
        remote_pub = probe.create_publisher(Twist, "/cmd_vel_remote", qos)
        arm_client = probe.create_client(SetBool, "/phase12_safety_gateway/arm")
        outgoing = {"message": Twist(), "active": True}
        remote_timer = probe.create_timer(
            0.05,
            lambda: remote_pub.publish(outgoing["message"])
            if outgoing["active"]
            else None,
        )
        executor = MultiThreadedExecutor()
        executor.add_node(gateway)
        executor.add_node(probe)
        spin_thread = threading.Thread(target=executor.spin, daemon=True)
        spin_thread.start()

        def wait_until(predicate, timeout=3.0):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if predicate():
                    return True
                time.sleep(0.02)
            return False

        def call_arm(armed):
            self.assertTrue(arm_client.wait_for_service(timeout_sec=3.0))
            future = arm_client.call_async(SetBool.Request(data=armed))
            self.assertTrue(wait_until(future.done, 3.0))
            self.assertTrue(future.result().success)

        try:
            self.assertTrue(wait_until(lambda: len(received) >= 2))
            time.sleep(0.15)
            self.assertTrue(all(message.linear.x == 0.0 for _, message in received))

            call_arm(True)
            command = Twist()
            command.linear.x = 3.0
            command.linear.y = -3.0
            command.angular.z = 4.0
            outgoing["message"] = command
            self.assertTrue(
                wait_until(lambda: any(message.linear.x > 0 for _, message in received))
            )
            positive = [message for _, message in received if message.linear.x > 0]
            self.assertLessEqual(max(m.linear.x for m in positive), 0.25)
            self.assertGreaterEqual(min(m.linear.y for m in positive), -0.25)
            self.assertLessEqual(max(m.angular.z for m in positive), 0.5)

            # No further input: the output must return to zero on the watchdog.
            outgoing["active"] = False
            received.clear()
            input_stopped_at = time.monotonic()
            self.assertTrue(
                wait_until(
                    lambda: any(
                        received_at - input_stopped_at >= 0.9
                        and message.linear.x == 0.0
                        for received_at, message in received
                    ),
                    timeout=2.0,
                )
            )
            call_arm(False)
            self.assertFalse(gateway.armed)
        finally:
            executor.shutdown(timeout_sec=2.0)
            spin_thread.join(timeout=2.0)
            remote_timer.cancel()
            gateway.destroy_node()
            probe.destroy_node()
            rclpy.shutdown()


if __name__ == "__main__":
    unittest.main()
