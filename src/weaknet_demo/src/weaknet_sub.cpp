#include<memory>
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <vector>
#include <chrono>
#include <string>

#include "rclcpp/rclcpp.hpp"
#include "weaknet_demo/msg/weaknet_sample.hpp"

struct SubscriberStats
{
    std::uint64_t received{0};
    std::uint64_t inferred_lost{0};
    std::uint64_t last_sequence{0};
    bool have_last{false};
    double sum_delay_ms{0.0};
    double min_delay_ms{0.0};
    double max_delay_ms{0.0};
    double first_receive_sec{0.0};
    double last_receive_sec{0.0};
    bool have_receive_window{false};
    std::vector<double> delay_samples_ms;
    double sum_delay_squared_ms{0.0};
};

int main(int argc, char * argv[])
{
    rclcpp::init(argc, argv);

    auto stats = std::make_shared<SubscriberStats>();
    auto node = std::make_shared<rclcpp::Node>("weaknet_sub");

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
      "subscriber QoS: reliability=%s history=KEEP_LAST depth=%lld",
      reliability.c_str(), static_cast<long long>(depth));

    auto subscription = node->create_subscription<weaknet_demo::msg::WeaknetSample>(
        "/weaknet/sample", qos,
         [node, stats](const weaknet_demo::msg::WeaknetSample::SharedPtr message)
        {
            if (stats->have_last && 
                message->sequence > stats->last_sequence + 1) {
                stats->inferred_lost +=
                message->sequence - stats->last_sequence - 1;
            }

            stats->last_sequence = message->sequence;
            stats->have_last = true;
            stats->received++;

            const auto receive_time = node->get_clock()->now();
            // const rclcpp::Time send_time(message->send_time);
            // const double delay_ms =
            // (receive_time - send_time).seconds() * 1000.0;
            const auto receive_steady_now =
            std::chrono::steady_clock::now().time_since_epoch();

            const auto receive_steady_ns =
              std::chrono::duration_cast<std::chrono::nanoseconds>(
                receive_steady_now).count();

            const double delay_ms =
              static_cast<double>(
                receive_steady_ns - message->steady_send_time_ns) / 1e6;


            stats->delay_samples_ms.push_back(delay_ms);
            stats->sum_delay_squared_ms += delay_ms * delay_ms;

            if (!stats->have_receive_window) {
                stats->first_receive_sec = receive_time.seconds();
                stats->have_receive_window = true;
            }

            stats->last_receive_sec = receive_time.seconds();

            stats->sum_delay_ms += delay_ms;
            if (stats->received == 1) 
            {
                stats->min_delay_ms = delay_ms;
                stats->max_delay_ms = delay_ms;
            } 
            else 
            {
                stats->min_delay_ms =
                std::min(stats->min_delay_ms, delay_ms);
                stats->max_delay_ms =
                std::max(stats->max_delay_ms, delay_ms);
            }
            RCLCPP_INFO(
                node->get_logger(),
                "seq=%llu send=%d.%09u recv=%.9f delay=%.3f ms payload='%s'",
                static_cast<unsigned long long>(message->sequence),
                message->send_time.sec,
                message->send_time.nanosec,
                receive_time.seconds(),
                delay_ms,
                message->payload.c_str()
            );
        }
    );
    (void)subscription;
    rclcpp::spin(node);

    const double average_delay_ms =
      stats->received > 0
      ? stats->sum_delay_ms /
        static_cast<double>(stats->received)
      : 0.0;

    const double duration_sec = stats->last_receive_sec - stats->first_receive_sec;
    const double receive_rate_hz =
      (stats->received > 1 && duration_sec > 0.0)
      ? static_cast<double>(stats->received - 1) / duration_sec
      : 0.0;

    double p95_delay_ms = 0.0;
    double latency_jitter_ms = 0.0;
    if (!stats->delay_samples_ms.empty()) 
    {
      auto sorted_delays = stats->delay_samples_ms;
      std::sort(sorted_delays.begin(), sorted_delays.end());

      const auto p95_index = static_cast<std::size_t>(
        0.95 * static_cast<double>(sorted_delays.size() - 1));

      p95_delay_ms = sorted_delays[p95_index];

      const double average_delay_ms =
        stats->sum_delay_ms /
        static_cast<double>(stats->delay_samples_ms.size());

      const double mean_square =
        stats->sum_delay_squared_ms /
        static_cast<double>(stats->delay_samples_ms.size());

      const double variance =
        std::max(0.0, mean_square - average_delay_ms * average_delay_ms);

      latency_jitter_ms = std::sqrt(variance);
    }

    RCLCPP_INFO(
      node->get_logger(),
      "summary: received=%llu inferred_lost=%llu "
      "avg=%.3f ms min=%.3f ms max=%.3f ms duration=%.3f s rate=%.3f Hz "
      "p95=%.3f ms jitter_stddev=%.3f ms",
      static_cast<unsigned long long>(stats->received),
      static_cast<unsigned long long>(stats->inferred_lost),
      average_delay_ms,
      stats->min_delay_ms,
      stats->max_delay_ms,
      duration_sec,
      receive_rate_hz,
      p95_delay_ms,
      latency_jitter_ms
    );
    return 0;
}
