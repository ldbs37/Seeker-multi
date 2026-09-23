#!/bin/bash

#######################
# Script de configuration automatique Homarr
# Configure Homarr avec les services de l'utilisateur via Docker labels
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

# Vérification des arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <username>"
    exit 1
fi

USERNAME=$1

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier que l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

USER_ID=$(id -u "$USERNAME")
HOMARR_PORT=$((7575 + USER_ID - 1000))

log "Configuration de Homarr pour $USERNAME (port $HOMARR_PORT)..."

# Créer le fichier de configuration Homarr
HOMARR_CONFIG_DIR="$INSTALL_DIR/data/users/$USERNAME/config/homarr"
mkdir -p "$HOMARR_CONFIG_DIR/configs"
mkdir -p "$HOMARR_CONFIG_DIR/data"
mkdir -p "$HOMARR_CONFIG_DIR/icons"

# Détecter le mode d'accès (Traefik/SSL ou port direct) depuis .env
ENV_FILE="$INSTALL_DIR/.env"
USE_TRAEFIK=false
DOMAIN=""
if [ -f "$ENV_FILE" ]; then
    grep -q '^USE_TRAEFIK=true' "$ENV_FILE" && USE_TRAEFIK=true
    DOMAIN=$(grep '^DOMAIN=' "$ENV_FILE" | cut -d'=' -f2)
fi
HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); [ -n "$HOST_IP" ] || HOST_IP="localhost"
BASE_PORT=$((USER_ID - 1000))

# URL d'un service selon le mode d'accès
svc_url() {
    local p path
    case "$1" in
        qbittorrent) p=$((8080 + BASE_PORT * 10)); path="/qbittorrent" ;;
        filebrowser) p=$((8081 + BASE_PORT));      path="/files" ;;
        sonarr)      p=$((8989 + BASE_PORT));       path="/sonarr" ;;
        radarr)      p=$((7878 + BASE_PORT));       path="/radarr" ;;
        readarr)     p=$((8787 + BASE_PORT));       path="/readarr" ;;
        bazarr)      p=$((6767 + BASE_PORT));       path="/bazarr" ;;
        prowlarr)    p=$((9696 + BASE_PORT));       path="/prowlarr" ;;
        overseerr)   p=$((5055 + BASE_PORT));       path="/overseerr" ;;
        calibre)     p=$((8083 + BASE_PORT));       path="/calibre" ;;
        *) return 1 ;;
    esac
    if [ "$USE_TRAEFIK" = true ] && [ -n "$DOMAIN" ]; then
        echo "https://${USERNAME}.${DOMAIN}${path}"
    else
        echo "http://${HOST_IP}:${p}"
    fi
}

# Construire la liste des services RÉELLEMENT présents pour cet utilisateur
# (détection par nom de conteneur), sous forme de liens HTML (guillemets
# simples pour rester valide en JSON).
declare -A SVC_LABELS=(
    [qbittorrent]="qBittorrent" [filebrowser]="Filebrowser"
    [sonarr]="Sonarr" [radarr]="Radarr" [readarr]="Readarr" [bazarr]="Bazarr"
    [prowlarr]="Prowlarr" [overseerr]="Overseerr" [calibre]="Calibre-Web"
)
LINKS=""
for s in qbittorrent filebrowser sonarr radarr readarr bazarr prowlarr overseerr calibre; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${s}-${USERNAME}$"; then
        LINKS="${LINKS}<li><a href='$(svc_url "$s")' target='_blank' rel='noopener'>${SVC_LABELS[$s]}</a></li>"
    fi
done
[ -n "$LINKS" ] || LINKS="<li>Aucun service détecté pour le moment</li>"
SERVICES_HTML="<h1>Bienvenue ${USERNAME} !</h1><p>Vos services :</p><ul>${LINKS}</ul>"

# Configuration par défaut de Homarr avec les services de l'utilisateur
# (heredoc NON quoté : \${SERVICES_HTML} est injecté ; le JSON ne contient
# ni \$ ni backtick).
cat > "$HOMARR_CONFIG_DIR/configs/default.json" << EOF
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

# Changer les permissions
chown -R "$USER_ID:$USER_ID" "$HOMARR_CONFIG_DIR"

log "✓ Configuration Homarr créée"

# Attendre que Homarr soit démarré
info "Attente du démarrage de Homarr..."
RETRY_COUNT=0
MAX_RETRIES=30
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s "http://localhost:$HOMARR_PORT" >/dev/null 2>&1; then
        break
    fi
    sleep 2
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
    warn "Homarr a mis trop de temps à démarrer"
    info "Configuration créée mais Homarr n'est pas encore accessible"
else
    log "✓ Homarr est accessible sur http://localhost:$HOMARR_PORT"
fi

# Instructions pour l'utilisateur
echo ""
info "═══════════════════════════════════════════════════════════"
info "Homarr est maintenant configuré pour $USERNAME"
info "═══════════════════════════════════════════════════════════"
info ""
info "📍 Accès: http://votre-serveur:$HOMARR_PORT"
info ""
info "🎨 Personnalisation:"
info "   - Vos services sont pré-listés (liens) sur le tableau de bord"
info "   - Ajoutez des tuiles/widgets supplémentaires via l'interface"
info "   - Personnalisez l'apparence dans les paramètres"
info ""
info "ℹ️  Note: l'auto-découverte Docker n'est pas activée (le socket Docker"
info "   n'est pas monté dans Homarr, par sécurité). Les services sont donc"
info "   listés à partir des conteneurs détectés au moment de la configuration."
info ""
info "═══════════════════════════════════════════════════════════"
