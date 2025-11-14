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
ENV_FILE="$INSTALL_DIR/.env"
TZ="Europe/Paris"
USE_TRAEFIK=false
DOMAIN=""

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

# Détecter si Traefik est actif
detect_traefik() {
    # Vérifier si le domaine est configuré dans .env
    if [ -f "$ENV_FILE" ] && grep -q "^DOMAIN=" "$ENV_FILE"; then
        DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)
        if [ -n "$DOMAIN" ]; then
            USE_TRAEFIK=true
            info "Mode Traefik détecté avec domaine: $DOMAIN"
        fi
    fi
}

# Générer les labels Traefik pour un service
generate_traefik_labels() {
    local service_name=$1
    local username=$2
    local port=$3
    local path=$4
    local protect_with_authelia=${5:-true}

    if [ "$USE_TRAEFIK" != "true" ]; then
        return
    fi

    local subdomain="${username}.${DOMAIN}"

    echo "    networks:"
    echo "      - traefik_proxy"
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo -n "      - \"traefik.http.routers.${service_name}.rule=Host(\\\`${subdomain}\\\`)"
    if [ -n "$path" ]; then
        echo -n " && PathPrefix(\\\`${path}\\\`)"
    fi
    echo "\""
    echo "      - \"traefik.http.routers.${service_name}.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.${service_name}.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.services.${service_name}.loadbalancer.server.port=${port}\""

    if [ "$protect_with_authelia" = "true" ]; then
        echo "      - \"traefik.http.routers.${service_name}.middlewares=authelia@docker\""
    fi
}

# Vérifier si l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Détecter le mode Traefik
detect_traefik

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
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "sonarr-$username" "$username" "8989" "/sonarr" "true")
    restart: unless-stopped
EOF
                info "Sonarr sera accessible sur https://$username.$DOMAIN/sonarr"
            else
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
            fi
            ;;

        radarr)
            local port=$((7878 + BASE_PORT))
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "radarr-$username" "$username" "7878" "/radarr" "true")
    restart: unless-stopped
EOF
                info "Radarr sera accessible sur https://$username.$DOMAIN/radarr"
            else
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
            fi
            ;;

        readarr)
            local port=$((8787 + BASE_PORT))
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "readarr-$username" "$username" "8787" "/readarr" "true")
    restart: unless-stopped
EOF
                info "Readarr sera accessible sur https://$username.$DOMAIN/readarr"
            else
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
            fi
            ;;

        bazarr)
            local port=$((6767 + BASE_PORT))
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "bazarr-$username" "$username" "6767" "/bazarr" "true")
    restart: unless-stopped
EOF
                info "Bazarr sera accessible sur https://$username.$DOMAIN/bazarr"
            else
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
            fi
            ;;

        prowlarr)
            local port=$((9696 + BASE_PORT))
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "prowlarr-$username" "$username" "9696" "/prowlarr" "true")
    restart: unless-stopped
EOF
                info "Prowlarr sera accessible sur https://$username.$DOMAIN/prowlarr"
            else
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
            fi
            ;;

        overseerr)
            local port=$((5055 + BASE_PORT))
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "overseerr-$username" "$username" "5055" "/overseerr" "true")
    restart: unless-stopped
EOF
                info "Overseerr sera accessible sur https://$username.$DOMAIN/overseerr"
            else
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
            fi
            ;;

        calibre)
            local port=$((8083 + BASE_PORT))
            mkdir -p "$BASE_DIR/books/library"
            mkdir -p "$BASE_DIR/books/uploads"
            chown -R "$user_id:$user_id" "$BASE_DIR/books"
            if [ "$USE_TRAEFIK" = "true" ]; then
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
$(generate_traefik_labels "calibre-$username" "$username" "8083" "/calibre" "true")
    restart: unless-stopped
EOF
                info "Calibre-web sera accessible sur https://$username.$DOMAIN/calibre"
            else
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
            fi
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

    if [ "$USE_TRAEFIK" = "true" ]; then
        # Mode Traefik : afficher les URLs HTTPS
        local service_path
        case $SERVICE in
            sonarr) service_path="/sonarr" ;;
            radarr) service_path="/radarr" ;;
            readarr) service_path="/readarr" ;;
            bazarr) service_path="/bazarr" ;;
            prowlarr) service_path="/prowlarr" ;;
            overseerr) service_path="/overseerr" ;;
            calibre) service_path="/calibre" ;;
        esac

        info "Accessible sur: https://$USERNAME.$DOMAIN$service_path"
        info "Connexion SSO via: https://auth.$DOMAIN"
    else
        # Mode port direct : afficher les ports
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
    fi
else
    error "Le service $SERVICE n'a pas pu démarrer. Vérifiez les logs avec: docker logs $CONTAINER_NAME"
fi
