#!/bin/bash

#######################
# Script de modification de mot de passe
# Usage: ./update_password.sh <username> [nouveau_mot_de_passe]
# Met à jour : système Linux, Authelia (SSO), qBittorrent, gestion de fichiers et,
# si configuré, Jellyfin — tous avec le même mot de passe.
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
AUTHELIA_DB="$INSTALL_DIR/authelia/users_database.yml"
AUTHELIA_IMAGE="authelia/authelia:4.39.28"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_qbittorrent.sh" || error "lib_qbittorrent.sh introuvable"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_password.sh" || error "lib_password.sh introuvable"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_traefik.sh" || error "lib_traefik.sh introuvable"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_filebrowser.sh" || error "lib_filebrowser.sh introuvable"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_lang.sh" || error "lib_lang.sh introuvable"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_jellyfin.sh" || error "lib_jellyfin.sh introuvable"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <username> [nouveau_mot_de_passe]"
    echo ""
    echo "Si le mot de passe n'est pas fourni, il sera demandé de manière sécurisée"
    echo "(recommandé : un mot de passe passé en argument reste dans l'historique)."
    exit 1
fi

USERNAME=$1
NEW_PASSWORD=${2:-}

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"
USER_ID=$(id -u "$USERNAME")
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"

# Règle renforcée pour les administrateurs (groupe "admins" d'Authelia)
IS_ADMIN=false
password_user_is_admin "$USERNAME" "$AUTHELIA_DB" && IS_ADMIN=true

if [ -z "$NEW_PASSWORD" ]; then
    echo ""
    info "Mot de passe : $(password_policy "$IS_ADMIN")"
    while true; do
        read -r -s -p "Nouveau mot de passe: " NEW_PASSWORD; echo
        if ! PW_REASON=$(password_check "$NEW_PASSWORD" "$IS_ADMIN"); then
            warn "Mot de passe refusé : $PW_REASON"; continue
        fi
        read -r -s -p "Confirmez le mot de passe: " NEW_PASSWORD_CONFIRM; echo
        [ "$NEW_PASSWORD" = "$NEW_PASSWORD_CONFIRM" ] && break
        warn "Les mots de passe ne correspondent pas"
    done
fi
PW_REASON=$(password_check "$NEW_PASSWORD" "$IS_ADMIN") \
    || error "Mot de passe refusé : $PW_REASON ($(password_policy "$IS_ADMIN"))"

container_exists() { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# Échappe une chaîne pour l'insérer dans du JSON
json_escape() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

log "Modification du mot de passe pour $USERNAME..."

# Hash Authelia calculé AVANT toute modification (rien n'est changé s'il échoue)
NEW_HASH=$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$NEW_PASSWORD" 2>/dev/null \
           | grep 'Digest:' | awk '{print $2}') || true
[[ "$NEW_HASH" == \$argon2* ]] || error "Impossible de générer le hash Authelia — aucun mot de passe modifié"

UPDATED=()

#######################
# 1. Système Linux
#######################
log "Mise à jour du mot de passe système..."
echo "$USERNAME:$NEW_PASSWORD" | chpasswd || error "Échec de la mise à jour du mot de passe système"
UPDATED+=("Système Linux (SSH, console)")

#######################
# 2. Authelia (SSO)
#######################
if grep -q "^  ${USERNAME}:" "$AUTHELIA_DB" 2>/dev/null; then
    log "Mise à jour du mot de passe Authelia..."
    cp "$AUTHELIA_DB" "$AUTHELIA_DB.bak"
    awk -v user="  ${USERNAME}:" -v line="    password: \"${NEW_HASH}\"" '
        $0 == user          { in_user = 1; print; next }
        /^  [^ ]/           { in_user = 0 }
        in_user && /^    password:/ { print line; in_user = 0; next }
        { print }
    ' "$AUTHELIA_DB.bak" > "$AUTHELIA_DB"
    chmod 600 "$AUTHELIA_DB"
    if grep -qF "$NEW_HASH" "$AUTHELIA_DB"; then
        rm -f "$AUTHELIA_DB.bak"
        docker restart authelia >/dev/null 2>&1 || warn "Redémarrez Authelia : docker restart authelia"
        UPDATED+=("Authelia (SSO)")
    else
        cp "$AUTHELIA_DB.bak" "$AUTHELIA_DB"
        error "Échec de la mise à jour Authelia (fichier restauré)"
    fi
else
    warn "Compte Authelia introuvable pour $USERNAME"
fi

#######################
# 3. qBittorrent (conteneur arrêté : il réécrit sa config en quittant)
#######################
QB="qbittorrent-$USERNAME"
QB_CONF="$USER_DIR/config/qbittorrent/qBittorrent/qBittorrent.conf"
if container_exists "$QB" && [ -f "$QB_CONF" ]; then
    log "Mise à jour du mot de passe qBittorrent..."
    docker stop "$QB" >/dev/null 2>&1 || true
    if qbit_configure "$QB_CONF" "$USERNAME" "$NEW_PASSWORD"; then
        chown "$USER_ID:$USER_ID" "$QB_CONF"
        UPDATED+=("qBittorrent")
    else
        warn "Impossible de mettre à jour qBittorrent"
    fi
    docker start "$QB" >/dev/null 2>&1 || warn "Échec du redémarrage de $QB"
fi

#######################
# 4. Gestion de fichiers (FileBrowser Quantum)
#######################
# Connexion unique : pas de mot de passe propre. Repli (en-tête pas encore
# créé) : mot de passe dans sa configuration, réappliqué au redémarrage.
FB="filebrowser-$USERNAME"
FB_CFG="$USER_DIR/config/filebrowser/config.yaml"
traefik_detect "$INSTALL_DIR/.env"
if container_exists "$FB" && [ -f "$FB_CFG" ] && grep -qE '^      enabled: true$' <(sed -n '/^    password:/,/^    [a-z]/p' "$FB_CFG"); then
    log "Mise à jour du mot de passe du gestionnaire de fichiers..."
    if fbq_write_config "$FB_CFG" "$USERNAME" "$NEW_PASSWORD"; then
        chown "$USER_ID:$USER_ID" "$FB_CFG"
        docker restart "$FB" >/dev/null 2>&1 || warn "Échec du redémarrage de $FB"
        UPDATED+=("Fichiers")
    else
        warn "Impossible de mettre à jour le gestionnaire de fichiers"
    fi
fi

#######################
# 5. Jellyfin : compte créé s'il manque (avec ses bibliothèques), sinon
#    mot de passe mis à jour
#######################
if container_exists jellyfin && jellyfin_wait && jellyfin_wizard_done; then
    log "Mise à jour du compte Jellyfin..."
    if jellyfin_user_sync "$USERNAME" "$NEW_PASSWORD"; then
        UPDATED+=("Jellyfin")
        jellyfin_sso_ensure || true
    else
        warn "Impossible de mettre à jour Jellyfin"
    fi
fi

#######################
# Résumé
#######################
echo ""
info "═══════════════════════════════════════════════════════════"
info "Mot de passe mis à jour pour $USERNAME :"
for u in "${UPDATED[@]}"; do info "   ✓ $u"; done
info ""
info "Homarr n'a pas d'authentification propre (protégé par Authelia)."
info "Mode Traefik : Sonarr, Radarr, Prowlarr et Calibre-web n'ont pas de"
info "mot de passe propre (connexion via Authelia, voir arr_setup.sh)."
info "═══════════════════════════════════════════════════════════"
