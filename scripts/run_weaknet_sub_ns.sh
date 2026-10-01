#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="weaknet_sub_ns"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROS_SETUP="${ROS_SETUP:-/opt/ros/${ROS_DISTRO:-humble}/setup.bash}"
WORKSPACE_SETUP="$WORKSPACE/install/setup.bash"
RUN_USER="${SUDO_USER:-${USER}}"
RELIABILITY="${1:-reliable}"
DEPTH="${2:-10}"
CSV_PATH="${3:-}"

case "$RELIABILITY" in
  reliable|best_effort)
    ;;
  *)
    echo "Usage: $0 [reliable|best_effort] [depth] [csv_path]" >&2
    exit 2
    ;;
esac

if [[ ! "$DEPTH" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: depth must be a positive integer" >&2
  exit 2
fi

if [[ -n "$CSV_PATH" ]]; then
  mkdir -p "$(dirname "$CSV_PATH")"
fi

if ! sudo ip netns exec "$NAMESPACE" true 2>/dev/null; then
  echo "Error: namespace '$NAMESPACE' does not exist." >&2
  echo "Run setup_weaknet_netns.sh up first." >&2
  exit 1
fi

if [[ ! -f "$ROS_SETUP" ]]; then
  echo "Error: ROS setup file not found: $ROS_SETUP" >&2
  exit 1
fi

if [[ ! -f "$WORKSPACE_SETUP" ]]; then
  echo "Error: workspace setup file not found: $WORKSPACE_SETUP" >&2
  echo "Build the workspace first: colcon build --packages-select weaknet_demo" >&2
  exit 1
fi

echo "Starting weaknet_sub with reliability=$RELIABILITY depth=$DEPTH csv_path=${CSV_PATH:-disabled}"

exec sudo ip netns exec "$NAMESPACE" \
  runuser -u "$RUN_USER" -- \
  bash -lc "
    source '$ROS_SETUP'
    source '$WORKSPACE_SETUP'
    export ROS_DOMAIN_ID=0
    export ROS_LOCALHOST_ONLY=0
    export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
    export FASTDDS_BUILTIN_TRANSPORTS=UDPv4
    exec ros2 run weaknet_demo weaknet_sub \
      --ros-args -p reliability:=$RELIABILITY -p depth:=$DEPTH \
      ${CSV_PATH:+-p csv_path:=$CSV_PATH}
  "
