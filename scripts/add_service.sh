#!/bin/bash

#######################
# Script d'ajout de services optionnels
# Usage: ./add_service.sh <service_name>
# Services disponibles: scrutiny, uptime-kuma, watchtower, duplicati
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
TZ="Europe/Paris"
ADMIN_UID="1000"
ADMIN_GID="1000"

# Vérification des arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <service_name>"
    echo ""
    echo "Services disponibles:"
    echo "  - plex          : Serveur de streaming média"
    echo "  - jellyfin      : Serveur de streaming média (alternative open-source à Plex)"
    echo "  - scrutiny      : Monitoring des disques durs"
    echo "  - uptime-kuma   : Monitoring de disponibilité"
    echo "  - watchtower    : Mises à jour automatiques des conteneurs"
    echo "  - duplicati     : Système de backup"
    exit 1
fi

SERVICE=$1

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier si le service est déjà installé
if docker ps -a --format '{{.Names}}' | grep -q "^$SERVICE$"; then
    warn "Le service $SERVICE est déjà installé"
    exit 0
fi

# Sauvegarder le docker-compose.yml
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"

case $SERVICE in
    plex)
        log "Installation de Plex (serveur de streaming)..."
        mkdir -p "$INSTALL_DIR/plex"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  plex:
    image: linuxserver/plex:latest
    container_name: plex
    network_mode: host
    environment:
      - PUID=$ADMIN_UID
      - PGID=$ADMIN_GID
      - TZ=$TZ
      - VERSION=docker
    volumes:
      - $INSTALL_DIR/plex:/config
      - $INSTALL_DIR/data:/data
    restart: unless-stopped
EOF
        info "Plex sera accessible sur le port 32400"
        info "Interface web: http://votre-serveur:32400/web"
        ;;

    scrutiny)
        log "Installation de Scrutiny (monitoring disques)..."
        mkdir -p "$INSTALL_DIR/scrutiny/config"
        mkdir -p "$INSTALL_DIR/scrutiny/influxdb"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  scrutiny:
    image: ghcr.io/analogj/scrutiny:master-omnibus
    container_name: scrutiny
    privileged: true
    ports:
      - "8080:8080"
      - "8086:8086"
    volumes:
      - $INSTALL_DIR/scrutiny/config:/opt/scrutiny/config
      - $INSTALL_DIR/scrutiny/influxdb:/opt/scrutiny/influxdb
      - /run/udev:/run/udev:ro
    cap_add:
      - SYS_RAWIO
      - SYS_ADMIN
    devices:
      - /dev/sda:/dev/sda
      - /dev/sdb:/dev/sdb
    environment:
      - TZ=$TZ
    restart: unless-stopped
EOF
        info "Scrutiny sera accessible sur le port 8080"
        ;;

    uptime-kuma)
        log "Installation d'Uptime Kuma (monitoring)..."
        mkdir -p "$INSTALL_DIR/uptime-kuma"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    volumes:
      - $INSTALL_DIR/uptime-kuma:/app/data
    ports:
      - "3001:3001"
    environment:
      - TZ=$TZ
    restart: unless-stopped
EOF
        info "Uptime Kuma sera accessible sur le port 3001"
        ;;

    watchtower)
        log "Installation de Watchtower (mises à jour auto)..."

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
      - WATCHTOWER_INCLUDE_RESTARTING=true
      - TZ=$TZ
    restart: unless-stopped
EOF
        info "Watchtower configuré pour vérifier les mises à jour quotidiennement à 4h du matin"
        ;;

    duplicati)
        log "Installation de Duplicati (backups)..."
        mkdir -p "$INSTALL_DIR/duplicati/config"
        mkdir -p "$INSTALL_DIR/duplicati/backups"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  duplicati:
    image: linuxserver/duplicati:latest
    container_name: duplicati
    environment:
      - PUID=$ADMIN_UID
      - PGID=$ADMIN_GID
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/duplicati/config:/config
      - $INSTALL_DIR/duplicati/backups:/backups
      - $INSTALL_DIR/data:/source:ro
      - /mnt/backup:/backup-destination
    ports:
      - "8200:8200"
    restart: unless-stopped
EOF
        info "Duplicati sera accessible sur le port 8200"
        ;;

    jellyfin)
        log "Installation de Jellyfin (serveur de streaming)..."
        mkdir -p "$INSTALL_DIR/jellyfin/config"
        mkdir -p "$INSTALL_DIR/jellyfin/cache"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=$ADMIN_UID
      - PGID=$ADMIN_GID
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/jellyfin/config:/config
      - $INSTALL_DIR/jellyfin/cache:/cache
      - $INSTALL_DIR/data:/media:ro
    ports:
      - "8096:8096"
      - "8920:8920"
      - "7359:7359/udp"
      - "1900:1900/udp"
    restart: unless-stopped
EOF
        info "Jellyfin sera accessible sur le port 8096"
        info "Interface web: http://votre-serveur:8096"
        ;;

    *)
        error "Service inconnu: $SERVICE"
        ;;
esac

# Démarrer le service
log "Démarrage du service $SERVICE..."
cd "$INSTALL_DIR"
docker-compose up -d "$SERVICE"

# Vérifier que le service est bien démarré
sleep 5
if docker ps --format '{{.Names}}' | grep -q "^$SERVICE$"; then
    log "${GREEN}✓${NC} Service $SERVICE installé et démarré avec succès !"
else
    error "Le service $SERVICE n'a pas pu démarrer. Vérifiez les logs avec: docker logs $SERVICE"
fi
