#!/usr/bin/env bash

# Compatibility launcher. Uses the same environment as normal ros2 commands.

# Never leak shell options into a caller that accidentally sources this helper.
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "This helper must be executed, not sourced; source setup_phase12_wsl.sh first." >&2
  return 2
fi

set -Eeo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ROS_DISTRO_VALUE="${WEAKNET_ROS_DISTRO:-${ROS_DISTRO:-humble}}"

if [[ -z "${ROS_DOMAIN_ID:-}" || ! -f "${FASTRTPS_DEFAULT_PROFILES_FILE:-}" ]]; then
  echo "Error: Phase 12 DDS environment is not available." >&2
  echo "Run this first in the same WSL shell:" >&2
  echo "  export WEAKNET_ROBOT_IP=<ROBOT_IP>" >&2
  echo "  source $WORKSPACE/scripts/setup_phase12_wsl.sh up" >&2
  exit 2
fi

# ROS setup files are not guaranteed to be nounset-safe.
source "/opt/ros/${ROS_DISTRO_VALUE}/setup.bash"
source "$WORKSPACE/install/setup.bash"
echo "Phase 12 publisher profile: $FASTRTPS_DEFAULT_PROFILES_FILE (automatic port)" >&2
exec ros2 run weaknet_demo weaknet_cmdvel_pub "$@"
