#!/bin/bash

#######################
# Script d'ajout de service à un utilisateur existant
# Usage: ./add_user_service.sh <username> <service>
# Services: sonarr, radarr, readarr, bazarr, prowlarr, seerr, calibre
#           (ainsi que qbittorrent, homarr, filebrowser s'ils manquent)
#######################

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonctions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Configuration
INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
TZ="Europe/Paris"

for lib in lib_ports lib_traefik lib_qbittorrent lib_services; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

usage() {
    echo "Usage: $0 <username> <service>"
    echo ""
    echo "Services disponibles:"
    echo "  - sonarr      : Gestion de séries TV"
    echo "  - radarr      : Gestion de films"
    echo "  - readarr     : Gestion de livres"
    echo "  - bazarr      : Gestion de sous-titres"
    echo "  - prowlarr    : Gestion d'indexeurs"
    echo "  - seerr       : demandes de films/séries (connexion Jellyfin/Plex)"
    echo "  - calibre     : Bibliothèque ebooks"
    exit 1
}

[ $# -eq 2 ] || usage
USERNAME=$1
SERVICE=$2

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
[[ " $USER_SERVICES " == *" $SERVICE "* ]] || { warn "Service inconnu : $SERVICE"; usage; }
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"
[ -f "$DOCKER_COMPOSE_FILE" ] || error "docker-compose.yml introuvable ($DOCKER_COMPOSE_FILE)"

if [ -f "$ENV_FILE" ] && grep -q '^TZ=' "$ENV_FILE"; then
    TZ=$(grep '^TZ=' "$ENV_FILE" | cut -d'=' -f2)
fi
traefik_detect "$ENV_FILE"

USER_ID=$(id -u "$USERNAME")
# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
CONTAINER_NAME="${SERVICE}-${USERNAME}"
# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
FB_PASSWORD_HASH=""

if grep -q "^  ${CONTAINER_NAME}:" "$DOCKER_COMPOSE_FILE" \
   || docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    warn "Le service $SERVICE est déjà installé pour $USERNAME"
    exit 0
fi

case "$SERVICE" in
    qbittorrent|filebrowser)
        # Services de base créés par add_user.sh avec les identifiants de
        # l'utilisateur (ici, le mot de passe n'est pas connu).
        error "$SERVICE est un service de base, installé par add_user.sh" ;;
    homarr)
        [ "$USE_TRAEFIK" = true ] \
            && error "Mode Traefik : le tableau de bord est le Homarr partagé (https://$DOMAIN)" ;;
esac

log "Ajout du service $SERVICE pour l'utilisateur $USERNAME..."
service_prepare "$SERVICE"
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"
compose_append_services "$DOCKER_COMPOSE_FILE" "$SERVICE" \
    || error "docker-compose.yml invalide après ajout — fichier inchangé (voir l'erreur ci-dessus)"

log "Démarrage du service..."
cd "$INSTALL_DIR"
compose_cmd up -d "$CONTAINER_NAME"

# Mettre à jour les liens du tableau de bord Homarr
"$SCRIPT_DIR/configure_homarr.sh" "$USERNAME" >/dev/null 2>&1 || true
# API libre-service : état des services à jour (sauf si appelé par son ouvrier)
[ -n "${SEEDBOX_API_WORKER:-}" ] || "$SCRIPT_DIR/seedbox_api_worker.sh" --state >/dev/null 2>&1 || true

sleep 5
if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "${GREEN}✓${NC} Service $SERVICE ajouté avec succès pour $USERNAME !"
    info "Accessible sur: $(service_url "$SERVICE")"
    [ "$USE_TRAEFIK" = true ] && info "Connexion SSO via: https://auth.$DOMAIN"
    # Réglages à saisir dans l'appli pour des imports SANS copie (hardlinks) :
    # téléchargements et médias sont sur le même montage /data.
    QB_PORT=8080; [ "$USE_TRAEFIK" = true ] || QB_PORT=$(user_port "$USER_ID" qbittorrent)
    case "$SERVICE" in
        sonarr|radarr|readarr)
            case "$SERVICE" in sonarr) root=/data/tv ;; radarr) root=/data/movies ;; *) root=/data/books ;; esac
            echo ""
            info "Configuration recommandée (imports par hardlink, sans doubler l'espace) :"
            info "   • Dossier racine        : $root"
            info "   • Client de téléchargement : qBittorrent, hôte qbittorrent-$USERNAME, port $QB_PORT"
            info "     (identifiants = ceux de la seedbox)"
            info "   • Gestion des médias → « Utiliser des liens physiques » : laisser ACTIVÉ" ;;
    esac
else
    error "Le service $SERVICE n'a pas pu démarrer. Vérifiez les logs avec: docker logs $CONTAINER_NAME"
fi
