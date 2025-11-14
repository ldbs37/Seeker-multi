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

# Configuration par défaut de Homarr avec les services de l'utilisateur
cat > "$HOMARR_CONFIG_DIR/configs/default.json" << 'EOF'
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
        "html": "<h1>Bienvenue sur votre Seedbox!</h1><p>Vos services sont configurés automatiquement.</p>"
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
        "enabledDocker": true,
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
info "   - Les services avec Docker labels seront auto-détectés"
info "   - Ajoutez manuellement d'autres services via l'interface"
info "   - Personnalisez l'apparence dans les paramètres"
info ""
info "🔧 Services disponibles:"
info "   - qBittorrent sera auto-détecté"
info "   - Filebrowser sera auto-détecté"
info "   - Autres services: ajoutez-les manuellement ou via l'API"
info ""
info "═══════════════════════════════════════════════════════════"
