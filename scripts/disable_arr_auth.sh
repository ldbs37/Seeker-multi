#!/bin/bash

#######################
# Script pour désactiver l'authentification dans les services *arr
# Permet de s'appuyer uniquement sur Authelia/reverse proxy
# Usage: ./disable_arr_auth.sh <username> <service>
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
if [ $# -lt 2 ]; then
    echo "Usage: $0 <username> <service>"
    echo ""
    echo "Services supportés: sonarr, radarr, readarr, prowlarr, lidarr"
    echo ""
    echo "Exemple:"
    echo "  sudo ./disable_arr_auth.sh john sonarr"
    exit 1
fi

USERNAME=$1
SERVICE=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Services supportés
case $SERVICE in
    sonarr|radarr|readarr|prowlarr|lidarr)
        CONTAINER_NAME="${SERVICE}-${USERNAME}"
        ;;
    *)
        error "Service non supporté: $SERVICE. Utilisez: sonarr, radarr, readarr, prowlarr, ou lidarr"
        ;;
esac

# Vérifier que le conteneur existe
if ! docker ps -a --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    error "Le conteneur $CONTAINER_NAME n'existe pas"
fi

CONFIG_DIR="$INSTALL_DIR/$SERVICE/$USERNAME"
CONFIG_FILE="$CONFIG_DIR/config.xml"

# Vérifier que le fichier de config existe
if [ ! -f "$CONFIG_FILE" ]; then
    error "Fichier de configuration non trouvé: $CONFIG_FILE"
fi

log "Désactivation de l'authentification pour $CONTAINER_NAME..."

# Sauvegarder le fichier original
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

# Arrêter le conteneur pour modifier la config
docker stop "$CONTAINER_NAME" >/dev/null 2>&1

# Modifier le fichier de configuration
# On cherche <AuthenticationMethod> et on le met à "None"
if grep -q "<AuthenticationMethod>" "$CONFIG_FILE"; then
    # Remplacer la valeur existante
    sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>None</AuthenticationMethod>|' "$CONFIG_FILE"
    log "✓ AuthenticationMethod mis à 'None'"
else
    # Ajouter la ligne si elle n'existe pas (après la ligne Config)
    sed -i '/<Config>/a\  <AuthenticationMethod>None</AuthenticationMethod>' "$CONFIG_FILE"
    log "✓ AuthenticationMethod ajouté avec valeur 'None'"
fi

# Redémarrer le conteneur
docker start "$CONTAINER_NAME" >/dev/null 2>&1
sleep 3

# Vérifier que le conteneur est bien démarré
if docker ps --format '{{.Names}}' | grep -q "^$CONTAINER_NAME$"; then
    log "✓ $CONTAINER_NAME redémarré avec succès"
else
    error "Échec du redémarrage de $CONTAINER_NAME"
fi

echo ""
info "═══════════════════════════════════════════════════════════"
info "Authentification désactivée pour $CONTAINER_NAME"
info "═══════════════════════════════════════════════════════════"
info ""
info "⚠️  IMPORTANT :"
info "   - Le service n'a plus d'authentification propre"
info "   - Assurez-vous d'avoir Authelia/reverse proxy configuré"
info "   - Sinon, le service sera accessible sans mot de passe !"
info ""
info "💡 Pour réactiver l'authentification :"
info "   1. Éditez: $CONFIG_FILE"
info "   2. Changez AuthenticationMethod en 'Forms' ou 'Basic'"
info "   3. Redémarrez: docker restart $CONTAINER_NAME"
info "═══════════════════════════════════════════════════════════"
