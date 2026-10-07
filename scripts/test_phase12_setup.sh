#!/usr/bin/env bash
# Offline regression checks; no ROS processes, firewall writes, or robot access.
set -eo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
phase12_test_dir=$(mktemp -d /tmp/weaknet-phase12-test.XXXXXX)
export phase12_test_dir
touch "$phase12_test_dir/setup.bash"
bash -n scripts/setup_phase12_wsl.sh scripts/setup_phase12_jetson_local.sh scripts/run_phase12_cmdvel_pub.sh scripts/deploy_phase12_gateway.sh
(
  set +e
  set +o pipefail
  before_flags=$-
  before_pipe=$(set -o | grep '^pipefail')
  source scripts/setup_phase12_wsl.sh help >/dev/null
  # Isolate daemon cleanup and network calls from the real host.
  timeout() { return 0; }
  ps() { return 0; }
  wslpath() { printf '%s\n' 'C:\phase12\setup_phase12_windows.ps1'; }
  WEAKNET_ROBOT_IP=192.0.2.10
  WEAKNET_WSL_LAN_IP=192.0.2.11
  WEAKNET_ROS_SETUP=$phase12_test_dir/setup.bash
  WEAKNET_WORKSPACE_SETUP=$phase12_test_dir/setup.bash
  WEAKNET_RUNTIME_DIR=$phase12_test_dir
  unset WEAKNET_CONTROL_DATA_PORT WEAKNET_CONTROL_PROFILE_PATH
  WEAKNET_DDS_DATA_PORT=0
  source scripts/setup_phase12_wsl.sh up >/dev/null || exit 1
  [[ $- == "$before_flags" ]] || exit 1
  [[ $(set -o | grep '^pipefail') == "$before_pipe" ]] || exit 1
  [[ $ROS_DOMAIN_ID == 61 && $FASTRTPS_DEFAULT_PROFILES_FILE == *super_client.xml ]] || exit 1
  grep -q '<port>0</port>' "$FASTRTPS_DEFAULT_PROFILES_FILE" || exit 1
  grep -q '<discoveryProtocol>SUPER_CLIENT</discoveryProtocol>' "$FASTRTPS_DEFAULT_PROFILES_FILE" || exit 1
  grep -q '<discoveryProtocol>CLIENT</discoveryProtocol>' "$PROFILE_PATH" || exit 1
  source scripts/setup_phase12_wsl.sh firewall >"$phase12_test_dir/firewall.txt" || exit 1
  grep -q -- "-RobotIP '192.0.2.10'" "$phase12_test_dir/firewall.txt" || exit 1
  WEAKNET_DDS_DATA_PORT=46000
  source scripts/setup_phase12_wsl.sh up >/dev/null 2>&1
  [[ $? == 2 && $- == "$before_flags" ]] || exit 1
  WEAKNET_DDS_DATA_PORT=0
  WEAKNET_ROBOT_IP=999.0.0.1
  source scripts/setup_phase12_wsl.sh up >/dev/null 2>&1
  [[ $? == 2 ]] || exit 1
  source scripts/run_phase12_cmdvel_pub.sh >/dev/null 2>&1
  [[ $? == 2 && $- == "$before_flags" ]] || exit 1
  [[ $(set -o | grep '^pipefail') == "$before_pipe" ]] || exit 1
)
(
  set +e
  set +o pipefail
  before_flags=$-
  source scripts/setup_phase12_jetson_local.sh help >/dev/null
  [[ $- == "$before_flags" ]] || exit 1
  # Fail before any robot-side mutations; ensure source returns to the caller.
  WEAKNET_ROBOT_ENV_FILE=$phase12_test_dir/nonexistent
  source scripts/setup_phase12_jetson_local.sh check >/dev/null 2>&1
  [[ $? == 1 && $- == "$before_flags" ]] || exit 1
  [[ $(set -o | grep '^pipefail') == *off ]] || exit 1
  find_existing_driver() { echo 123; }
  driver_env_matches() { return 1; }
  test_launch='/usr/bin/python3 /opt/ros/humble/bin/ros2 launch yahboomcar_ctrl yahboomcar_joy_launch.py'
  ps() {
    if [[ "$*" == *args=* ]]; then printf '%s\n' "$test_launch"; else id -u; fi
  }
  stopped=0
  stop_process_tree() { [[ $1 == 123 ]] || return 1; stopped=1; }
  take_over_vendor_launch >/dev/null || exit 1
  [[ $stopped == 1 ]] || exit 1
  stopped=0
  test_launch='/usr/bin/python3 /opt/ros/humble/bin/ros2 launch unrelated robot.launch.py'
  take_over_vendor_launch >/dev/null 2>&1
  [[ $? == 1 && $stopped == 0 ]] || exit 1
)
echo "PASS: source options, failure returns, CLIENT/SUPER_CLIENT profiles, legacy-port rejection, firewall generation, scoped vendor takeover."
echo "Fixtures retained at $phase12_test_dir"
