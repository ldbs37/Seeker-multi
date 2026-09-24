#!/bin/bash

#######################
# Script de configuration automatique Homarr
# Génère le tableau de bord de l'utilisateur avec des liens vers SES services
# (détectés dans docker-compose.yml : fonctionne aussi avant le démarrage).
# L'auto-découverte Docker n'est pas utilisée : il faudrait monter le socket
# Docker dans un conteneur par utilisateur (équivalent root) — exclu.
# Usage: ./configure_homarr.sh <username>
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

for lib in lib_ports lib_traefik lib_services; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

[ $# -ge 1 ] || { echo "Usage: $0 <username>"; exit 1; }
USERNAME=$1
[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"

USER_ID=$(id -u "$USERNAME")
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
traefik_detect "$INSTALL_DIR/.env"

HOMARR_CONFIG_DIR="$USER_DIR/config/homarr"
mkdir -p "$HOMARR_CONFIG_DIR"
log "Configuration de Homarr pour $USERNAME..."

# Liens vers les services de l'utilisateur présents dans le compose
# (guillemets simples dans le HTML pour rester valide en JSON)
declare -A SVC_LABELS=(
    [qbittorrent]="qBittorrent" [filebrowser]="Filebrowser"
    [sonarr]="Sonarr" [radarr]="Radarr" [readarr]="Readarr" [bazarr]="Bazarr"
    [prowlarr]="Prowlarr" [overseerr]="Overseerr" [calibre]="Calibre-Web"
)
LINKS=""
for s in qbittorrent filebrowser sonarr radarr readarr bazarr prowlarr overseerr calibre; do
    if grep -q "^  ${s}-${USERNAME}:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; then
        LINKS="${LINKS}<li><a href='$(service_url "$s")' target='_blank' rel='noopener'>${SVC_LABELS[$s]}</a></li>"
    fi
done
[ -n "$LINKS" ] || LINKS="<li>Aucun service pour le moment</li>"
SERVICES_HTML="<h1>Bienvenue ${USERNAME} !</h1><p>Vos services :</p><ul>${LINKS}</ul>"
# API libre-service activée (setup_api.sh) : lien de gestion des services
if [ "$USE_TRAEFIK" = true ] && grep -q '^SEEDBOX_API=true' "$INSTALL_DIR/.env" 2>/dev/null; then
    SERVICES_HTML="${SERVICES_HTML}<p><a href='/seedbox-api/'>➕ Ajouter / retirer des services</a></p>"
fi

# Heredoc NON quoté : ${SERVICES_HTML} est injecté (le JSON ne contient ni $
# ni backtick).
cat > "$HOMARR_CONFIG_DIR/default.json" << EOF
{
  "schemaVersion": 1,
  "configProperties": {
    "name": "default"
  },
  "categories": [
    {
      "id": "downloads",
      "position": 1,
      "name": "Téléchargements"
    },
    {
      "id": "media",
      "position": 2,
      "name": "Média"
    },
    {
      "id": "management",
      "position": 3,
      "name": "Gestion"
    }
  ],
  "wrappers": [],
  "apps": [],
  "widgets": [
    {
      "id": "welcome",
      "type": "html",
      "properties": {
        "html": "${SERVICES_HTML}"
      },
      "area": {
        "type": "wrapper",
        "properties": {
          "gridstack": {
            "x": 0,
            "y": 0,
            "w": 12,
            "h": 2
          }
        }
      }
    }
  ],
  "settings": {
    "common": {
      "searchEngine": {
        "enabled": true,
        "type": "google"
      },
      "quickAccess": []
    },
    "customization": {
      "layout": {
        "enabledLeftSidebar": false,
        "enabledRightSidebar": false,
        "enabledDocker": false,
        "enabledPing": true
      },
      "pageTitle": "Seedbox Dashboard",
      "logoImageUrl": "",
      "faviconUrl": "",
      "backgroundImageUrl": "",
      "customCss": "",
      "colors": {
        "primary": "#fa5252",
        "secondary": "#fd7e14",
        "shade": "#495057"
      }
    }
  }
}
EOF

chown -R "$USER_ID:$USER_ID" "$HOMARR_CONFIG_DIR"
log "✓ Tableau de bord Homarr généré"

# Recharger Homarr s'il tourne déjà
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "homarr-${USERNAME}"; then
    docker restart "homarr-${USERNAME}" >/dev/null 2>&1 && log "✓ Homarr redémarré"
fi

info "📍 Accès: $(service_url homarr)"
