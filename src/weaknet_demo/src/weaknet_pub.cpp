#include <chrono>
#include <cstdint>
#include <memory>
#include <string>

#include "rclcpp/rclcpp.hpp"
#include "weaknet_demo/msg/weaknet_sample.hpp"

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    auto node = std::make_shared<rclcpp::Node>("weaknet_pub");

    const auto reliability =
        node->declare_parameter<std::string>("reliability", "reliable");
    const auto depth =
        node->declare_parameter<std::int64_t>("depth", 10);

    if (depth <= 0) {
        RCLCPP_FATAL(node->get_logger(), "depth must be greater than zero");
        rclcpp::shutdown();
        return 1;
    }

    rclcpp::QoS qos(rclcpp::KeepLast(static_cast<std::size_t>(depth)));
    if (reliability == "reliable") {
        qos.reliable();
    } else if (reliability == "best_effort") {
        qos.best_effort();
    } else {
        RCLCPP_FATAL(
            node->get_logger(),
            "Unsupported reliability '%s'; use 'reliable' or 'best_effort'",
            reliability.c_str());
        rclcpp::shutdown();
        return 1;
    }

    RCLCPP_INFO(
        node->get_logger(),
        "publisher QoS: reliability=%s history=KEEP_LAST depth=%lld",
        reliability.c_str(), static_cast<long long>(depth));

    auto publisher = node->create_publisher<weaknet_demo::msg::WeaknetSample>(
        "/weaknet/sample", qos);
    auto sequence = std::make_shared<std::uint64_t>(0);
    auto timer = node->create_wall_timer(
        std::chrono::milliseconds(50),
        [publisher,node,sequence](){
            weaknet_demo::msg::WeaknetSample message;
            message.sequence = (*sequence)++;
            message.send_time = node->get_clock()->now();
            const auto steady_now = std::chrono::steady_clock::now().time_since_epoch();
            message.steady_send_time_ns =
                std::chrono::duration_cast<std::chrono::nanoseconds>(
                steady_now).count();
            message.payload = "hello from weaknet_pub";
            publisher->publish(message);
        }
    );
    rclcpp::spin(node);
    rclcpp::shutdown();
    return 0;
}
