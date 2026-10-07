#!/usr/bin/env bash
# Copy driver source and environment setup; build on Jetson, never copy WSL binaries.
set -Eeo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
JETSON_HOST="${WEAKNET_JETSON_HOST:-}"
if [[ -z "$JETSON_HOST" ]]; then
  echo 'Error: set WEAKNET_JETSON_HOST to the Jetson SSH target (user@host).' >&2
  exit 2
fi

ssh "$JETSON_HOST" 'mkdir -p ~/ros2exp_ws/src ~/ros2exp_ws/scripts'
scp -r "$WORKSPACE/src/jetson_base_driver" "$JETSON_HOST:~/ros2exp_ws/src/"
scp "$WORKSPACE/scripts/setup_phase12_jetson_local.sh" "$JETSON_HOST:~/ros2exp_ws/scripts/"
echo "Copied Jetson driver source and setup to $JETSON_HOST:~/ros2exp_ws."
echo 'Build on Jetson:'
echo '  source /opt/ros/humble/setup.bash'
echo '  source ~/yahboomcar_ros2_ws/yahboomcar_ws/install/setup.bash'
echo '  cd ~/ros2exp_ws && colcon build --packages-select jetson_base_driver --symlink-install'
echo 'The current driver is not restarted by this deployment script.'
