#!/bin/bash

#######################
# Script d'ajout de service à un utilisateur existant
# Usage: ./add_user_service.sh <username> <service>
# Services: sonarr, radarr, readarr, bazarr, prowlarr, overseerr, calibre
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

# Vérification des arguments
if [ $# -ne 2 ]; then
    echo "Usage: $0 <username> <service>"
    echo ""
    echo "Services disponibles:"
    echo "  - sonarr      : Gestion de séries TV"
    echo "  - radarr      : Gestion de films"
    echo "  - readarr     : Gestion de livres"
    echo "  - bazarr      : Gestion de sous-titres"
    echo "  - prowlarr    : Gestion d'indexeurs"
    echo "  - overseerr   : Système de requêtes"
    echo "  - calibre     : Bibliothèque ebooks"
    exit 1
fi

USERNAME=$1
SERVICE=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier si l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Récupérer l'UID de l'utilisateur
USER_ID=$(id -u "$USERNAME")
BASE_DIR="$INSTALL_DIR/data/users/$USERNAME"

# Calculer le port de base pour cet utilisateur
BASE_PORT=$((USER_ID - 1000))

# Vérifier si le service est déjà installé
CONTAINER_NAME="${SERVICE}-${USERNAME}"
if docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    warn "Le service $SERVICE est déjà installé pour $USERNAME"
    exit 0
fi

# Créer les dossiers nécessaires
log "Création des dossiers pour $SERVICE..."
mkdir -p "$INSTALL_DIR/$SERVICE/$USERNAME"
chown -R "$USER_ID:$USER_ID" "$INSTALL_DIR/$SERVICE/$USERNAME"

# Fonction pour ajouter le service au docker-compose.yml
add_service_to_compose() {
    local service=$1
    local username=$2
    local user_id=$3

    # Sauvegarder le docker-compose.yml
    cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"

    case $service in
        sonarr)
            local port=$((8989 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  sonarr-$username:
    image: linuxserver/sonarr:latest
    container_name: sonarr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/sonarr/$username:/config
      - $BASE_DIR/tv:/tv
      - $BASE_DIR/downloads:/downloads
    ports:
      - "$port:8989"
    restart: unless-stopped
EOF
            info "Sonarr sera accessible sur le port $port"
            ;;

        radarr)
            local port=$((7878 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  radarr-$username:
    image: linuxserver/radarr:latest
    container_name: radarr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/radarr/$username:/config
      - $BASE_DIR/movies:/movies
      - $BASE_DIR/downloads:/downloads
    ports:
      - "$port:7878"
    restart: unless-stopped
EOF
            info "Radarr sera accessible sur le port $port"
            ;;

        readarr)
            local port=$((8787 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  readarr-$username:
    image: lscr.io/linuxserver/readarr:develop
    container_name: readarr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/readarr/$username:/config
      - $BASE_DIR/books:/books
      - $BASE_DIR/downloads:/downloads
    ports:
      - "$port:8787"
    restart: unless-stopped
EOF
            info "Readarr sera accessible sur le port $port"
            ;;

        bazarr)
            local port=$((6767 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  bazarr-$username:
    image: linuxserver/bazarr:latest
    container_name: bazarr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/bazarr/$username:/config
      - $BASE_DIR/movies:/movies
      - $BASE_DIR/tv:/tv
    ports:
      - "$port:6767"
    restart: unless-stopped
EOF
            info "Bazarr sera accessible sur le port $port"
            ;;

        prowlarr)
            local port=$((9696 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  prowlarr-$username:
    image: linuxserver/prowlarr:latest
    container_name: prowlarr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/prowlarr/$username:/config
    ports:
      - "$port:9696"
    restart: unless-stopped
EOF
            info "Prowlarr sera accessible sur le port $port"
            ;;

        overseerr)
            local port=$((5055 + BASE_PORT))
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  overseerr-$username:
    image: sctx/overseerr:latest
    container_name: overseerr-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/overseerr/$username:/app/config
    ports:
      - "$port:5055"
    restart: unless-stopped
EOF
            info "Overseerr sera accessible sur le port $port"
            ;;

        calibre)
            local port=$((8083 + BASE_PORT))
            mkdir -p "$BASE_DIR/books/library"
            mkdir -p "$BASE_DIR/books/uploads"
            chown -R "$user_id:$user_id" "$BASE_DIR/books"
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  calibre-$username:
    image: linuxserver/calibre-web:latest
    container_name: calibre-$username
    environment:
      - PUID=$user_id
      - PGID=$user_id
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/calibre/$username:/config
      - $BASE_DIR/books:/books
    ports:
      - "$port:8083"
    restart: unless-stopped
EOF
            info "Calibre-web sera accessible sur le port $port"
            ;;

        *)
            error "Service inconnu: $service"
            ;;
    esac
}

# Ajouter le service
log "Ajout du service $SERVICE pour l'utilisateur $USERNAME..."
add_service_to_compose "$SERVICE" "$USERNAME" "$USER_ID"

# Démarrer le service
log "Démarrage du service..."
cd "$INSTALL_DIR"
docker-compose up -d "$CONTAINER_NAME"

# Vérifier que le service est démarré
sleep 5
if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    log "${GREEN}✓${NC} Service $SERVICE ajouté avec succès pour $USERNAME !"

    # Afficher le port
    local display_port
    case $SERVICE in
        sonarr) display_port=$((8989 + BASE_PORT)) ;;
        radarr) display_port=$((7878 + BASE_PORT)) ;;
        readarr) display_port=$((8787 + BASE_PORT)) ;;
        bazarr) display_port=$((6767 + BASE_PORT)) ;;
        prowlarr) display_port=$((9696 + BASE_PORT)) ;;
        overseerr) display_port=$((5055 + BASE_PORT)) ;;
        calibre) display_port=$((8083 + BASE_PORT)) ;;
    esac

    info "Accessible sur: http://votre-serveur:$display_port"
else
    error "Le service $SERVICE n'a pas pu démarrer. Vérifiez les logs avec: docker logs $CONTAINER_NAME"
fi
