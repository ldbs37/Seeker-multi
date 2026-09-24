#!/bin/bash

#######################
# Création d'un compte Jellyfin pour un utilisateur de la seedbox
# Usage: ./configure_jellyfin_user.sh <username> <password> <jellyfin_api_key>
#
# - crée le compte Jellyfin (mêmes identifiants que la seedbox) ;
# - crée SES bibliothèques (séries, films, livres, musique) pointant sur son
#   dossier, vu par le conteneur sous /media/users/<user>/ ;
# - limite son accès à SES bibliothèques uniquement.
# La clé API se crée dans Jellyfin : Tableau de bord → Clés API.
# API vérifiée sur les sources de Jellyfin 10.11 (version épinglée).
#######################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
JELLYFIN_URL="http://localhost:8096"

[ $# -ge 3 ] || { echo "Usage: $0 <username> <password> <jellyfin_api_key>"; exit 1; }
USERNAME=$1; PASSWORD=$2; API_KEY=$3

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"
command -v python3 >/dev/null || error "python3 requis"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_autoconfig.sh"   # json_escape
curl -fs -o /dev/null "$JELLYFIN_URL/health" || error "Jellyfin n'est pas accessible sur $JELLYFIN_URL"

USER_ID=$(id -u "$USERNAME")
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
MEDIA_DIR="/media/users/$USERNAME"          # même dossier, vu depuis le conteneur

jf() { curl -s -H "X-Emby-Token: $API_KEY" "$@"; }
pyjson() { python3 -c "import json,sys; d=json.load(sys.stdin); $1"; }

# Vérifier la clé API
code=$(jf -o /dev/null -w '%{http_code}' "$JELLYFIN_URL/Users")
[ "$code" = 200 ] || error "Clé API refusée par Jellyfin (HTTP $code)"

#######################
# 1. Compte
#######################
log "Création du compte Jellyfin $USERNAME..."
JID=$(jf "$JELLYFIN_URL/Users" | pyjson "print(next((u['Id'] for u in d if u['Name']=='$USERNAME'),''))")
if [ -z "$JID" ]; then
    JID=$(jf -X POST "$JELLYFIN_URL/Users/New" -H "Content-Type: application/json" \
          -d "{\"Name\":\"$USERNAME\",\"Password\":\"$(json_escape "$PASSWORD")\"}" \
          | pyjson "print(d.get('Id',''))" 2>/dev/null) || true
    [ -n "$JID" ] || error "Création du compte Jellyfin impossible"
    log "✓ Compte créé"
else
    info "Le compte existe déjà (réutilisé)"
fi

#######################
# 2. Bibliothèques (paramètres name/collectionType/paths dans l'URL)
#######################
mkdir -p "$USER_DIR"/{tv,movies,books,music}
chown "$USER_ID:$USER_ID" "$USER_DIR"/{tv,movies,books,music}
EXISTING=$(jf "$JELLYFIN_URL/Library/VirtualFolders" | pyjson "print('\n'.join(f['Name'] for f in d))")

LIB_NAMES=()
while IFS='|' read -r label dir type; do
    name="$label ($USERNAME)"
    LIB_NAMES+=("$name")
    if grep -qxF "$name" <<< "$EXISTING"; then
        info "Bibliothèque déjà présente : $name"
        continue
    fi
    q=$(python3 -c "import urllib.parse,sys;print(urllib.parse.urlencode({'name':sys.argv[1],'collectionType':sys.argv[2],'paths':sys.argv[3],'refreshLibrary':'false'}))" \
        "$name" "$type" "$MEDIA_DIR/$dir")
    code=$(jf -o /dev/null -w '%{http_code}' -X POST "$JELLYFIN_URL/Library/VirtualFolders?$q" \
           -H "Content-Type: application/json" -d '{"LibraryOptions":{"EnableRealtimeMonitor":true}}')
    [[ "$code" == 2* ]] && log "✓ Bibliothèque : $name → $MEDIA_DIR/$dir" || warn "Bibliothèque $name non créée (HTTP $code)"
done << 'LIBS'
Séries TV|tv|tvshows
Films|movies|movies
Livres|books|books
Musique|music|music
LIBS

#######################
# 3. Accès limité à SES bibliothèques (politique complète : les champs
#    obligatoires comme PasswordResetProviderId sont conservés)
#######################
FOLDER_IDS=$(jf "$JELLYFIN_URL/Library/VirtualFolders" | python3 -c "
import json,sys
names=set(sys.argv[1:]); d=json.load(sys.stdin)
print(json.dumps([f['ItemId'] for f in d if f['Name'] in names]))" "${LIB_NAMES[@]}")
POLICY=$(jf "$JELLYFIN_URL/Users/$JID" | python3 -c "
import json,sys
p=json.load(sys.stdin)['Policy']
p.update({'IsAdministrator':False,'EnableAllFolders':False,'EnabledFolders':json.loads(sys.argv[1]),
          'EnableContentDeletion':False,'EnableRemoteControlOfOtherUsers':False,'EnablePublicSharing':False})
print(json.dumps(p))" "$FOLDER_IDS")
code=$(jf -o /dev/null -w '%{http_code}' -X POST "$JELLYFIN_URL/Users/$JID/Policy" -H "Content-Type: application/json" -d "$POLICY")
[[ "$code" == 2* ]] && log "✓ Accès limité à ses bibliothèques" || warn "Politique non appliquée (HTTP $code)"

jf -o /dev/null -X POST "$JELLYFIN_URL/Library/Refresh" || true
log "✓ Scan des bibliothèques lancé"

echo ""
info "Jellyfin : $USERNAME (mêmes identifiants que la seedbox)"
info "Bibliothèques : $MEDIA_DIR/{tv,movies,books,music}"
