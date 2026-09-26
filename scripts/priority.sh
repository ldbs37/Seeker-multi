#!/bin/bash
#######################
# priority.sh — Les applications passent avant les téléchargements (disque
# et réseau ; voir lib_priority.sh).
# Usage: sudo ./priority.sh           # activer (+ minuteur chaque minute)
#        sudo ./priority.sh --apply   # appliquer une fois (minuteur)
#        sudo ./priority.sh --off     # tout retirer
#######################

set -u
INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_priority.sh" || exit 1
[[ $EUID -eq 0 ]] || { echo "Ce script doit être exécuté en tant que root" >&2; exit 1; }

case "${1:-}" in
    --apply) priority_apply ;;
    --off)
        systemctl disable --now seedbox-priority.timer >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/seedbox-priority.{service,timer}
        systemctl daemon-reload >/dev/null 2>&1 || true
        priority_remove
        echo "Priorité des applications retirée" ;;
    "")
        priority_apply && priority_timer_ensure
        echo "Priorité des applications active (disque : BFQ ; réseau : téléchargements en dernier)" ;;
    *) echo "Usage: $0 [--apply|--off]" >&2; exit 1 ;;
esac
