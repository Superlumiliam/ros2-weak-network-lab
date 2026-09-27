#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="weaknet_pub_ns"
ROS_SETUP="/opt/ros/humble/setup.bash"
WORKSPACE_SETUP="/home/liam/ros2exp_ws/install/setup.bash"
RUN_USER="${SUDO_USER:-${USER}}"
RELIABILITY="${1:-reliable}"
DEPTH="${2:-10}"

case "$RELIABILITY" in
  reliable|best_effort)
    ;;
  *)
    echo "Usage: $0 [reliable|best_effort] [depth]" >&2
    exit 2
    ;;
esac

if [[ ! "$DEPTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: depth must be a positive integer" >&2
  exit 2
fi

if ! sudo ip netns exec "$NAMESPACE" true 2>/dev/null; then
  echo "Error: namespace '$NAMESPACE' does not exist." >&2
  echo "Run setup_weaknet_netns.sh up first." >&2
  exit 1
fi

echo "Starting weaknet_pub with reliability=$RELIABILITY depth=$DEPTH"

exec sudo ip netns exec "$NAMESPACE" \
  runuser -u "$RUN_USER" -- \
  bash -lc "
    source '$ROS_SETUP'
    source '$WORKSPACE_SETUP'
    export ROS_DOMAIN_ID=0
    export ROS_LOCALHOST_ONLY=0
    export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
    export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
    exec ros2 run weaknet_demo weaknet_pub \
      --ros-args -p reliability:=$RELIABILITY -p depth:=$DEPTH
  "
