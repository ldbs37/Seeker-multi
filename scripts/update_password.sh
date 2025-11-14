#!/bin/bash

#######################
# Script de modification de mot de passe utilisateur
# Modifie le mot de passe système, Authelia, et optionnellement Jellyfin
# Usage: ./update_password.sh <username> [nouveau_mot_de_passe]
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
AUTHELIA_CONFIG_DIR="$INSTALL_DIR/authelia"
JELLYFIN_URL="http://localhost:8096"

# Vérification des arguments
if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [nouveau_mot_de_passe]"
    echo ""
    echo "Si le mot de passe n'est pas fourni, il sera demandé de manière sécurisée."
    echo ""
    echo "Exemple:"
    echo "  sudo ./update_password.sh john"
    echo "  sudo ./update_password.sh john NewSecurePass456"
    exit 1
fi

USERNAME=$1
NEW_PASSWORD=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier que l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Demander le mot de passe si non fourni
if [ -z "$NEW_PASSWORD" ]; then
    echo ""
    while true; do
        read -s -p "Nouveau mot de passe (min 8 caractères): " NEW_PASSWORD
        echo
        if [ ${#NEW_PASSWORD} -ge 8 ]; then
            read -s -p "Confirmez le mot de passe: " NEW_PASSWORD_CONFIRM
            echo
            if [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ]; then
                break
            else
                warn "Les mots de passe ne correspondent pas"
            fi
        else
            warn "Le mot de passe doit contenir au moins 8 caractères"
        fi
    done
fi

# Validation du mot de passe
if [ ${#NEW_PASSWORD} -lt 8 ]; then
    error "Le mot de passe doit contenir au moins 8 caractères"
fi

log "Modification du mot de passe pour $USERNAME..."

#######################
# 1. Mot de passe système Linux
#######################

log "Mise à jour du mot de passe système..."
echo "$USERNAME:$NEW_PASSWORD" | chpasswd

if [ $? -eq 0 ]; then
    log "✓ Mot de passe système mis à jour"
else
    error "Échec de la mise à jour du mot de passe système"
fi

#######################
# 2. Mot de passe Authelia
#######################

log "Mise à jour du mot de passe Authelia..."

# Générer le nouveau hash Argon2
NEW_HASHED_PASSWORD=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$NEW_PASSWORD" | grep 'Digest:' | awk '{print $2}')

if [ -z "$NEW_HASHED_PASSWORD" ]; then
    error "Impossible de générer le hash Argon2"
fi

# Sauvegarder le fichier original
cp "$AUTHELIA_CONFIG_DIR/users_database.yml" "$AUTHELIA_CONFIG_DIR/users_database.yml.bak"

# Remplacer le mot de passe dans le fichier Authelia
# On utilise awk pour remplacer uniquement le mot de passe de l'utilisateur spécifié
awk -v user="  $USERNAME:" -v newpass="    password: $NEW_HASHED_PASSWORD" '
BEGIN { in_user=0 }
{
    if ($0 == user) {
        in_user=1
        print $0
    } else if (in_user && /^    password:/) {
        print newpass
        in_user=0
    } else {
        print $0
    }
}' "$AUTHELIA_CONFIG_DIR/users_database.yml.bak" > "$AUTHELIA_CONFIG_DIR/users_database.yml"

# Vérifier que la modification a réussi
if grep -A 5 "  $USERNAME:" "$AUTHELIA_CONFIG_DIR/users_database.yml" | grep -q "$NEW_HASHED_PASSWORD"; then
    log "✓ Mot de passe Authelia mis à jour"
    rm "$AUTHELIA_CONFIG_DIR/users_database.yml.bak"
else
    error "Échec de la mise à jour du mot de passe Authelia"
fi

# Redémarrer Authelia pour prendre en compte les changements
log "Redémarrage d'Authelia..."
docker restart authelia >/dev/null 2>&1
sleep 2
log "✓ Authelia redémarré"

#######################
# 3. Mot de passe Jellyfin (optionnel)
#######################

if docker ps --format '{{.Names}}' | grep -q "^jellyfin$"; then
    log "Jellyfin détecté. Mise à jour du mot de passe Jellyfin..."

    # Vérifier si la clé API est configurée
    if [ -f "$INSTALL_DIR/.jellyfin_api" ]; then
        source "$INSTALL_DIR/.jellyfin_api"

        # Vérifier que Jellyfin est accessible
        if curl -s "$JELLYFIN_URL/health" >/dev/null 2>&1; then
            # Récupérer l'ID utilisateur Jellyfin
            USERS_LIST=$(curl -s "$JELLYFIN_URL/Users" -H "X-Emby-Token: $JELLYFIN_API_KEY")
            JELLYFIN_USER_ID=$(echo "$USERS_LIST" | grep -o "\"Name\":\"$USERNAME\".*\"Id\":\"[^\"]*\"" | grep -o '"Id":"[^"]*"' | cut -d'"' -f4)

            if [ -n "$JELLYFIN_USER_ID" ]; then
                # Mettre à jour le mot de passe via l'API
                RESPONSE=$(curl -s -X POST "$JELLYFIN_URL/Users/$JELLYFIN_USER_ID/Password" \
                    -H "Content-Type: application/json" \
                    -H "X-Emby-Token: $JELLYFIN_API_KEY" \
                    -d "{
                        \"Id\": \"$JELLYFIN_USER_ID\",
                        \"NewPw\": \"$NEW_PASSWORD\",
                        \"ResetPassword\": false
                    }")

                if [ $? -eq 0 ]; then
                    log "✓ Mot de passe Jellyfin mis à jour"
                else
                    warn "Échec de la mise à jour du mot de passe Jellyfin"
                    info "Vous pouvez le mettre à jour manuellement dans l'interface Jellyfin"
                fi
            else
                warn "Utilisateur $USERNAME non trouvé dans Jellyfin"
                info "Créez le compte Jellyfin avec: sudo ./configure_jellyfin_user.sh $USERNAME <password> \$JELLYFIN_API_KEY"
            fi
        else
            warn "Jellyfin n'est pas accessible"
        fi
    else
        info "Clé API Jellyfin non configurée"
        info "Le mot de passe Jellyfin n'a pas été mis à jour"
        info "Mettez-le à jour manuellement dans l'interface Jellyfin"
    fi
else
    info "Jellyfin non installé, ignoré"
fi

#######################
# 4. Autres services (optionnel)
#######################

# Note: Les autres services utilisateur (qBittorrent, Sonarr, etc.) ont leurs propres
# systèmes de mots de passe indépendants. L'utilisateur doit les changer manuellement
# dans chaque interface web.

#######################
# Résumé
#######################

echo ""
info "═══════════════════════════════════════════════════════════"
info "Mot de passe mis à jour pour $USERNAME"
info "═══════════════════════════════════════════════════════════"
info ""
info "✅ Services mis à jour automatiquement :"
info "   - Système Linux (SSH, console)"
info "   - Authelia (authentification centralisée)"
if docker ps --format '{{.Names}}' | grep -q "^jellyfin$" && [ -f "$INSTALL_DIR/.jellyfin_api" ]; then
    info "   - Jellyfin (streaming média)"
fi
info ""
info "⚠️  Services à mettre à jour manuellement :"
info ""
info "   📥 qBittorrent :"
info "      1. Connectez-vous à l'interface web"
info "      2. Allez dans Options → Web UI"
info "      3. Changez le mot de passe dans 'Authentification'"
info ""
info "   📂 Filebrowser :"
info "      1. Connectez-vous à l'interface web"
info "      2. Allez dans Settings → User Management"
info "      3. Sélectionnez votre utilisateur et changez le mot de passe"
info ""
info "   🖥️  Homarr :"
info "      Pas d'authentification propre - utilise Authelia (déjà mis à jour ✓)"
info ""
info "   📺 Sonarr, Radarr, Prowlarr, etc. :"
info "      1. Connectez-vous à chaque interface"
info "      2. Settings → General → Security"
info "      3. Changez API Key si utilisé pour authentification"
info ""
info "💡 Conseil : Notez ce mot de passe dans un gestionnaire sécurisé"
info "═══════════════════════════════════════════════════════════"
