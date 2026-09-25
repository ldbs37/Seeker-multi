#!/bin/bash
#######################
# arr_setup.sh — Applis d'un utilisateur configurées automatiquement :
#   - lib_arr.sh : connexion unique Sonarr/Radarr/Prowlarr (Readarr existant),
#     dossiers racine, qBittorrent comme client de téléchargement,
#     Prowlarr → *arr (+ son FlareSolverr) ;
#   - lib_calibre.sh : Calibre-web (connexion unique, bibliothèque /books) ;
#   - lib_seerr.sh : Seerr (Jellyfin au nom de l'utilisateur, ses
#     bibliothèques, Sonarr/Radarr).
# Idempotent : relançable sans risque (ne remplace rien de ce qui existe).
#
# Usage: arr_setup.sh <user>   # un utilisateur
#        arr_setup.sh --all    # tous les utilisateurs
#        arr_setup.sh --seerr-sessions   # prolonge les sessions Seerr (timer quotidien)
#######################

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

for lib in lib_ports lib_traefik lib_services lib_qbittorrent lib_homarr lib_arr lib_calibre lib_seerr; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || fail "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

[ $# -eq 1 ] || { echo "Usage: $0 <user> | --all | --seerr-sessions"; exit 1; }
[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root"
[ -f "$DOCKER_COMPOSE_FILE" ] || fail "docker-compose.yml introuvable ($DOCKER_COMPOSE_FILE)"
traefik_require "$ENV_FILE"

# Prolongation des sessions Seerr (connexion automatique), sans redémarrage
if [ "$1" = --seerr-sessions ]; then
    for u in $(sed -n 's/^  seerr-\([a-z_][a-z0-9_-]*\):$/\1/p' "$DOCKER_COMPOSE_FILE"); do
        seerr_session_refresh "$u" || warn "Session Seerr de $u non prolongée"
    done
    exit 0
fi

if [ "$1" = --all ]; then
    USERS=$(sed -n 's/^  \(sonarr\|radarr\|readarr\|prowlarr\|calibre\|seerr\)-\([a-z_][a-z0-9_-]*\):$/\2/p' "$DOCKER_COMPOSE_FILE" | sort -u)
else
    USERS="$1"
fi

RC=0
for u in $USERS; do
    if grep -qE "^  (sonarr|radarr|readarr|prowlarr)-$u:" "$DOCKER_COMPOSE_FILE"; then
        if arr_chain "$u"; then
            log "✓ $u : Sonarr/Radarr/Prowlarr reliés (connexion unique, qBittorrent, indexeurs)"
        else
            warn "$u : configuration *arr incomplète (relancez : $0 $u)"; RC=1
        fi
    fi
    if grep -q "^  calibre-$u:" "$DOCKER_COMPOSE_FILE"; then
        if calibre_configure "$u"; then
            log "✓ $u : Calibre-web (connexion unique, bibliothèque /books)"
        else
            warn "$u : configuration de Calibre-web incomplète (relancez : $0 $u)"; RC=1
        fi
    fi
    if grep -q "^  seerr-$u:" "$DOCKER_COMPOSE_FILE"; then
        if seerr_configure "$u"; then
            seerr_sessions_timer_ensure
            log "✓ $u : Seerr (Jellyfin, ses bibliothèques, Sonarr/Radarr, connexion automatique)"
        else
            warn "$u : configuration de Seerr incomplète (relancez : $0 $u)"; RC=1
        fi
    fi
done
exit $RC
