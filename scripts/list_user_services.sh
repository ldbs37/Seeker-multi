#!/bin/bash

#######################
# Liste les services d'un utilisateur, leur état et leur adresse d'accès
# Usage: ./list_user_services.sh <username>
#######################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

for lib in lib_ports lib_traefik lib_services; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || error "$lib.sh introuvable"
done

[ $# -eq 1 ] || error "Usage: $0 <username>"
USERNAME=$1
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"
USER_ID=$(id -u "$USERNAME")
# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
traefik_detect "$INSTALL_DIR/.env"

echo ""
echo -e "${BLUE}Services de ${USERNAME} (UID ${USER_ID}) :${NC}"
MISSING=()
for s in $USER_SERVICES; do
    name="${s}-${USERNAME}"
    if grep -q "^  ${name}:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; then
        status=$(docker ps -a --filter "name=^${name}$" --format '{{.Status}}' 2>/dev/null)
        case "$status" in
            Up*) state="${GREEN}● actif${NC}" ;;
            "")  state="${YELLOW}○ non créé${NC}" ;;
            *)   state="${RED}● arrêté${NC}" ;;
        esac
        printf "  %-12s %b  %s\n" "$s" "$state" "$(service_url "$s")"
    else
        MISSING+=("$s")
    fi
done
echo ""
info "Port torrent entrant : $(user_port "$USER_ID" torrent) (TCP/UDP)"
if [ ${#MISSING[@]} -gt 0 ]; then
    info "Services installables : ${MISSING[*]}"
    info "   sudo $SCRIPT_DIR/add_user_service.sh $USERNAME <service>"
fi
