#!/bin/bash

#######################
# Script de configuration automatique utilisateur Jellyfin
# Crée un compte Jellyfin et configure les bibliothèques média
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
JELLYFIN_URL="http://localhost:8096"

# Vérification des arguments
if [ $# -lt 3 ]; then
    echo "Usage: $0 <username> <password> <admin_api_key>"
    echo ""
    echo "Exemple:"
    echo "  sudo ./configure_jellyfin_user.sh john MyPass123 <admin_api_key>"
    exit 1
fi

USERNAME=$1
PASSWORD=$2
ADMIN_API_KEY=$3

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier que Jellyfin est démarré
log "Vérification de Jellyfin..."
if ! curl -s "$JELLYFIN_URL/health" >/dev/null 2>&1; then
    error "Jellyfin n'est pas accessible sur $JELLYFIN_URL"
fi

USER_ID=$(id -u "$USERNAME" 2>/dev/null)
if [ -z "$USER_ID" ]; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

USER_DIR="$INSTALL_DIR/data/users/$USERNAME"

log "Configuration Jellyfin pour $USERNAME..."

#######################
# 1. Créer l'utilisateur Jellyfin
#######################

log "Création du compte Jellyfin..."

USER_CREATE_RESPONSE=$(curl -s -X POST "$JELLYFIN_URL/Users/New" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Token: $ADMIN_API_KEY" \
    -d "{
        \"Name\": \"$USERNAME\",
        \"Password\": \"$PASSWORD\"
    }")

JELLYFIN_USER_ID=$(echo "$USER_CREATE_RESPONSE" | grep -o '"Id":"[^"]*"' | head -1 | cut -d'"' -f4)

if [ -z "$JELLYFIN_USER_ID" ]; then
    warn "Impossible de créer l'utilisateur (peut-être existe déjà)"
    # Essayer de récupérer l'ID de l'utilisateur existant
    USERS_LIST=$(curl -s "$JELLYFIN_URL/Users" -H "X-Emby-Token: $ADMIN_API_KEY")
    JELLYFIN_USER_ID=$(echo "$USERS_LIST" | grep -o "\"Name\":\"$USERNAME\".*\"Id\":\"[^\"]*\"" | grep -o '"Id":"[^"]*"' | cut -d'"' -f4)
fi

if [ -z "$JELLYFIN_USER_ID" ]; then
    error "Impossible de créer ou trouver l'utilisateur Jellyfin"
fi

log "✓ Utilisateur Jellyfin créé (ID: ${JELLYFIN_USER_ID:0:8}...)"

#######################
# 2. Configurer les bibliothèques média
#######################

log "Configuration des bibliothèques média..."

# Créer les dossiers média s'ils n'existent pas
mkdir -p "$USER_DIR"/{tv,movies,books,music}
chown -R "$USER_ID:$USER_ID" "$USER_DIR"

# Fonction pour créer une bibliothèque
create_library() {
    local name=$1
    local path=$2
    local type=$3

    log "  - Ajout bibliothèque $name..."

    curl -s -X POST "$JELLYFIN_URL/Library/VirtualFolders" \
        -H "Content-Type: application/json" \
        -H "X-Emby-Token: $ADMIN_API_KEY" \
        -d "{
            \"Name\": \"$name ($USERNAME)\",
            \"CollectionType\": \"$type\",
            \"Paths\": [\"$path\"],
            \"LibraryOptions\": {
                \"EnablePhotos\": true,
                \"EnableRealtimeMonitor\": true,
                \"EnableChapterImageExtraction\": false
            }
        }" >/dev/null 2>&1
}

# Créer les bibliothèques pour cet utilisateur
create_library "Séries TV" "$USER_DIR/tv" "tvshows"
create_library "Films" "$USER_DIR/movies" "movies"
create_library "Livres" "$USER_DIR/books" "books"
create_library "Musique" "$USER_DIR/music" "music"

log "✓ Bibliothèques créées"

#######################
# 3. Configurer les permissions utilisateur
#######################

log "Configuration des permissions..."

# Permissions par défaut : accès à ses propres bibliothèques
curl -s -X POST "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Policy" \
    -H "Content-Type: application/json" \
    -H "X-Emby-Token: $ADMIN_API_KEY" \
    -d '{
        "IsAdministrator": false,
        "IsHidden": false,
        "IsDisabled": false,
        "EnableUserPreferenceAccess": true,
        "EnableRemoteAccess": true,
        "EnableLiveTvAccess": false,
        "EnableMediaPlayback": true,
        "EnableAudioPlaybackTranscoding": true,
        "EnableVideoPlaybackTranscoding": true,
        "EnableContentDeletion": false,
        "EnableContentDownloading": true,
        "EnableSyncTranscoding": true,
        "EnableMediaConversion": false,
        "EnableAllDevices": true,
        "EnableAllChannels": false,
        "EnableAllFolders": false,
        "EnableRemoteControlOfOtherUsers": false,
        "EnableSharedDeviceControl": false,
        "EnablePublicSharing": false,
        "InvalidLoginAttemptCount": 0,
        "LoginAttemptsBeforeLockout": 5,
        "MaxActiveSessions": 0,
        "AuthenticationProviderId": "Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider"
    }' >/dev/null 2>&1

log "✓ Permissions configurées"

#######################
# 4. Lancer un scan des bibliothèques
#######################

log "Lancement du scan des bibliothèques..."

curl -s -X POST "$JELLYFIN_URL/Library/Refresh" \
    -H "X-Emby-Token: $ADMIN_API_KEY" >/dev/null 2>&1

log "✓ Scan lancé en arrière-plan"

#######################
# Résumé
#######################

echo ""
info "═══════════════════════════════════════════════════════════"
info "Configuration Jellyfin terminée pour $USERNAME"
info "═══════════════════════════════════════════════════════════"
info ""
info "📺 Accès: $JELLYFIN_URL"
info "👤 Utilisateur: $USERNAME"
info "🔑 Mot de passe: [celui fourni]"
info ""
info "📚 Bibliothèques créées:"
info "   - Séries TV: $USER_DIR/tv"
info "   - Films: $USER_DIR/movies"
info "   - Livres: $USER_DIR/books"
info "   - Musique: $USER_DIR/music"
info ""
info "💡 L'utilisateur peut maintenant se connecter à Jellyfin"
info "═══════════════════════════════════════════════════════════"
