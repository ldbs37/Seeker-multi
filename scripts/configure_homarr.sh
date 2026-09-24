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

# Services de l'utilisateur présents dans le compose : "clé|nom|url|icône"
declare -A SVC_LABELS=(
    [qbittorrent]="qBittorrent" [filebrowser]="Fichiers" [sonarr]="Sonarr"
    [radarr]="Radarr" [readarr]="Readarr" [bazarr]="Bazarr" [prowlarr]="Prowlarr"
    [seerr]="Seerr (demandes)" [calibre]="Calibre-Web"
)
declare -A SVC_ICONS=(
    [qbittorrent]="qbittorrent" [filebrowser]="filebrowser" [sonarr]="sonarr"
    [radarr]="radarr" [readarr]="readarr" [bazarr]="bazarr" [prowlarr]="prowlarr"
    [seerr]="jellyseerr" [calibre]="calibre-web"
)
ENTRIES=""
for s in qbittorrent filebrowser sonarr radarr readarr bazarr prowlarr seerr calibre; do
    if grep -q "^  ${s}-${USERNAME}:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; then
        ENTRIES+="${s}|${SVC_LABELS[$s]}|$(service_url "$s")|${SVC_ICONS[$s]}"$'\n'
    fi
done
# API libre-service (setup_api.sh) : tuile de gestion des services
if [ "$USE_TRAEFIK" = true ] && grep -q '^SEEDBOX_API=true' "$INSTALL_DIR/.env" 2>/dev/null; then
    ENTRIES+="seedbox-api|Ajouter / retirer des services|/seedbox-api/|docker"$'\n'
fi

# Configuration au format Homarr 0.16 (schemaVersion 2, calqué sur la
# configuration par défaut officielle) : une tuile cliquable par service + une
# note de bienvenue. Générée en Python pour un JSON toujours valide.
HM_USER="$USERNAME" HM_ENTRIES="$ENTRIES" python3 - > "$HOMARR_CONFIG_DIR/default.json.tmp" << 'PY'
import json, os, sys, uuid

user = os.environ["HM_USER"]
entries = [l.split("|") for l in os.environ["HM_ENTRIES"].splitlines() if l.strip()]
ICON = "https://cdn.jsdelivr.net/gh/walkxcode/dashboard-icons/png/{}.png"

def shape(i):
    # grilles Homarr : petit = 3 colonnes, moyen = 6, grand = 10 ; sous la note
    def loc(cols, w):
        per_row = max(1, cols // w)
        return {"location": {"x": (i % per_row) * w, "y": 2 + i // per_row},
                "size": {"width": w, "height": 1}}
    return {"sm": loc(3, 1), "md": loc(6, 1), "lg": loc(10, 2)}

apps = []
for i, (key, name, url, icon) in enumerate(entries):
    apps.append({
        "id": str(uuid.uuid4()),
        "name": name,
        "url": url,
        "behaviour": {"onClickUrl": url, "externalUrl": url,
                      "isOpeningNewTab": not url.startswith("/")},
        "network": {"enabledStatusChecker": False, "statusCodes": ["200"]},
        "appearance": {"iconUrl": ICON.format(icon), "appNameStatus": "normal",
                       "positionAppName": "column", "lineClampAppName": 1},
        "integration": {"type": None, "properties": []},
        "area": {"type": "wrapper", "properties": {"id": "default"}},
        "shape": shape(i),
    })

welcome = (f"<h2>Bienvenue {user} !</h2>"
           "<p>Vos services sont ci-dessous. qBittorrent et Fichiers utilisent "
           "vos identifiants de la seedbox.</p>"
           "<p>Sonarr/Radarr : dossiers racines <code>/data/tv</code> et "
           f"<code>/data/movies</code>, client <code>qbittorrent-{user}</code> "
           "port <code>8080</code> (imports par liens physiques : pas de doublon "
           "d'espace disque).</p>")
full = lambda cols: {"location": {"x": 0, "y": 0}, "size": {"width": cols, "height": 2}}
widgets = [{
    "id": str(uuid.uuid4()),
    "type": "notebook",
    "properties": {"showToolbar": False, "content": welcome},
    "area": {"type": "wrapper", "properties": {"id": "default"}},
    "shape": {"sm": full(3), "md": full(6), "lg": full(10)},
}]

config = {
    "schemaVersion": 2,
    "configProperties": {"name": "default"},
    "categories": [],
    "wrappers": [{"id": "default", "position": 0}],
    "apps": apps,
    "widgets": widgets,
    "settings": {
        "common": {"searchEngine": {"type": "google", "properties": {}}},
        "customization": {
            "layout": {"enabledLeftSidebar": False, "enabledRightSidebar": False,
                       "enabledDocker": False, "enabledPing": False,
                       "enabledSearchbar": True},
            "pageTitle": f"Seedbox · {user}",
            "logoImageUrl": "/imgs/logo/logo.png",
            "faviconUrl": "/imgs/favicon/favicon-squared.png",
            "backgroundImageUrl": "", "customCss": "",
            "colors": {"primary": "red", "secondary": "yellow", "shade": 7},
            "appOpacity": 100,
            "gridstack": {"columnCountSmall": 3, "columnCountMedium": 6,
                          "columnCountLarge": 10},
        },
        # Accès déjà filtré par Authelia (mode Traefik) : pas de 2e connexion
        "access": {"allowGuests": True},
    },
}
json.dump(config, sys.stdout, ensure_ascii=False, indent=2)
PY
mv "$HOMARR_CONFIG_DIR/default.json.tmp" "$HOMARR_CONFIG_DIR/default.json"

chown -R "$USER_ID:$USER_ID" "$HOMARR_CONFIG_DIR"
log "✓ Tableau de bord Homarr généré"

# Recharger Homarr s'il tourne déjà
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "homarr-${USERNAME}"; then
    docker restart "homarr-${USERNAME}" >/dev/null 2>&1 && log "✓ Homarr redémarré"
fi

info "📍 Accès: $(service_url homarr)"
