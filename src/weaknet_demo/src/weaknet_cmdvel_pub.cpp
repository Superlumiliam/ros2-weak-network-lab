#include <algorithm>
#include <chrono>
#include <cmath>
#include <memory>
#include <stdexcept>

#include "geometry_msgs/msg/twist.hpp"
#include "rclcpp/rclcpp.hpp"

class WeaknetCmdvelPublisher : public rclcpp::Node
{
public:
  WeaknetCmdvelPublisher()
  : Node("weaknet_cmdvel_pub")
  {
    rate_hz_ = declare_parameter<double>("rate_hz", 1.0);
    linear_x_ = declare_parameter<double>("linear_x", 0.0);
    linear_y_ = declare_parameter<double>("linear_y", 0.0);
    angular_z_ = declare_parameter<double>("angular_z", 0.0);

    if (!(rate_hz_ > 0.0) || !std::isfinite(rate_hz_)) {
      throw std::invalid_argument("rate_hz must be a finite positive number");
    }

    publisher_ = create_publisher<geometry_msgs::msg::Twist>(
      "/cmd_vel", rclcpp::QoS(10).reliable());

    const auto period = std::chrono::milliseconds(
      static_cast<int64_t>(std::max(1.0, 1000.0 / rate_hz_)));
    timer_ = create_wall_timer(period, [this]() {publish_command();});

    RCLCPP_INFO(
      get_logger(),
      "publishing /cmd_vel at %.2f Hz: linear.x=%.3f linear.y=%.3f angular.z=%.3f",
      rate_hz_, linear_x_, linear_y_, angular_z_);
  }

private:
  void publish_command()
  {
    geometry_msgs::msg::Twist command;
    command.linear.x = linear_x_;
    command.linear.y = linear_y_;
    command.angular.z = angular_z_;
    publisher_->publish(command);
    RCLCPP_INFO_THROTTLE(
      get_logger(), *get_clock(), 1000,
      "cmd_vel linear.x=%.3f linear.y=%.3f angular.z=%.3f matched_subscribers=%zu",
      linear_x_, linear_y_, angular_z_, publisher_->get_subscription_count());
  }

  double rate_hz_{1.0};
  double linear_x_{0.0};
  double linear_y_{0.0};
  double angular_z_{0.0};
  rclcpp::Publisher<geometry_msgs::msg::Twist>::SharedPtr publisher_;
  rclcpp::TimerBase::SharedPtr timer_;
};

int main(int argc, char * argv[])
{
  rclcpp::init(argc, argv);
  try {
    rclcpp::spin(std::make_shared<WeaknetCmdvelPublisher>());
  } catch (const std::exception & error) {
    RCLCPP_ERROR(rclcpp::get_logger("weaknet_cmdvel_pub"), "%s", error.what());
  }
  rclcpp::shutdown();
  return 0;
}
