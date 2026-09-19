#include<memory>
#include<chrono>
#include"rclcpp/rclcpp.hpp"
#include"weaknet_demo/msg/weaknet_sample.hpp"

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);
    auto node = std::make_shared<rclcpp::Node>("weaknet_pub");
    auto publisher = node->create_publisher<weaknet_demo::msg::WeaknetSample>(
        "/weaknet/sample", 10);
    auto sequence = std::make_shared<std::uint64_t>(0);
    auto timer = node->create_wall_timer(
        std::chrono::milliseconds(50),
        [publisher,node,sequence](){
            weaknet_demo::msg::WeaknetSample message;
            message.sequence = (*sequence)++;
            message.send_time = node->get_clock()->now();
            message.payload = "hello from weaknet_pub";
            publisher->publish(message);
        }
    );
    rclcpp::spin(node);
    rclcpp::shutdown();
    return 0;
}