#!/bin/bash

#######################
# Ajout d'un service SYSTÈME (administrateur) après l'installation
# Usage: ./add_service.sh <service_name>
#
# Reconstruit la partie "services système" du docker-compose.yml à partir des
# définitions partagées (lib_compose_base.sh, identiques à install.sh) : le
# service ajouté reçoit donc automatiquement labels Traefik + SSO en mode
# Traefik et des ports locaux. Le service Traefik et les services des
# utilisateurs sont conservés à l'identique.
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

for lib in lib_ports lib_traefik lib_services lib_compose_base lib_autoconfig lib_password lib_jellyfin; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

usage() {
    echo "Usage: $0 <service_name>"
    echo ""
    echo "Streaming:   jellyfin"
    echo "Monitoring:  scrutiny, uptime-kuma, dashdot"
    echo "Gestion:     portainer"
    echo "Maintenance: watchtower, duplicati"
    exit 1
}

[ $# -eq 1 ] || usage
SERVICE=$1
[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
FLAG=$(system_service_flag "$SERVICE") || { warn "Service inconnu : $SERVICE"; usage; }
[ -f "$DOCKER_COMPOSE_FILE" ] && [ -f "$ENV_FILE" ] || error "Installation introuvable dans $INSTALL_DIR"

if grep -q "^  ${SERVICE}:" "$DOCKER_COMPOSE_FILE"; then
    warn "Le service $SERVICE est déjà installé"
    exit 0
fi

envget() { grep "^$1=" "$ENV_FILE" | cut -d'=' -f2; }
TZ=$(envget TZ); DOMAIN=$(envget DOMAIN); ADMIN_UID=$(envget ADMIN_UID); ADMIN_GID=$(envget ADMIN_GID)
TZ=${TZ:-Europe/Paris}; ADMIN_UID=${ADMIN_UID:-1000}; ADMIN_GID=${ADMIN_GID:-1000}
traefik_require "$ENV_FILE"

# Identifiants admin demandés AVANT toute modification
ADMIN_USER=""; ADMIN_PASS=""
# (Jellyfin : administrateur = premier administrateur seedbox, automatique)
if [ "$SERVICE" = portainer ]; then
    minlen=12
    read -r -p "Nom d'utilisateur admin $SERVICE [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-admin}
    while true; do
        read -r -s -p "Mot de passe admin (min $minlen caractères): " ADMIN_PASS; echo
        [ ${#ADMIN_PASS} -ge $minlen ] || { warn "Trop court"; continue; }
        read -r -s -p "Confirmez: " p2; echo
        [ "$ADMIN_PASS" = "$p2" ] && break
        warn "Les mots de passe ne correspondent pas"
    done
fi

log "Ajout de $SERVICE..."
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"

# Services système actuels + le nouveau
detect_system_services "$DOCKER_COMPOSE_FILE"
printf -v "$FLAG" '%s' true

# Blocs conservés tels quels : tout ce qui n'est pas un service système
KEEP=()
while read -r n; do
    [[ " $SYSTEM_SERVICES $SYSTEM_SERVICES_OBSOLETE " == *" $n "* ]] || KEEP+=("$n")
done < <(compose_service_names "$DOCKER_COMPOSE_FILE")

TMP="${DOCKER_COMPOSE_FILE%.yml}.new.yml"
cp "$ENV_FILE" "$ENV_FILE.bak"
generate_docker_compose "$TMP"
[ ${#KEEP[@]} -gt 0 ] && compose_extract_blocks "${DOCKER_COMPOSE_FILE}.bak" "${KEEP[@]}" >> "$TMP"
# Réseaux privés des utilisateurs (déclarations, Traefik et Homarr)
compose_sync_user_nets "$TMP" || true

if ! compose_validate "$TMP"; then
    rm -f "$TMP"; cp "$ENV_FILE.bak" "$ENV_FILE"
    error "Le docker-compose.yml serait invalide — aucune modification appliquée"
fi
mv "$TMP" "$DOCKER_COMPOSE_FILE"

log "Démarrage de $SERVICE..."
cd "$INSTALL_DIR"
compose_cmd up -d "$SERVICE"

case "$SERVICE" in
    portainer)
        autoconfig_portainer "$ADMIN_USER" "$ADMIN_PASS" \
            && { portainer_sso_setup "$ADMIN_USER" "$ADMIN_PASS" "$(autoconfig_first_admin "$INSTALL_DIR")" || true; } || true ;;
    scrutiny)  autoconfig_scrutiny "$INSTALL_DIR" || true ;;
    duplicati) autoconfig_duplicati "$INSTALL_DIR" || true ;;
    uptime-kuma) autoconfig_uptime_kuma "$INSTALL_DIR" "$(autoconfig_first_admin "$INSTALL_DIR")" || true ;;
    jellyfin)
        # Comptes et bibliothèques de chaque utilisateur, administrateur =
        # premier administrateur seedbox, connexion via Authelia (client OIDC)
        if authelia_ensure_oidc_jellyfin "$INSTALL_DIR/authelia/configuration.yml"; then
            docker restart authelia >/dev/null 2>&1 || warn "Redémarrez Authelia : docker restart authelia"
        fi
        if jellyfin_sync_all; then
            log "✓ Jellyfin : comptes et bibliothèques des utilisateurs configurés"
            # Seerr des utilisateurs : reliés à Jellyfin
            "$SCRIPT_DIR/arr_setup.sh" --all || true
            info "Mot de passe Jellyfin (applis TV/mobile) : sudo $SCRIPT_DIR/update_password.sh <utilisateur>"
        else
            warn "Configuration automatique de Jellyfin incomplète : relancez generate_traefik_labels.sh"
        fi ;;
esac

sleep 3
if docker ps --format '{{.Names}}' | grep -qx "$SERVICE"; then
    log "${GREEN}✓${NC} Service $SERVICE installé et démarré"
else
    error "Le service $SERVICE n'a pas pu démarrer. Vérifiez : docker logs $SERVICE"
fi

# Accès
case "$SERVICE" in
    jellyfin)   info "Accès : https://jellyfin.$DOMAIN" ;;
    watchtower) info "Mises à jour automatiques chaque nuit à 4h" ;;
    duplicati)
        info "Accès (administrateurs, SSO) : https://duplicati.$DOMAIN"
        info "Mot de passe de Duplicati : sudo grep DUPLICATI_PASSWORD $ENV_FILE" ;;
    *)
        sub=$SERVICE; [ "$SERVICE" = uptime-kuma ] && sub=uptime
        info "Accès (administrateurs, SSO) : https://${sub}.$DOMAIN"
esac
