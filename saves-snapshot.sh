#!/usr/bin/env bash
# Balatro save snapshot / restore utility
# Usage:
#   ./saves-snapshot.sh snap [label]   — back up current run
#   ./saves-snapshot.sh restore        — list snapshots and restore one
#   ./saves-snapshot.sh kill           — force-quit Balatro (before losing)

set -euo pipefail

SAVE_DIR="$HOME/Library/Application Support/Balatro/1"
BACKUP_ROOT="$(dirname "$0")/tmp/saves"
mkdir -p "$BACKUP_ROOT"

cmd="${1:-}"

case "$cmd" in
  snap)
    label="${2:-}"
    ts="$(date +%Y%m%d_%H%M%S)"
    name="${ts}${label:+_$label}"
    dest="$BACKUP_ROOT/$name"
    mkdir -p "$dest"
    cp "$SAVE_DIR/save.jkr"    "$dest/save.jkr"    2>/dev/null && echo "  copied save.jkr"    || echo "  (no save.jkr — no active run?)"
    cp "$SAVE_DIR/profile.jkr" "$dest/profile.jkr" 2>/dev/null && echo "  copied profile.jkr" || echo "  (no profile.jkr)"
    cp "$SAVE_DIR/meta.jkr"    "$dest/meta.jkr"    2>/dev/null && echo "  copied meta.jkr"    || true
    echo "Snapshot saved → tmp/saves/$name"
    ;;

  restore)
    snapshots=("$BACKUP_ROOT"/*)
    if [[ ${#snapshots[@]} -eq 0 ]]; then
      echo "No snapshots found in tmp/saves/"
      exit 1
    fi
    echo "Available snapshots:"
    for i in "${!snapshots[@]}"; do
      echo "  [$i] $(basename "${snapshots[$i]}")"
    done
    read -rp "Restore which? [number]: " choice
    src="${snapshots[$choice]}"
    echo ""
    echo "To restore, run:"
    echo "  cp \"$src/save.jkr\"    \"$SAVE_DIR/save.jkr\""
    echo "  cp \"$src/profile.jkr\" \"$SAVE_DIR/profile.jkr\""
    echo "  cp \"$src/meta.jkr\"    \"$SAVE_DIR/meta.jkr\""
    echo ""
    echo "Then relaunch Balatro."
    ;;

  kill)
    pid="$(pgrep -i balatro || true)"
    if [[ -z "$pid" ]]; then
      echo "Balatro is not running."
    else
      kill -9 "$pid"
      echo "Force-killed Balatro (pid $pid). Steam did not record any result."
    fi
    ;;

  *)
    echo "Usage: $0 snap [label] | restore | kill"
    exit 1
    ;;
esac
