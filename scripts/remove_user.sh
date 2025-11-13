#!/bin/bash

#######################
# Script de suppression d'utilisateur
# Usage: ./remove_user.sh <username> [--keep-data]
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
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AUTHELIA_CONFIG_DIR="$INSTALL_DIR/authelia"

# Vérification des arguments
if [ $# -lt 1 ]; then
    error "Usage: $0 <username> [--keep-data]"
fi

USERNAME=$1
KEEP_DATA=false

if [ "$2" = "--keep-data" ]; then
    KEEP_DATA=true
fi

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier si l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Confirmation
warn "ATTENTION: Vous êtes sur le point de supprimer l'utilisateur $USERNAME"
if [ "$KEEP_DATA" = false ]; then
    warn "Toutes les données seront supprimées définitivement !"
else
    info "Les données seront conservées dans $INSTALL_DIR/data/users/$USERNAME"
fi
read -p "Êtes-vous sûr ? (tapez 'yes' pour confirmer): " confirm

if [ "$confirm" != "yes" ]; then
    log "Opération annulée"
    exit 0
fi

# Liste des services de l'utilisateur
SERVICES=(
    "qbittorrent-$USERNAME"
    "sonarr-$USERNAME"
    "radarr-$USERNAME"
    "readarr-$USERNAME"
    "bazarr-$USERNAME"
    "prowlarr-$USERNAME"
    "overseerr-$USERNAME"
    "homarr-$USERNAME"
    "calibre-$USERNAME"
    "filebrowser-$USERNAME"
)

# Arrêt et suppression des conteneurs
log "Arrêt des services..."
cd "$INSTALL_DIR"
for service in "${SERVICES[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^$service$"; then
        log "Arrêt de $service..."
        docker stop "$service" 2>/dev/null || true
        docker rm "$service" 2>/dev/null || true
    fi
done

# Suppression du docker-compose.yml
log "Mise à jour de la configuration Docker..."
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"

# Supprimer les sections de l'utilisateur du docker-compose.yml
# On va créer un fichier temporaire sans les services de cet utilisateur
awk -v username="$USERNAME" '
BEGIN { skip = 0 }
/^  # Services pour l.utilisateur: / {
    if ($0 ~ username) {
        skip = 1
        next
    }
}
/^  [a-z]/ {
    if (skip == 1) {
        if ($0 !~ username) {
            skip = 0
        } else {
            next
        }
    }
}
/^[^ ]/ {
    skip = 0
}
skip == 0 { print }
' "$DOCKER_COMPOSE_FILE" > "${DOCKER_COMPOSE_FILE}.tmp"

mv "${DOCKER_COMPOSE_FILE}.tmp" "$DOCKER_COMPOSE_FILE"

# Suppression des données si demandé
if [ "$KEEP_DATA" = false ]; then
    log "Suppression des données utilisateur..."
    rm -rf "$INSTALL_DIR/data/users/$USERNAME"

    # Suppression des configurations
    declare -a SERVICE_DIRS=(
        "qbittorrent"
        "sonarr"
        "radarr"
        "readarr"
        "bazarr"
        "prowlarr"
        "overseerr"
        "homarr"
        "calibre"
        "filebrowser"
    )

    for service in "${SERVICE_DIRS[@]}"; do
        rm -rf "$INSTALL_DIR/$service/$USERNAME"
    done
else
    info "Données conservées dans $INSTALL_DIR/data/users/$USERNAME"
fi

# Suppression de l'utilisateur d'Authelia
log "Suppression de l'authentification..."
if [ -f "$AUTHELIA_CONFIG_DIR/users_database.yml" ]; then
    # Supprimer l'utilisateur du fichier YAML
    sed -i "/^  $USERNAME:/,/^  [^ ]/{ /^  $USERNAME:/d; /^    /d; }" "$AUTHELIA_CONFIG_DIR/users_database.yml"

    # Redémarrer Authelia pour appliquer les changements
    docker restart authelia 2>/dev/null || warn "Impossible de redémarrer Authelia"
fi

# Suppression de l'utilisateur système
log "Suppression de l'utilisateur système..."
if [ "$KEEP_DATA" = false ]; then
    userdel -r "$USERNAME" 2>/dev/null || warn "Impossible de supprimer l'utilisateur système"
else
    userdel "$USERNAME" 2>/dev/null || warn "Impossible de supprimer l'utilisateur système"
fi

log "${GREEN}✓${NC} Utilisateur $USERNAME supprimé avec succès !"
if [ "$KEEP_DATA" = true ]; then
    info "Les données ont été conservées et peuvent être restaurées avec add_user.sh"
fi
