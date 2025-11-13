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
    echo ""
    echo "Streaming:"
    echo "  - plex          : Serveur de streaming média"
    echo "  - jellyfin      : Alternative open-source à Plex"
    echo ""
    echo "Monitoring & Dashboards:"
    echo "  - scrutiny      : Monitoring des disques durs (S.M.A.R.T.)"
    echo "  - uptime-kuma   : Monitoring de disponibilité"
    echo "  - dashdot       : Dashboard de monitoring système élégant"
    echo "  - tautulli      : Statistiques détaillées pour Plex"
    echo ""
    echo "Gestion:"
    echo "  - portainer     : Interface web pour gérer Docker"
    echo "  - organizr      : Dashboard all-in-one pour tous vos services"
    echo ""
    echo "Maintenance:"
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

        # Démarrer Jellyfin
        cd "$INSTALL_DIR"
        docker-compose up -d jellyfin

        # Configuration du compte admin
        log "Configuration du compte administrateur Jellyfin..."
        echo ""
        read -p "Nom d'utilisateur admin [admin]: " JELLYFIN_USER
        JELLYFIN_USER=${JELLYFIN_USER:-"admin"}

        while true; do
            read -s -p "Mot de passe admin (min 8 caractères): " JELLYFIN_PASSWORD
            echo
            if [ ${#JELLYFIN_PASSWORD} -ge 8 ]; then
                read -s -p "Confirmez le mot de passe: " JELLYFIN_PASSWORD_CONFIRM
                echo
                if [ "$JELLYFIN_PASSWORD" = "$JELLYFIN_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 8 caractères"
            fi
        done

        # Attendre que Jellyfin soit prêt (max 60 secondes)
        log "Attente du démarrage de Jellyfin..."
        RETRY_COUNT=0
        MAX_RETRIES=30
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            if curl -s http://localhost:8096/health >/dev/null 2>&1; then
                break
            fi
            sleep 2
            RETRY_COUNT=$((RETRY_COUNT + 1))
        done

        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            warn "Jellyfin a mis trop de temps à démarrer"
            warn "Créez manuellement le compte admin sur http://votre-serveur:8096"
            info "Utilisateur: $JELLYFIN_USER"
            return
        fi

        # Créer le compte admin via l'API
        log "Création du compte administrateur..."
        RESPONSE=$(curl -s -X POST http://localhost:8096/Startup/User \
            -H "Content-Type: application/json" \
            -d "{\"Name\":\"$JELLYFIN_USER\",\"Password\":\"$JELLYFIN_PASSWORD\"}")

        # Compléter le wizard de démarrage
        curl -s -X POST http://localhost:8096/Startup/Complete >/dev/null 2>&1

        if [ $? -eq 0 ]; then
            log "${GREEN}✓${NC} Compte administrateur créé avec succès !"
            info "Jellyfin est accessible sur le port 8096"
            info "Interface web: http://votre-serveur:8096"
            info "Utilisateur: $JELLYFIN_USER"
            echo ""
            info "Vous pouvez maintenant vous connecter avec vos identifiants"
        else
            warn "Impossible de créer le compte admin automatiquement"
            warn "Créez-le manuellement sur http://votre-serveur:8096"
            info "Utilisateur suggéré: $JELLYFIN_USER"
        fi

        # Ne pas exécuter la section de démarrage normale
        return
        ;;

    dashdot)
        log "Installation de Dashdot (monitoring système)..."
        mkdir -p "$INSTALL_DIR/dashdot"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  dashdot:
    image: mauricenino/dashdot:latest
    container_name: dashdot
    privileged: true
    ports:
      - "3002:3001"
    volumes:
      - $INSTALL_DIR/dashdot:/data
      - /:/mnt/host:ro
    environment:
      - TZ=$TZ
      - DASHDOT_ENABLE_CPU_TEMPS=true
    restart: unless-stopped
EOF
        info "Dashdot sera accessible sur le port 3002"
        info "Interface web: http://votre-serveur:3002"
        ;;

    portainer)
        log "Installation de Portainer (gestion Docker)..."
        mkdir -p "$INSTALL_DIR/portainer"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    ports:
      - "9000:9000"
      - "8000:8000"
    volumes:
      - $INSTALL_DIR/portainer:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=$TZ
    restart: unless-stopped
EOF

        # Démarrer Portainer
        cd "$INSTALL_DIR"
        docker-compose up -d portainer

        # Configuration du compte admin
        log "Configuration du compte administrateur Portainer..."
        echo ""
        read -p "Nom d'utilisateur admin [admin]: " PORTAINER_USER
        PORTAINER_USER=${PORTAINER_USER:-"admin"}

        while true; do
            read -s -p "Mot de passe admin (min 12 caractères): " PORTAINER_PASSWORD
            echo
            if [ ${#PORTAINER_PASSWORD} -ge 12 ]; then
                read -s -p "Confirmez le mot de passe: " PORTAINER_PASSWORD_CONFIRM
                echo
                if [ "$PORTAINER_PASSWORD" = "$PORTAINER_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 12 caractères"
            fi
        done

        # Attendre que Portainer soit prêt (max 60 secondes)
        log "Attente du démarrage de Portainer..."
        RETRY_COUNT=0
        MAX_RETRIES=30
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            if curl -s http://localhost:9000/api/status >/dev/null 2>&1; then
                break
            fi
            sleep 2
            RETRY_COUNT=$((RETRY_COUNT + 1))
        done

        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            warn "Portainer a mis trop de temps à démarrer"
            warn "Créez manuellement le compte admin sur http://votre-serveur:9000"
            info "Utilisateur: $PORTAINER_USER"
            return
        fi

        # Créer le compte admin via l'API
        log "Création du compte administrateur..."
        RESPONSE=$(curl -s -X POST http://localhost:9000/api/users/admin/init \
            -H "Content-Type: application/json" \
            -d "{\"Username\":\"$PORTAINER_USER\",\"Password\":\"$PORTAINER_PASSWORD\"}")

        if echo "$RESPONSE" | grep -q "Id"; then
            log "${GREEN}✓${NC} Compte administrateur créé avec succès !"
            info "Portainer est accessible sur le port 9000"
            info "Interface web: http://votre-serveur:9000"
            info "Utilisateur: $PORTAINER_USER"
            echo ""
            info "Vous pouvez maintenant vous connecter avec vos identifiants"
        else
            warn "Impossible de créer le compte admin automatiquement"
            warn "Créez-le manuellement sur http://votre-serveur:9000 dans les 5 minutes"
            info "Utilisateur suggéré: $PORTAINER_USER"
        fi

        # Ne pas exécuter la section de démarrage normale
        return
        ;;

    tautulli)
        log "Installation de Tautulli (stats Plex)..."
        mkdir -p "$INSTALL_DIR/tautulli"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  tautulli:
    image: linuxserver/tautulli:latest
    container_name: tautulli
    environment:
      - PUID=$ADMIN_UID
      - PGID=$ADMIN_GID
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/tautulli:/config
    ports:
      - "8181:8181"
    restart: unless-stopped
EOF
        info "Tautulli sera accessible sur le port 8181"
        info "Interface web: http://votre-serveur:8181"
        info "Connectez Tautulli à Plex pour voir les statistiques"
        ;;

    organizr)
        log "Installation d'Organizr (dashboard all-in-one)..."
        mkdir -p "$INSTALL_DIR/organizr"

        cat >> "$DOCKER_COMPOSE_FILE" << EOF

  organizr:
    image: organizr/organizr:latest
    container_name: organizr
    environment:
      - PUID=$ADMIN_UID
      - PGID=$ADMIN_GID
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/organizr:/config
    ports:
      - "9983:80"
    restart: unless-stopped
EOF
        info "Organizr sera accessible sur le port 9983"
        info "Interface web: http://votre-serveur:9983"
        info "Premier accès : configurez l'admin et ajoutez vos services"
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
