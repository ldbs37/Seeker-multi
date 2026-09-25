#!/bin/bash

#######################
# Suppression d'un service (système, ou service d'un utilisateur)
# Usage: ./remove_service.sh <service>            # ex: portainer, dashdot
#        ./remove_service.sh <service>-<user>     # ex: sonarr-alice
#
# Retire le service du docker-compose.yml (sinon il serait recréé au prochain
# `up -d`) puis supprime le conteneur. Les données/configurations sont
# conservées sur le disque.
#######################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"

for lib in lib_ports lib_traefik lib_services lib_compose_base; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || error "$lib.sh introuvable"
done

[ $# -eq 1 ] || error "Usage: $0 <service> | <service>-<utilisateur>"
NAME=$1
[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
grep -q "^  ${NAME}:" "$DOCKER_COMPOSE_FILE" || error "Service '$NAME' absent du docker-compose.yml"

case "$NAME" in
    authelia|flaresolverr|traefik|homarr)
        error "$NAME est un composant indispensable de la seedbox" ;;
    qbittorrent-*|homarr-*|filebrowser-*)
        error "Service de base d'un utilisateur : utilisez remove_user.sh pour supprimer l'utilisateur" ;;
esac

cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"
TMP="${DOCKER_COMPOSE_FILE%.yml}.new.yml"

if FLAG=$(system_service_flag "$NAME"); then
    # Service système : reconstruction de la partie système sans lui
    envget() { grep "^$1=" "$ENV_FILE" | cut -d'=' -f2; }
    TZ=$(envget TZ)
    ADMIN_UID=$(envget ADMIN_UID)
    ADMIN_GID=$(envget ADMIN_GID)
    TZ=${TZ:-Europe/Paris}; ADMIN_UID=${ADMIN_UID:-1000}; ADMIN_GID=${ADMIN_GID:-1000}
    traefik_detect "$ENV_FILE"
    detect_system_services "$DOCKER_COMPOSE_FILE"
    printf -v "$FLAG" '%s' false
    KEEP=()
    while read -r n; do
        [[ " $SYSTEM_SERVICES $SYSTEM_SERVICES_OBSOLETE " == *" $n "* ]] || KEEP+=("$n")
    done < <(compose_service_names "$DOCKER_COMPOSE_FILE")
    cp "$ENV_FILE" "$ENV_FILE.bak"
    generate_docker_compose "$TMP" >/dev/null
    [ ${#KEEP[@]} -gt 0 ] && compose_extract_blocks "${DOCKER_COMPOSE_FILE}.bak" "${KEEP[@]}" >> "$TMP"
else
    # Service d'un utilisateur ou bloc personnalisé : retrait du bloc exact
    awk -v name="${NAME}:" '
        /^  [^ #]/ { skip = ($1 == name) }
        /^[^ ]/    { skip = 0 }
        !skip      { print }
    ' "$DOCKER_COMPOSE_FILE" > "$TMP"
fi

if ! compose_validate "$TMP"; then
    rm -f "$TMP"; [ -f "$ENV_FILE.bak" ] && cp "$ENV_FILE.bak" "$ENV_FILE"
    error "Le docker-compose.yml serait invalide — aucune modification appliquée"
fi
mv "$TMP" "$DOCKER_COMPOSE_FILE"
docker rm -f "$NAME" >/dev/null 2>&1 || true

# Tableau de bord Homarr de l'utilisateur à jour
usr=${NAME##*-}
if [[ "$NAME" == *-* ]] && id "$usr" &>/dev/null; then
    "$SCRIPT_DIR/configure_homarr.sh" "$usr" >/dev/null 2>&1 || true
fi

log "${GREEN}✓${NC} Service $NAME supprimé (données conservées sur le disque)"

# API libre-service : état des services à jour (sauf si appelé par son ouvrier)
[ -n "${SEEDBOX_API_WORKER:-}" ] || "$SCRIPT_DIR/seedbox_api_worker.sh" --state >/dev/null 2>&1 || true
