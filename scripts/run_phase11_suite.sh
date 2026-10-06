#!/usr/bin/env bash
# Purpose: Run the complete Phase 11 experiment matrix, collect artifacts, and audit results.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
RAW_DIR="$WORKSPACE/exp/raw/phase11"
LOG_DIR="$RAW_DIR/logs"
ANALYSIS_DIR="$RAW_DIR/analysis"
MANIFEST="$RAW_DIR/manifest.csv"
PUB_SCRIPT="$WORKSPACE/scripts/run_weaknet_pub_ns.sh"
SUB_SCRIPT="$WORKSPACE/scripts/run_weaknet_sub_ns.sh"
ANALYZER="$WORKSPACE/scripts/analyze_weaknet_csv.py"
NAMESPACE="weaknet_pub_ns"
SUB_NAMESPACE="weaknet_sub_ns"
INTERFACE="wnpub0"
RUN_USER="${SUDO_USER:-${USER}}"
RUN_TAG="${PHASE11_RUN_TAG:-$(date +%Y%m%d_%H%M%S)}"

SUB_PID=""
PUB_PID=""

mkdir -p "$RAW_DIR" "$LOG_DIR" "$ANALYSIS_DIR"

if [[ "$EUID" -ne 0 ]]; then
  sudo -v
fi

if ! sudo -n ip netns exec "$NAMESPACE" true 2>/dev/null; then
  echo "Error: namespace '$NAMESPACE' does not exist." >&2
  echo "Run setup_weaknet_netns.sh up first." >&2
  exit 1
fi

if [[ ! -f "$MANIFEST" ]]; then
  printf '%s\n' \
    'run_id,qos_reliability,depth,network_condition,raw_csv,subscriber_log,publisher_log,tc_log,analysis_log,status' \
    > "$MANIFEST"
fi

pid_is_running() {
  local pid="$1"
  local state

  [[ -n "$pid" ]] || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | awk 'NR == 1 {print $1}')"
  [[ -n "$state" && "$state" != Z* ]]
}

wait_for_process() {
  local pid="$1"
  for _ in {1..20}; do
    if ! pid_is_running "$pid"; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.2
  done
  return 1
}

signal_node() {
  local namespace="$1"
  local process_name="$2"
  local signal="$3"

  sudo -n ip netns exec "$namespace" \
    pkill "-$signal" -u "$RUN_USER" -x "$process_name" \
    >/dev/null 2>&1 || true
}

stop_node() {
  local namespace="$1"
  local process_name="$2"
  local pid="$3"

  [[ -n "$pid" ]] || return 0

  # Signal the actual ROS 2 process inside its namespace so rclcpp can
  # print its summary and close the CSV cleanly.
  signal_node "$namespace" "$process_name" INT
  if wait_for_process "$pid"; then
    return 0
  fi

  signal_node "$namespace" "$process_name" TERM
  kill -TERM "$pid" 2>/dev/null || true
  if wait_for_process "$pid"; then
    return 0
  fi

  signal_node "$namespace" "$process_name" KILL
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

stop_nodes() {
  stop_node "$NAMESPACE" weaknet_pub "$PUB_PID"
  stop_node "$SUB_NAMESPACE" weaknet_sub "$SUB_PID"
  PUB_PID=""
  SUB_PID=""
}

clear_qdisc() {
  sudo -n ip netns exec "$NAMESPACE" \
    tc qdisc del dev "$INTERFACE" root >/dev/null 2>&1 || true
}

apply_qdisc() {
  local condition="$1"

  case "$condition" in
    normal)
      clear_qdisc
      ;;
    loss1)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem loss 1%
      ;;
    loss5)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem loss 5%
      ;;
    loss10)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem loss 10%
      ;;
    loss20)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem loss 20%
      ;;
    delay20)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 20ms
      ;;
    delay50)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 50ms
      ;;
    delay100)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 100ms
      ;;
    delay200)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 200ms
      ;;
    delay500)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 500ms
      ;;
    delay100_loss10)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem delay 100ms loss 10%
      ;;
    outage_loss100)
      sudo -n ip netns exec "$NAMESPACE" \
        tc qdisc replace dev "$INTERFACE" root netem loss 100%
      ;;
    *)
      echo "Unsupported condition: $condition" >&2
      return 2
      ;;
  esac
}

save_tc_stats() {
  local tc_log="$1"
  sudo -n ip netns exec "$NAMESPACE" \
    tc -s qdisc show dev "$INTERFACE" 2>&1 |
    sed 's/[[:space:]]*$//' > "$tc_log" || true
}

verify_clean_qdisc() {
  local check_log="$1"

  if ! sudo -n ip netns exec "$NAMESPACE" \
    tc qdisc show dev "$INTERFACE" > "$check_log" 2>&1; then
    echo "Could not verify qdisc state; see $check_log" >&2
    return 1
  fi

  if grep -q 'netem' "$check_log"; then
    echo "Residual netem rule detected; see $check_log" >&2
    return 1
  fi
}

append_manifest() {
  local run_id="$1"
  local reliability="$2"
  local depth="$3"
  local condition="$4"
  local raw_csv="$5"
  local subscriber_log="$6"
  local publisher_log="$7"
  local tc_log="$8"
  local analysis_log="$9"
  local status="${10}"
  local raw_csv_rel="${raw_csv#"$RAW_DIR/"}"
  local subscriber_log_rel="${subscriber_log#"$RAW_DIR/"}"
  local publisher_log_rel="${publisher_log#"$RAW_DIR/"}"
  local tc_log_rel="${tc_log#"$RAW_DIR/"}"
  local analysis_log_rel="${analysis_log#"$RAW_DIR/"}"

  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$run_id" "$reliability" "$depth" "$condition" \
    "$raw_csv_rel" "$subscriber_log_rel" "$publisher_log_rel" "$tc_log_rel" \
    "$analysis_log_rel" "$status" >> "$MANIFEST"
}

run_nodes() {
  local reliability="$1"
  local depth="$2"
  local raw_csv="$3"
  local subscriber_log="$4"
  local publisher_log="$5"

  "$SUB_SCRIPT" "$reliability" "$depth" "$raw_csv" \
    > "$subscriber_log" 2>&1 &
  SUB_PID=$!
  sleep 2

  "$PUB_SCRIPT" "$reliability" "$depth" \
    > "$publisher_log" 2>&1 &
  PUB_PID=$!
}

run_static() {
  local logical_run_id="$1"
  local reliability="$2"
  local depth="$3"
  local condition="$4"
  local duration_s="${5:-30}"
  local run_id="${logical_run_id}_${RUN_TAG}"

  local raw_csv="$RAW_DIR/${run_id}.csv"
  local subscriber_log="$LOG_DIR/${run_id}.sub.log"
  local publisher_log="$LOG_DIR/${run_id}.pub.log"
  local tc_log="$LOG_DIR/${run_id}.tc.log"
  local analysis_log="$ANALYSIS_DIR/${run_id}.txt"

  echo "[Phase 11] start $run_id"
  stop_nodes
  apply_qdisc "$condition"
  run_nodes "$reliability" "$depth" "$raw_csv" "$subscriber_log" "$publisher_log"
  sleep "$duration_s"
  save_tc_stats "$tc_log"
  stop_nodes
  clear_qdisc
  verify_clean_qdisc "$LOG_DIR/${run_id}.post_cleanup_qdisc.log"

  if python3 "$ANALYZER" "$raw_csv" > "$analysis_log"; then
    append_manifest "$run_id" "$reliability" "$depth" "$condition" \
      "$raw_csv" "$subscriber_log" "$publisher_log" "$tc_log" \
      "$analysis_log" "valid"
    echo "[Phase 11] finished $run_id"
  else
    append_manifest "$run_id" "$reliability" "$depth" "$condition" \
      "$raw_csv" "$subscriber_log" "$publisher_log" "$tc_log" \
      "$analysis_log" "analysis_failed"
    echo "[Phase 11] analysis failed for $run_id" >&2
  fi
}

run_outage() {
  local logical_run_id="$1"
  local depth="$2"
  local run_id="${logical_run_id}_${RUN_TAG}"

  local raw_csv="$RAW_DIR/${run_id}.csv"
  local subscriber_log="$LOG_DIR/${run_id}.sub.log"
  local publisher_log="$LOG_DIR/${run_id}.pub.log"
  local tc_log="$LOG_DIR/${run_id}.tc.log"
  local analysis_log="$ANALYSIS_DIR/${run_id}.txt"

  echo "[Phase 11] start $run_id"
  stop_nodes
  clear_qdisc
  run_nodes reliable "$depth" "$raw_csv" "$subscriber_log" "$publisher_log"
  sleep 5
  apply_qdisc outage_loss100
  sleep 10
  save_tc_stats "$tc_log"
  clear_qdisc
  sleep 15
  stop_nodes
  verify_clean_qdisc "$LOG_DIR/${run_id}.post_cleanup_qdisc.log"

  if python3 "$ANALYZER" "$raw_csv" > "$analysis_log"; then
    append_manifest "$run_id" reliable "$depth" \
      "outage_loss100_10s_recovery" "$raw_csv" "$subscriber_log" \
      "$publisher_log" "$tc_log" "$analysis_log" "valid"
    echo "[Phase 11] finished $run_id"
  else
    append_manifest "$run_id" reliable "$depth" \
      "outage_loss100_10s_recovery" "$raw_csv" "$subscriber_log" \
      "$publisher_log" "$tc_log" "$analysis_log" "analysis_failed"
    echo "[Phase 11] analysis failed for $run_id" >&2
  fi
}

cleanup() {
  stop_nodes
  clear_qdisc
}

trap cleanup EXIT
trap 'exit 130' INT TERM

echo "This suite will run 18 Phase 11 experiments and may take about 10 minutes."
echo "Run tag: $RUN_TAG"
echo "Raw data: $RAW_DIR"
echo "Enter the sudo password once if prompted. It is not stored by this script."
sudo -v

ip netns list | grep -q "^${NAMESPACE} " || {
  echo "Namespace '$NAMESPACE' is missing. Run setup_weaknet_netns.sh up first." >&2
  exit 1
}

run_static baseline_reliable_depth10 reliable 10 normal
run_static baseline_best_effort_depth10 best_effort 10 normal
run_static delay20_reliable_depth10 reliable 10 delay20
run_static delay50_reliable_depth10 reliable 10 delay50
run_static delay100_reliable_depth10 reliable 10 delay100
run_static delay200_reliable_depth10 reliable 10 delay200
run_static delay500_reliable_depth10 reliable 10 delay500
run_static loss1_reliable_depth10 reliable 10 loss1
run_static loss5_reliable_depth10 reliable 10 loss5
run_static loss10_reliable_depth10 reliable 10 loss10
run_static loss20_reliable_depth10 reliable 10 loss20
run_static loss10_best_effort_depth10 best_effort 10 loss10
run_static delay100_best_effort_depth10 best_effort 10 delay100
run_static delay100_loss10_reliable_depth10 reliable 10 delay100_loss10
run_static delay100_loss10_best_effort_depth10 best_effort 10 delay100_loss10
run_outage outage_reliable_depth1 1
run_outage outage_reliable_depth5 5
run_outage outage_reliable_depth10 10

clear_qdisc
echo "[Phase 11] all experiments finished"
echo "Manifest: $MANIFEST"
