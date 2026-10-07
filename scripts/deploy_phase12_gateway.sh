#!/usr/bin/env bash
# Copy the architecture-independent gateway and its lifecycle setup to Jetson.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  :
else
  echo "This helper must be executed, not sourced." >&2
  return 2
fi

set -e
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd -- "$SCRIPT_DIR/.." && pwd)"
JETSON_HOST="${WEAKNET_JETSON_HOST:-}"
REMOTE_DIR="${WEAKNET_JETSON_DEPLOY_DIR:-.cache/weaknet_phase12}"

if [[ -z "$JETSON_HOST" ]]; then
  echo "Error: set WEAKNET_JETSON_HOST to the Jetson SSH target (user@host)." >&2
  exit 2
fi

ssh "$JETSON_HOST" "mkdir -p '$REMOTE_DIR'"
scp "$WORKSPACE/scripts/phase12_safety_gateway.py" \
  "$JETSON_HOST:~/$REMOTE_DIR/"
scp "$WORKSPACE/scripts/setup_phase12_jetson_local.sh" \
  "$JETSON_HOST:~/weaknet_phase12_setup.sh"
ssh "$JETSON_HOST" "chmod 700 \"\$HOME/$REMOTE_DIR/phase12_safety_gateway.py\" ~/weaknet_phase12_setup.sh"
echo "Deployed the gateway and setup script to $JETSON_HOST."
echo "On Jetson, inspect control processes before starting it."
echo "If the known vendor joystick launch is active and the robot is stationary:"
echo "  source ~/weaknet_phase12_setup.sh takeover"
echo "Otherwise, with all joystick control stopped:"
echo "  source ~/weaknet_phase12_setup.sh up"
