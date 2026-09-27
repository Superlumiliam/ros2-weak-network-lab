#!/usr/bin/env bash

set -euo pipefail

PUB_NS="weaknet_pub_ns"
SUB_NS="weaknet_sub_ns"
PUB_IF="wnpub0"
SUB_IF="wnsub0"
PUB_ADDR="10.200.0.1/30"
SUB_ADDR="10.200.0.2/30"
SUB_IP="10.200.0.2"

ns_exists() {
  ip netns list | awk '{print $1}' | grep -Fxq "$1"
}

interface_exists() {
  ip -n "$1" link show "$2" >/dev/null 2>&1
}

show_status() {
  echo "Namespaces:"
  ip netns list | grep -E "^(${PUB_NS}|${SUB_NS})$" || true
  echo

  for ns in "$PUB_NS" "$SUB_NS"; do
    if ns_exists "$ns"; then
      echo "[$ns]"
      ip -n "$ns" -br addr show
      ip -n "$ns" -br link show
      echo
    fi
  done
}

setup() {
  if ! ns_exists "$PUB_NS"; then
    ip netns add "$PUB_NS"
  fi

  if ! ns_exists "$SUB_NS"; then
    ip netns add "$SUB_NS"
  fi

  local pub_if_exists=0
  local sub_if_exists=0
  interface_exists "$PUB_NS" "$PUB_IF" && pub_if_exists=1
  interface_exists "$SUB_NS" "$SUB_IF" && sub_if_exists=1

  if [[ "$pub_if_exists" -eq 0 && "$sub_if_exists" -eq 0 ]]; then
    ip link add "$PUB_IF" type veth peer name "$SUB_IF"
    ip link set "$PUB_IF" netns "$PUB_NS"
    ip link set "$SUB_IF" netns "$SUB_NS"
  elif [[ "$pub_if_exists" -ne 1 || "$sub_if_exists" -ne 1 ]]; then
    echo "Error: veth pair is partially present; refusing to guess how to repair it." >&2
    echo "Run '$0 down' and then '$0 up' after stopping experiment nodes." >&2
    exit 1
  fi

  ip -n "$PUB_NS" addr replace "$PUB_ADDR" dev "$PUB_IF"
  ip -n "$SUB_NS" addr replace "$SUB_ADDR" dev "$SUB_IF"

  ip -n "$PUB_NS" link set lo up
  ip -n "$SUB_NS" link set lo up
  ip -n "$PUB_NS" link set "$PUB_IF" up
  ip -n "$SUB_NS" link set "$SUB_IF" up

  echo "Checking connectivity..."
  ip netns exec "$PUB_NS" ping -c 2 -W 1 "$SUB_IP" >/dev/null
  echo "Weaknet namespace topology is ready."
  echo "  publisher: $PUB_NS / $PUB_ADDR"
  echo "  subscriber: $SUB_NS / $SUB_ADDR"
  echo "  no tc/netem rule was added"
}

teardown() {
  echo "Stop ROS2 processes inside the namespaces before teardown."

  if ns_exists "$PUB_NS"; then
    ip netns del "$PUB_NS"
  fi

  if ns_exists "$SUB_NS"; then
    ip netns del "$SUB_NS"
  fi

  echo "Weaknet namespace topology removed."
}

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

case "${1:-up}" in
  up)
    setup
    ;;
  status)
    show_status
    ;;
  down)
    teardown
    ;;
  *)
    echo "Usage: $0 [up|status|down]" >&2
    exit 2
    ;;
esac
