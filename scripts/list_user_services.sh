#!/bin/bash

#######################
# Script de listage des services d'un utilisateur
# Usage: ./list_user_services.sh <username>
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

# Vérification des arguments
if [ $# -ne 1 ]; then
    error "Usage: $0 <username>"
fi

USERNAME=$1

# Vérifier si l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Récupérer l'UID
USER_ID=$(id -u "$USERNAME")
BASE_PORT=$((USER_ID - 1000))

echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Services pour l'utilisateur: $USERNAME"
echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}\n"

# Liste des services possibles
declare -A SERVICES=(
    ["qbittorrent"]="$((8080 + BASE_PORT * 10))"
    ["sonarr"]="$((8989 + BASE_PORT))"
    ["radarr"]="$((7878 + BASE_PORT))"
    ["readarr"]="$((8787 + BASE_PORT))"
    ["bazarr"]="$((6767 + BASE_PORT))"
    ["prowlarr"]="$((9696 + BASE_PORT))"
    ["overseerr"]="$((5055 + BASE_PORT))"
    ["homarr"]="$((7575 + BASE_PORT))"
    ["calibre"]="$((8083 + BASE_PORT))"
    ["filebrowser"]="$((8081 + BASE_PORT))"
)

# Afficher les services installés
echo -e "${GREEN}Services installés:${NC}"
for service in "${!SERVICES[@]}"; do
    container_name="${service}-${USERNAME}"
    if docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        status=$(docker ps --filter "name=^${container_name}$" --format '{{.Status}}')
        if [ -n "$status" ]; then
            echo -e "  ${GREEN}✓${NC} ${service^} - Port: ${SERVICES[$service]} - ${GREEN}Running${NC}"
        else
            echo -e "  ${YELLOW}!${NC} ${service^} - Port: ${SERVICES[$service]} - ${YELLOW}Stopped${NC}"
        fi
    fi
done

# Afficher les services disponibles mais non installés
echo -e "\n${YELLOW}Services disponibles (non installés):${NC}"
AVAILABLE_SERVICES=(sonarr radarr readarr bazarr prowlarr overseerr calibre)
for service in "${AVAILABLE_SERVICES[@]}"; do
    container_name="${service}-${USERNAME}"
    if ! docker ps -a --format '{{.Names}}' | grep -q "^$container_name$"; then
        echo -e "  ${BLUE}○${NC} ${service^} - Port: ${SERVICES[$service]}"
    fi
done

echo -e "\n${BLUE}Pour ajouter un service:${NC}"
echo "  sudo ./add_user_service.sh $USERNAME <service>"
echo ""
echo -e "${BLUE}Exemple:${NC}"
echo "  sudo ./add_user_service.sh $USERNAME sonarr"
echo ""
