#!/bin/bash

#######################
# Compte Jellyfin d'un utilisateur de la seedbox (lib_jellyfin.sh)
# Usage: ./configure_jellyfin_user.sh <username> [password] [jellyfin_api_key]
#
# - crée le compte Jellyfin s'il manque (mot de passe donné, sinon
#   aléatoire : connexion via Authelia, ou update_password.sh) ;
# - crée SES bibliothèques (séries, films, livres, musique) dans son dossier ;
# - limite son accès à SES bibliothèques (administrateurs seedbox : tout) ;
# - mode Traefik : met à jour les droits de la connexion via Authelia.
# Fait automatiquement par add_user.sh, update_password.sh et
# generate_traefik_labels.sh ; utile pour réparer un compte.
# Clé d'API : « seedbox » (créée au besoin) ; la 3e option est facultative.
#######################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ $# -ge 1 ] || { echo "Usage: $0 <username> [password] [jellyfin_api_key]"; exit 1; }
USERNAME=$1; PASSWORD=${2:-}

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"
for lib in lib_ports lib_traefik lib_lang lib_password lib_jellyfin; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || error "$lib.sh introuvable"
done
# shellcheck disable=SC2034  # lue par lib_jellyfin.sh
[ -n "${3:-}" ] && JF_KEY=$3
traefik_require "$INSTALL_DIR/.env"

jellyfin_wait || error "Jellyfin n'est pas accessible sur $JELLYFIN_LOCAL_URL"
jellyfin_wizard_done || error "Assistant Jellyfin non terminé : lancez generate_traefik_labels.sh (ou terminez-le sur http://<serveur>:8096)"
jellyfin_user_sync "$USERNAME" "$PASSWORD" || error "Compte Jellyfin de $USERNAME incomplet"
log "✓ Jellyfin : compte et bibliothèques de $USERNAME"
jellyfin_sso_ensure && log "✓ Connexion via Authelia à jour"
