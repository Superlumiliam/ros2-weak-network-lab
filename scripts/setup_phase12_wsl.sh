#!/usr/bin/env bash
# Purpose: Configure the current WSL2 shell for Phase 12 Fast DDS communication with a robot.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This script must be sourced so its environment changes remain in the current shell." >&2
  echo "Usage: source $0 [up|check|firewall]" >&2
  exit 2
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
ACTION="${1:-up}"

WEAKNET_ROS_DISTRO="${WEAKNET_ROS_DISTRO:-${ROS_DISTRO:-humble}}"
WEAKNET_ROS_SETUP="${WEAKNET_ROS_SETUP:-/opt/ros/${WEAKNET_ROS_DISTRO}/setup.bash}"
WEAKNET_WORKSPACE_SETUP="${WEAKNET_WORKSPACE_SETUP:-$WORKSPACE/install/setup.bash}"
WEAKNET_ROBOT_IP="${WEAKNET_ROBOT_IP:-}"
WEAKNET_ROS_DOMAIN_ID="${WEAKNET_ROS_DOMAIN_ID:-61}"
WEAKNET_DISCOVERY_SERVER_PORT="${WEAKNET_DISCOVERY_SERVER_PORT:-42100}"
WEAKNET_DDS_DATA_PORT="${WEAKNET_DDS_DATA_PORT:-0}"
WEAKNET_WSL_LAN_IP="${WEAKNET_WSL_LAN_IP:-}"
WEAKNET_SERVER_GUID_PREFIX="${WEAKNET_SERVER_GUID_PREFIX:-44.53.00.5f.45.50.52.4f.53.49.4d.41}"
WEAKNET_RUNTIME_DIR="${WEAKNET_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/tmp}/weaknet_phase12}"
PROFILE_TEMPLATE="$WORKSPACE/config/phase12/fastdds_tcp_client.xml.in"
PROFILE_PATH="$WEAKNET_RUNTIME_DIR/fastdds_tcp_client.xml"
SUPER_PROFILE_PATH="$WEAKNET_RUNTIME_DIR/fastdds_tcp_super_client.xml"

weaknet_phase12_wsl_usage() {
  cat <<'USAGE'
Usage:
  source scripts/setup_phase12_wsl.sh up
  source scripts/setup_phase12_wsl.sh check
  source scripts/setup_phase12_wsl.sh firewall

Required configuration:
  WEAKNET_ROBOT_IP             Robot LAN address.

Optional configuration:
  WEAKNET_ROS_DISTRO           ROS distribution, default: humble.
  WEAKNET_ROS_DOMAIN_ID        ROS domain, default: 61.
  WEAKNET_DISCOVERY_SERVER_PORT Fast DDS TCP discovery port, default: 42100.
  WEAKNET_DDS_DATA_PORT        WSL TCP data port, default: 0 (automatic per process).
  WEAKNET_WSL_LAN_IP           WSL address reachable from the robot; auto-detected from the route to WEAKNET_ROBOT_IP.
  WEAKNET_SERVER_GUID_PREFIX   Fast DDS server GUID prefix for server id 0.
The firewall action prints the Windows administrator command for the actual
Linux ephemeral port range. It does not start ROS or change firewall rules.
USAGE
}

weaknet_phase12_validate_port() {
  local label="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]{1,5}$ ]] || (( 10#$value < 1 || 10#$value > 65535 )); then
    echo "Error: $label must be an integer from 1 to 65535: $value" >&2
    return 2
  fi
}

weaknet_phase12_require_ipv4() {
  if [[ -z "$WEAKNET_ROBOT_IP" ]]; then
    echo "Error: set WEAKNET_ROBOT_IP before sourcing this script." >&2
    return 2
  fi

  if [[ ! "$WEAKNET_ROBOT_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "Error: WEAKNET_ROBOT_IP must be an IPv4 address." >&2
    return 2
  fi
  local octet
  local -a octets
  IFS=. read -r -a octets <<< "$WEAKNET_ROBOT_IP"
  for octet in "${octets[@]}"; do
    (( 10#$octet <= 255 )) || { echo "Error: invalid IPv4 address." >&2; return 2; }
  done
}

weaknet_phase12_validate_configuration() {
  weaknet_phase12_require_ipv4 || return
  weaknet_phase12_validate_port WEAKNET_DISCOVERY_SERVER_PORT "$WEAKNET_DISCOVERY_SERVER_PORT" || return
  if [[ "$WEAKNET_DDS_DATA_PORT" != 0 || -n "${WEAKNET_CONTROL_DATA_PORT:-}" ]]; then
    echo "Error: obsolete fixed-port settings detected. Run:" >&2
    echo "  unset WEAKNET_DDS_DATA_PORT WEAKNET_CONTROL_DATA_PORT WEAKNET_CONTROL_PROFILE_PATH" >&2
    echo "Then source this setup again; each participant must use port 0." >&2
    return 2
  fi
}

weaknet_phase12_render_profile() {
  local discovery_protocol="${1:-CLIENT}"
  local profile_path="${2:-$PROFILE_PATH}"
  local data_port="${3:-$WEAKNET_DDS_DATA_PORT}"
  if [[ ! -f "$PROFILE_TEMPLATE" ]]; then
    echo "Error: missing Fast DDS profile template: $PROFILE_TEMPLATE" >&2
    return 1
  fi

  mkdir -p "$WEAKNET_RUNTIME_DIR" || return
  sed \
    -e "s|@ROBOT_IP@|$WEAKNET_ROBOT_IP|g" \
    -e "s|@DISCOVERY_SERVER_PORT@|$WEAKNET_DISCOVERY_SERVER_PORT|g" \
    -e "s|@DDS_DATA_PORT@|$data_port|g" \
    -e "s|@WSL_LAN_IP@|$WEAKNET_WSL_LAN_IP|g" \
    -e "s|@SERVER_GUID_PREFIX@|$WEAKNET_SERVER_GUID_PREFIX|g" \
    -e "s|@DISCOVERY_PROTOCOL@|$discovery_protocol|g" \
    "$PROFILE_TEMPLATE" > "$profile_path"
}

weaknet_phase12_detect_wsl_lan_ip() {
  if [[ -n "$WEAKNET_WSL_LAN_IP" ]]; then
    return 0
  fi

  WEAKNET_WSL_LAN_IP="$(ip -4 route get "$WEAKNET_ROBOT_IP" 2>/dev/null | \
    awk '{for (i = 1; i <= NF; ++i) if ($i == "src") {print $(i + 1); exit}}')"
  if [[ -z "$WEAKNET_WSL_LAN_IP" ]]; then
    echo "Error: could not determine the WSL LAN IP from the route to $WEAKNET_ROBOT_IP." >&2
    echo "Set WEAKNET_WSL_LAN_IP explicitly and source the setup script again." >&2
    return 1
  fi
}

weaknet_phase12_ros_daemon_pids() {
  ps -eo pid=,comm=,args= 2>/dev/null | awk -v domain="$ROS_DOMAIN_ID" '
    {
      is_daemon = 0
      domain_matches = 0
      is_ros_python = ($2 == "python3" || $2 == "python")
      is_daemon_module = ($0 ~ /ros2cli\.daemon\.daemonize/)
      for (i = 3; i <= NF; ++i) {
        if ($i == "--name" && $(i + 1) == "ros2-daemon") {
          is_daemon = 1
        }
        if ($i == "--ros-domain-id" && $(i + 1) == domain) {
          domain_matches = 1
        }
      }
      if (is_ros_python && is_daemon_module && is_daemon && domain_matches) {
        print $1
      }
    }'
}

weaknet_phase12_reset_ros_daemon() {
  # The daemon can keep its XML-RPC socket alive after rclpy has shut down.
  # In that state `ros2 topic/node list` reports a remote !rclpy.ok() fault.
  timeout 5s ros2 daemon stop >/dev/null 2>&1 || true

  local daemon_pids
  daemon_pids="$(weaknet_phase12_ros_daemon_pids || true)"
  if [[ -n "$daemon_pids" ]]; then
    kill $daemon_pids 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      daemon_pids="$(weaknet_phase12_ros_daemon_pids || true)"
      [[ -z "$daemon_pids" ]] && break
      sleep 0.2
    done
  fi
}

weaknet_phase12_wsl_setup() {
  weaknet_phase12_validate_configuration || return
  weaknet_phase12_detect_wsl_lan_ip || return

  if [[ ! -f "$WEAKNET_ROS_SETUP" ]]; then
    echo "Error: ROS setup file not found: $WEAKNET_ROS_SETUP" >&2
    return 1
  fi
  if [[ ! -f "$WEAKNET_WORKSPACE_SETUP" ]]; then
    echo "Error: workspace overlay not found: $WEAKNET_WORKSPACE_SETUP" >&2
    echo "Build the workspace first, then source this script again." >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$WEAKNET_ROS_SETUP" || return
  # shellcheck disable=SC1090
  source "$WEAKNET_WORKSPACE_SETUP" || return
  weaknet_phase12_render_profile CLIENT "$PROFILE_PATH" || return
  weaknet_phase12_render_profile SUPER_CLIENT "$SUPER_PROFILE_PATH" || return

  export ROS_DOMAIN_ID="$WEAKNET_ROS_DOMAIN_ID"
  export RMW_IMPLEMENTATION="rmw_fastrtps_cpp"
  export ROS_LOCALHOST_ONLY=0
  # Interactive WSL commands are primarily CLI/introspection commands. Use
  # SUPER_CLIENT so the CLI can see the complete Discovery Server graph.
  # The normal CLIENT profile remains available at PROFILE_PATH for nodes
  # that should use the narrower data-plane discovery behavior.
  export FASTRTPS_DEFAULT_PROFILES_FILE="$SUPER_PROFILE_PATH"
  export ROS_DISCOVERY_SERVER="TCPv4:[${WEAKNET_ROBOT_IP}]:${WEAKNET_DISCOVERY_SERVER_PORT}"
  unset FASTDDS_BUILTIN_TRANSPORTS FASTDDS_DEFAULT_PROFILES_FILE ROS_SUPER_CLIENT
  unset WEAKNET_CONTROL_PROFILE_PATH
  weaknet_phase12_reset_ros_daemon

  echo "WSL Phase 12 profiles prepared; end-to-end delivery is NOT yet verified."
  echo "  robot:       $WEAKNET_ROBOT_IP"
  echo "  domain:      $ROS_DOMAIN_ID"
  echo "  RMW:         $RMW_IMPLEMENTATION"
  echo "  DDS profile: $FASTRTPS_DEFAULT_PROFILES_FILE"
  echo "  node profile: $PROFILE_PATH"
  if [[ "$WEAKNET_DDS_DATA_PORT" == "0" ]]; then
    echo "  data port:   automatic per participant"
  else
    echo "  data port:   $WEAKNET_DDS_DATA_PORT"
  fi
  echo "  WSL LAN IP:  $WEAKNET_WSL_LAN_IP"
  echo "  Firewall instructions: source $SCRIPT_DIR/setup_phase12_wsl.sh firewall"
}

weaknet_phase12_configure_hyperv_firewall() {
  weaknet_phase12_validate_configuration || return
  local first_port last_port windows_script
  read -r first_port last_port < /proc/sys/net/ipv4/ip_local_port_range || return
  weaknet_phase12_validate_port ephemeral_min "$first_port" || return
  weaknet_phase12_validate_port ephemeral_max "$last_port" || return
  windows_script="$(wslpath -w "$SCRIPT_DIR/setup_phase12_windows.ps1")" || return
  echo "Run in Windows ADMINISTRATOR PowerShell (not Bash):"
  # PowerShell single-quoted strings escape apostrophes by doubling them.
  windows_script="${windows_script//\'/\'\'}"
  printf "powershell.exe -NoProfile -ExecutionPolicy Bypass -File '%s' -RobotIP '%s' -DataPorts '%s-%s'\n" \
    "$windows_script" "$WEAKNET_ROBOT_IP" "$first_port" "$last_port"
  echo "Scope: WSL inbound TCP from this robot only, on Linux ephemeral ports."
  echo "This range can also contain non-ROS services; use only with a trusted robot."
}

weaknet_phase12_wsl_check() {
  weaknet_phase12_require_ipv4 || return
  export FASTRTPS_DEFAULT_PROFILES_FILE="$SUPER_PROFILE_PATH"
  echo "Environment:"
  env | grep -E '^(ROS_DISTRO|ROS_DOMAIN_ID|ROS_LOCALHOST_ONLY|RMW_IMPLEMENTATION|FASTRTPS_DEFAULT_PROFILES_FILE)=' | sort || true
  echo
  echo "Network:"
  ip -br addr || true
  ip route get "$WEAKNET_ROBOT_IP" || true
  echo
  echo "WSL TCP listener:"
  if [[ "$WEAKNET_DDS_DATA_PORT" == "0" ]]; then
    echo "automatic per participant; inspect ss -lntp while a ROS node is running"
  else
    ss -lntp | grep ":${WEAKNET_DDS_DATA_PORT} " || true
  fi
  ss -lntp || true
  echo "Robot TCP connections (discovery alone does not prove delivery):"
  ss -tnp dst "$WEAKNET_ROBOT_IP" || true
  echo
  echo "ROS graph:"
  ros2 node list --no-daemon --spin-time "${WEAKNET_DISCOVERY_WAIT_S:-5}" || true
}

case "$ACTION" in
  up)
    weaknet_phase12_wsl_setup
    ;;
  check)
    weaknet_phase12_wsl_setup && weaknet_phase12_wsl_check
    ;;
  firewall)
    weaknet_phase12_configure_hyperv_firewall
    ;;
  help|-h|--help)
    weaknet_phase12_wsl_usage
    ;;
  *)
    echo "Unknown action: $ACTION" >&2
    weaknet_phase12_wsl_usage >&2
    return 2
    ;;
esac
