#!/usr/bin/env bash
# Purpose: Configure Jetson ROS 2/Fast DDS, Discovery Server, and the repository base driver after reboot.

# This file is intentionally usable both as an executable and via `source`.
# Do not enable errexit when sourced: errexit is a shell-wide option and would
# make a harmless diagnostic failure terminate the user's SSH shell.
WEAKNET_PHASE12_SOURCED=0
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  WEAKNET_PHASE12_SOURCED=1
else
  set -Eeo pipefail
fi

ACTION="${1:-up}"
ROS_DISTRO="${WEAKNET_ROS_DISTRO:-humble}"
ROS_DOMAIN_ID_VALUE="${WEAKNET_ROS_DOMAIN_ID:-61}"
DISCOVERY_PORT="${WEAKNET_DISCOVERY_SERVER_PORT:-42100}"
# Jetson runs several ROS processes. Each participant must get its own TCP
# listener, so 0 asks Fast DDS to allocate an available port per process.
JETSON_DDS_DATA_PORT="${WEAKNET_JETSON_DDS_DATA_PORT:-0}"
JETSON_IP="${WEAKNET_JETSON_IP:-${WEAKNET_DISCOVERY_BIND_IP:-}}"
SERVER_GUID_PREFIX="${WEAKNET_SERVER_GUID_PREFIX:-44.53.00.5f.45.50.52.4f.53.49.4d.41}"
VENDOR_WORKSPACE="${WEAKNET_VENDOR_WORKSPACE:-$HOME/yahboomcar_ros2_ws/yahboomcar_ws}"
ROBOT_WORKSPACE="${WEAKNET_ROBOT_WORKSPACE:-$HOME/ros2exp_ws}"
DRIVER_PACKAGE="${WEAKNET_ROBOT_DRIVER_PACKAGE:-jetson_base_driver}"
DRIVER_EXECUTABLE="${WEAKNET_ROBOT_DRIVER_EXECUTABLE:-Mcnamu_driver_M1}"
ROBOT_ENV_FILE="${WEAKNET_ROBOT_ENV_FILE:-}"
CONTROL_TOPIC="${WEAKNET_CONTROL_TOPIC:-/cmd_vel}"
JOYSTICK_PROCESS_PATTERN="${WEAKNET_ROBOT_JOYSTICK_PROCESS_PATTERN:-yahboom_joy_M1}"

STATE_DIR="${WEAKNET_REMOTE_STATE_DIR:-$HOME/.cache/weaknet_phase12}"
SERVER_PID_FILE="$STATE_DIR/fastdds_discovery.pid"
DRIVER_PID_FILE="$STATE_DIR/robot_driver.pid"
SERVER_LOG="$STATE_DIR/fastdds_discovery.log"
DRIVER_LOG="$STATE_DIR/robot_driver.log"
ENV_FILE="$STATE_DIR/environment.sh"
PROFILE_PATH="$STATE_DIR/fastdds_tcp_jetson.xml"
SUPER_PROFILE_PATH="$STATE_DIR/fastdds_tcp_jetson_super_client.xml"
ROS_SETUP="/opt/ros/${ROS_DISTRO}/setup.bash"
WORKSPACE_SETUP="${ROBOT_WORKSPACE}/install/setup.bash"

usage() {
  cat <<'USAGE'
Usage:
  ./setup_phase12_jetson_local.sh up
  ./setup_phase12_jetson_local.sh takeover  # stop the known vendor joystick launch first
  ./setup_phase12_jetson_local.sh check
  ./setup_phase12_jetson_local.sh verify  # receive one /cmd_vel sample, no publishing
  ./setup_phase12_jetson_local.sh down

Optional configuration:
  WEAKNET_ROS_DISTRO           ROS distribution, default: humble.
  WEAKNET_ROS_DOMAIN_ID        ROS domain, default: 61.
  WEAKNET_JETSON_IP            Jetson LAN address; auto-detected from the default route.
  WEAKNET_SERVER_GUID_PREFIX   Fast DDS Discovery Server GUID prefix, default: server id 0.
  WEAKNET_DISCOVERY_SERVER_PORT Fast DDS TCP discovery port, default: 42100.
  WEAKNET_JETSON_DDS_DATA_PORT Fast DDS TCP data port, default: 0 (automatic per process).
  WEAKNET_VENDOR_WORKSPACE     Vendor underlay providing yahboomcar_msgs.
  WEAKNET_ROBOT_WORKSPACE      Repository workspace overlay, default: ~/ros2exp_ws.
  WEAKNET_ROBOT_DRIVER_PACKAGE Driver package, default: jetson_base_driver.
  WEAKNET_ROBOT_DRIVER_EXECUTABLE Driver executable, default: Mcnamu_driver_M1.
  WEAKNET_ROBOT_ENV_FILE        Optional vendor-specific environment file.
  WEAKNET_CONTROL_TOPIC         Read-only topic checked by up/check, default: /cmd_vel.
  WEAKNET_ROBOT_JOYSTICK_PROCESS_PATTERN
                                Optional joystick process pattern used for warnings.

Run this script directly to start services. To keep the exported ROS variables
in the current terminal, source it instead:
  source ./setup_phase12_jetson_local.sh up
USAGE
}

case "$ACTION" in
  up|takeover|check|status|verify|down)
    ;;
  help|-h|--help)
    usage
    if [[ "$WEAKNET_PHASE12_SOURCED" -eq 1 ]]; then
      return 0
    fi
    exit 0
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    usage >&2
    if [[ "$WEAKNET_PHASE12_SOURCED" -eq 1 ]]; then
      return 2
    fi
    exit 2
    ;;
esac

import_interactive_environment() {
  local environment_line
  if [[ -n "$ROBOT_ENV_FILE" ]]; then
    if [[ ! -f "$ROBOT_ENV_FILE" ]]; then
      echo "Error: robot environment file not found: $ROBOT_ENV_FILE" >&2
      return 1
    fi
    # shellcheck disable=SC1090
    source "$ROBOT_ENV_FILE"
    return
  fi

  if [[ -f "$HOME/.bashrc" ]]; then
    while IFS= read -r environment_line; do
      if [[ "$environment_line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        export "$environment_line"
      fi
    done < <(bash -ic 'env' 2>/dev/null)
  fi
}

detect_jetson_ip() {
  if [[ -n "$JETSON_IP" ]]; then
    return 0
  fi

  local default_device
  default_device="$(ip -4 route show default 2>/dev/null | \
    awk '{for (i = 1; i <= NF; ++i) if ($i == "dev") {print $(i + 1); exit}}')"
  if [[ -n "$default_device" ]]; then
    JETSON_IP="$(ip -4 -o addr show dev "$default_device" scope global 2>/dev/null | \
      awk '{split($4, address, "/"); print address[1]; exit}')"
  fi
  if [[ -z "$JETSON_IP" ]]; then
    echo "Error: could not determine the Jetson LAN IP from the default route." >&2
    echo "Set WEAKNET_JETSON_IP explicitly and run the script again." >&2
    return 1
  fi
}

prepare_environment() {
  import_interactive_environment || return 1
  detect_jetson_ip || return 1
  if [[ "$JETSON_DDS_DATA_PORT" != 0 ]]; then
    echo 'Error: unset WEAKNET_JETSON_DDS_DATA_PORT; concurrent participants need automatic ports.' >&2
    return 2
  fi

  if [[ ! -f "$ROS_SETUP" ]]; then
    echo "Error: ROS setup not found: $ROS_SETUP" >&2
    return 1
  fi
  if [[ ! -f "$WORKSPACE_SETUP" ]]; then
    echo "Error: repository workspace overlay not found: $WORKSPACE_SETUP" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$ROS_SETUP" || return 1
  if [[ -f "$VENDOR_WORKSPACE/install/setup.bash" ]]; then
    source "$VENDOR_WORKSPACE/install/setup.bash" || return 1
  fi
  # shellcheck disable=SC1090
  source "$WORKSPACE_SETUP" || return 1
  export ROS_DOMAIN_ID="$ROS_DOMAIN_ID_VALUE"
  export RMW_IMPLEMENTATION="rmw_fastrtps_cpp"
  export ROS_LOCALHOST_ONLY=0
  write_fastdds_profile "$PROFILE_PATH" CLIENT || return 1
  write_fastdds_profile "$SUPER_PROFILE_PATH" SUPER_CLIENT || return 1
  export FASTRTPS_DEFAULT_PROFILES_FILE="$SUPER_PROFILE_PATH"
  export ROS_DISCOVERY_SERVER="TCPv4:[${JETSON_IP}]:${DISCOVERY_PORT}"
  unset FASTDDS_BUILTIN_TRANSPORTS FASTDDS_DEFAULT_PROFILES_FILE ROS_SUPER_CLIENT
}

write_fastdds_profile() {
  local profile_path="$1"
  local discovery_protocol="$2"
  mkdir -p "$STATE_DIR" || return 1
  cat > "$profile_path" <<EOF
<?xml version="1.0" encoding="UTF-8" ?>
<dds xmlns="http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles">
  <profiles>
    <transport_descriptors>
      <transport_descriptor>
        <transport_id>weaknet_tcp_jetson_transport</transport_id>
        <type>TCPv4</type>
        <wan_addr>${JETSON_IP}</wan_addr>
        <interfaceWhiteList>
          <address>${JETSON_IP}</address>
        </interfaceWhiteList>
        <listening_ports>
          <port>${JETSON_DDS_DATA_PORT}</port>
        </listening_ports>
      </transport_descriptor>
    </transport_descriptors>

    <participant profile_name="weaknet_tcp_jetson" is_default_profile="true">
      <rtps>
        <builtin>
          <discovery_config>
            <discoveryProtocol>${discovery_protocol}</discoveryProtocol>
            <discoveryServersList>
              <RemoteServer prefix="${SERVER_GUID_PREFIX}">
                <metatrafficUnicastLocatorList>
                  <locator>
                    <tcpv4>
                      <address>${JETSON_IP}</address>
                      <port>${DISCOVERY_PORT}</port>
                      <physical_port>${DISCOVERY_PORT}</physical_port>
                    </tcpv4>
                  </locator>
                </metatrafficUnicastLocatorList>
              </RemoteServer>
            </discoveryServersList>
          </discovery_config>
        </builtin>
        <useBuiltinTransports>false</useBuiltinTransports>
        <userTransports>
          <transport_id>weaknet_tcp_jetson_transport</transport_id>
        </userTransports>
      </rtps>
    </participant>
  </profiles>
</dds>
EOF
}

write_environment_file() {
  mkdir -p "$STATE_DIR" || return 1
  cat > "$ENV_FILE" <<EOF
# Purpose: Export the Phase 12 ROS 2/Fast DDS environment on the Jetson.
export ROS_DOMAIN_ID=$ROS_DOMAIN_ID_VALUE
export RMW_IMPLEMENTATION=rmw_fastrtps_cpp
export ROS_LOCALHOST_ONLY=0
export FASTRTPS_DEFAULT_PROFILES_FILE="$SUPER_PROFILE_PATH"
export ROS_DISCOVERY_SERVER="TCPv4:[${JETSON_IP}]:${DISCOVERY_PORT}"
unset FASTDDS_BUILTIN_TRANSPORTS FASTDDS_DEFAULT_PROFILES_FILE ROS_SUPER_CLIENT
EOF
}

pid_is_process() {
  local pid_file="$1"
  local pattern="$2"
  [[ -s "$pid_file" ]] || return 1
  local pid
  pid="$(cat "$pid_file")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= | grep -Fq "$pattern"
}

discovery_listener_pid() {
  ss -lntpH | awk -v port=":${DISCOVERY_PORT}" '
    index($4, port) {match($0, /pid=[0-9]+/); if (RSTART) {print substr($0, RSTART + 4, RLENGTH - 4); exit}}'
}

collect_descendants() {
  local parent_pid="$1"
  local child_pid
  while read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    collect_descendants "$child_pid"
    echo "$child_pid"
  done < <(pgrep -P "$parent_pid" || true)
}

stop_process_tree() {
  local pid="$1"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  local descendants
  descendants="$(collect_descendants "$pid")"
  if [[ -n "$descendants" ]]; then
    kill -TERM $descendants 2>/dev/null || true
  fi
  kill -TERM "$pid" 2>/dev/null || true

  for _ in 1 2 3 4 5; do
    local alive=0
    local candidate
    for candidate in "$pid" $descendants; do
      if kill -0 "$candidate" 2>/dev/null &&
        [[ "$(ps -o stat= -p "$candidate" 2>/dev/null)" != Z* ]]; then
        alive=1
        break
      fi
    done
    [[ "$alive" -eq 0 ]] && return 0
    sleep 1
  done
  echo "Error: process tree rooted at PID $pid did not stop after SIGTERM." >&2
  return 1
}

find_existing_driver() {
  local driver_pid parent_pid
  driver_pid="$(pgrep -f -- "$DRIVER_EXECUTABLE" | head -n1 || true)"
  [[ -n "$driver_pid" ]] || return 1
  parent_pid="$(ps -o ppid= -p "$driver_pid" 2>/dev/null | tr -d ' ' || true)"
  if [[ -n "$parent_pid" && "$parent_pid" != "1" ]] &&
    ps -p "$parent_pid" -o args= 2>/dev/null | grep -Eq 'ros2 (launch|run)'; then
    echo "$parent_pid"
  else
    echo "$driver_pid"
  fi
}

driver_process_is_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -Eq "ros2 (launch|run)|${DRIVER_EXECUTABLE}"
}

driver_env_matches() {
  local pid="$1"
  [[ -r "/proc/${pid}/environ" ]] || return 1
  local process_env
  process_env="$(tr '\0' '\n' < "/proc/${pid}/environ")"
  grep -Fqx "ROS_DOMAIN_ID=${ROS_DOMAIN_ID_VALUE}" <<<"$process_env" &&
    grep -Fqx "RMW_IMPLEMENTATION=rmw_fastrtps_cpp" <<<"$process_env" &&
    grep -Fqx "ROS_LOCALHOST_ONLY=0" <<<"$process_env" &&
    grep -Fqx "FASTRTPS_DEFAULT_PROFILES_FILE=${PROFILE_PATH}" <<<"$process_env" &&
    grep -Fqx "ROS_DISCOVERY_SERVER=TCPv4:[${JETSON_IP}]:${DISCOVERY_PORT}" <<<"$process_env"
}

driver_package_matches() {
  local args
  args="$(ps -p "$1" -o args=)" || return 1
  [[ "$args" == *"ros2 run $DRIVER_PACKAGE $DRIVER_EXECUTABLE"* ||
     "$args" == *"/lib/$DRIVER_PACKAGE/$DRIVER_EXECUTABLE"* ]]
}

joystick_process_is_alive() {
  pgrep -f -- "$JOYSTICK_PROCESS_PATTERN" >/dev/null 2>&1
}

start_discovery_server() {
  local fastdds_bin
  fastdds_bin="$(command -v fastdds)"
  if pid_is_process "$SERVER_PID_FILE" "fastdds discovery"; then
    echo "Discovery Server already running: PID $(cat "$SERVER_PID_FILE")"
    return
  fi

  local listener_pid
  listener_pid="$(discovery_listener_pid)"
  if [[ -n "$listener_pid" ]]; then
    if ! ps -p "$listener_pid" -o args= | grep -Eq 'fast-discovery|fastdds discovery'; then
      echo "Error: TCP port ${DISCOVERY_PORT} is already used by PID ${listener_pid}." >&2
      return 1
    fi
    echo "$listener_pid" > "$SERVER_PID_FILE"
    echo "Existing Discovery Server adopted: PID $listener_pid"
    return
  fi

  # The Discovery Server is a SERVER participant. Do not let the client
  # profile used by the robot driver or ROS_DISCOVERY_SERVER alter its role.
  nohup env -u FASTRTPS_DEFAULT_PROFILES_FILE -u FASTDDS_DEFAULT_PROFILES_FILE \
    -u ROS_SUPER_CLIENT -u ROS_DISCOVERY_SERVER \
    "$fastdds_bin" discovery \
    -i 0 \
    -t "$JETSON_IP" \
    -q "$DISCOVERY_PORT" \
    >"$SERVER_LOG" 2>&1 &
  echo $! > "$SERVER_PID_FILE"
  sleep 2
  if [[ -z "$(discovery_listener_pid)" ]]; then
    echo "Error: Discovery Server did not start; log: $SERVER_LOG" >&2
    return 1
  fi
  echo "Discovery Server started: PID $(cat "$SERVER_PID_FILE")"
}

start_driver() {
  local existing_pid=""
  if [[ -s "$DRIVER_PID_FILE" ]] && driver_process_is_alive "$(cat "$DRIVER_PID_FILE")"; then
    existing_pid="$(cat "$DRIVER_PID_FILE")"
  else
    rm -f "$DRIVER_PID_FILE"
    existing_pid="$(find_existing_driver || true)"
  fi

  if [[ -n "$existing_pid" ]]; then
    if driver_env_matches "$existing_pid" && driver_package_matches "$existing_pid"; then
      echo "$existing_pid" > "$DRIVER_PID_FILE"
      echo "Robot driver already configured: PID $existing_pid"
      return
    fi
    echo "Error: an existing $DRIVER_EXECUTABLE uses a different package or ROS/Fast DDS environment (PID $existing_pid)." >&2
    echo "Stop that vendor driver explicitly before running this setup script; no duplicate driver will be started." >&2
    echo "For the standard yahboomcar_joy_launch.py only, use: source ~/ros2exp_ws/scripts/setup_phase12_jetson_local.sh takeover" >&2
    return 1
  fi

  nohup env FASTRTPS_DEFAULT_PROFILES_FILE="$PROFILE_PATH" \
    ros2 run "$DRIVER_PACKAGE" "$DRIVER_EXECUTABLE" \
    </dev/null >"$DRIVER_LOG" 2>&1 &
  echo $! > "$DRIVER_PID_FILE"
  sleep 3
  if ! driver_process_is_alive "$(cat "$DRIVER_PID_FILE")"; then
    echo "Error: robot driver did not stay running; log: $DRIVER_LOG" >&2
    return 1
  fi
  echo "Robot driver started: PID $(cat "$DRIVER_PID_FILE")"
}

show_status() {
  echo "Jetson IP: $JETSON_IP"
  echo "Environment file: $ENV_FILE"
  echo "DDS profile: $PROFILE_PATH"
  echo "CLI profile: $SUPER_PROFILE_PATH"
  if [[ "$JETSON_DDS_DATA_PORT" == "0" ]]; then
    echo "DDS data port: automatic per participant"
  else
    echo "DDS data port: $JETSON_DDS_DATA_PORT"
  fi
  echo "--- Discovery Server ---"
  if pid_is_process "$SERVER_PID_FILE" "fastdds discovery"; then
    echo "running: PID $(cat "$SERVER_PID_FILE")"
  else
    local listener_pid
    listener_pid="$(discovery_listener_pid)"
    if [[ -n "$listener_pid" ]]; then
      echo "running but unmanaged: PID $listener_pid"
    else
      echo "not running"
    fi
  fi
  ss -lntp | grep ":${DISCOVERY_PORT} " || true
  echo "--- Robot driver (no joystick bringup) ---"
  if [[ -s "$DRIVER_PID_FILE" ]] && driver_process_is_alive "$(cat "$DRIVER_PID_FILE")"; then
    echo "running: PID $(cat "$DRIVER_PID_FILE")"
  else
    local existing_pid
    existing_pid="$(find_existing_driver || true)"
    if [[ -n "$existing_pid" ]]; then
      echo "running but unmanaged: PID $existing_pid"
    else
      echo "not running"
    fi
  fi
  ps -ef | grep -E '[M]cnamu_driver_M1|[y]ahboom_joy_M1|[j]oy_node' || true
  echo "--- Talker process candidates ---"
  ps -ef | grep -E '[t]alker|[d]emo_nodes_cpp' || true
  echo "--- Optional joystick control ---"
  if joystick_process_is_alive; then
    echo "WARNING: joystick control process is running; do not run the experiment publisher at the same time."
  else
    echo "not running (optional)"
  fi
  echo "--- ROS graph ---"
  (
    export FASTRTPS_DEFAULT_PROFILES_FILE="$SUPER_PROFILE_PATH"
    ros2 node list --no-daemon --spin-time "${WEAKNET_DISCOVERY_WAIT_S:-5}" || true
    echo "--- Control topic: $CONTROL_TOPIC ---"
    ros2 topic info --no-daemon --spin-time "${WEAKNET_DISCOVERY_WAIT_S:-5}" \
      "$CONTROL_TOPIC" --verbose || true
  ) || true
}

stop_pid_file() {
  local pid_file="$1"
  local label="$2"
  if [[ -s "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      stop_process_tree "$pid"
      echo "$label stop requested: PID $pid"
    fi
    rm -f "$pid_file"
  fi
}

stop_existing_driver() {
  local existing_pid
  existing_pid="$(find_existing_driver || true)"
  if [[ -n "$existing_pid" ]]; then
    stop_process_tree "$existing_pid"
    echo "Robot driver stop requested: PID $existing_pid"
  fi
}

stop_discovery_server() {
  local tracked_pid=""
  if [[ -s "$SERVER_PID_FILE" ]]; then
    tracked_pid="$(cat "$SERVER_PID_FILE")"
    stop_pid_file "$SERVER_PID_FILE" "Discovery Server"
  fi

  local listener_pid
  listener_pid="$(discovery_listener_pid)"
  if [[ -n "$listener_pid" && "$listener_pid" != "$tracked_pid" ]]; then
    stop_process_tree "$listener_pid"
    echo "Discovery Server listener stop requested: PID $listener_pid"
  fi
}

take_over_vendor_launch() {
  local existing_pid args owner
  existing_pid="$(find_existing_driver || true)"
  [[ -n "$existing_pid" ]] || return 0
  driver_env_matches "$existing_pid" && return 0
  args="$(ps -p "$existing_pid" -o args=)" || return 1
  owner="$(ps -p "$existing_pid" -o uid= | tr -d ' ')" || return 1
  if [[ "$owner" != "$(id -u)" || "$args" != *'/ros2 launch yahboomcar_ctrl yahboomcar_joy_launch.py'* ]]; then
    echo "Error: takeover only stops this user's standard yahboomcar_joy_launch.py; inspect PID $existing_pid." >&2
    return 1
  fi
  echo "Stopping verified vendor joystick/driver launch: PID $existing_pid"
  stop_process_tree "$existing_pid" || return 1
}

weaknet_phase12_main() {
  prepare_environment || return 1
  mkdir -p "$STATE_DIR" || return 1

  case "$ACTION" in
    up|takeover)
      if [[ "$ACTION" == takeover ]]; then
        take_over_vendor_launch || return 1
      fi
      if joystick_process_is_alive; then
        echo "Error: a joystick control process is running; refusing to start the base driver." >&2
        echo "Stop the intended joystick launch first, verify the robot is stationary, then retry." >&2
        return 1
      fi
      write_environment_file || return 1
      start_discovery_server || return 1
      start_driver || return 1
      reset_cli_daemon
      show_status || return 1
      ;;
    check|status)
      reset_cli_daemon
      show_status || return 1
      ;;
    verify)
      echo "Checking actual zero Twist receipt on $CONTROL_TOPIC (15 second limit)..."
      if timeout --signal=INT --kill-after=3s 15s ros2 topic echo \
        "$CONTROL_TOPIC" geometry_msgs/msg/Twist \
        --qos-reliability reliable --qos-durability volatile \
        --filter 'all(v == 0.0 for v in (m.linear.x, m.linear.y, m.linear.z, m.angular.x, m.angular.y, m.angular.z))' \
        --once; then
        echo 'PASS: received a live Twist with all six components zero.'
      else
        echo 'FAIL: no verified zero Twist receipt; inspect TCP data connections and firewall.' >&2
        return 1
      fi
      ;;
    down)
      if [[ -s "$DRIVER_PID_FILE" ]]; then
        stop_pid_file "$DRIVER_PID_FILE" "Robot driver" || return 1
      else
        stop_existing_driver || return 1
      fi
      stop_discovery_server || return 1
      ;;
  esac
}

reset_cli_daemon() {
  timeout 5s ros2 daemon stop >/dev/null 2>&1 || true
  # Restrict cleanup to this user's ROS daemon for this exact domain.
  local pid
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill -TERM "$pid" 2>/dev/null || true
  done < <(ps -u "$(id -u)" -o pid=,comm=,args= | awk -v domain="$ROS_DOMAIN_ID" '
    ($2 == "python3" || $2 == "python") && /ros2cli\.daemon\.daemonize/ {
      named = 0; matched = 0
      for (i = 3; i <= NF; i++) {
        if ($i == "--name" && $(i+1) == "ros2-daemon") named = 1
        if ($i == "--ros-domain-id" && $(i+1) == domain) matched = 1
      }
      if (named && matched) print $1
    }')
}

weaknet_phase12_main "$@"
WEAKNET_PHASE12_STATUS=$?
if [[ "$WEAKNET_PHASE12_SOURCED" -eq 1 ]]; then
  return "$WEAKNET_PHASE12_STATUS"
fi
exit "$WEAKNET_PHASE12_STATUS"
