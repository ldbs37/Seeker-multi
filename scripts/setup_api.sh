#!/bin/bash

#######################
# setup_api.sh — Active l'API libre-service des utilisateurs (mode Traefik)
#
# Chaque utilisateur peut alors ajouter/retirer ses services optionnels depuis
# https://<user>.<domaine>/seedbox-api/ (lien sur son tableau de bord Homarr).
#
# Architecture :
#   - conteneur "seedbox-api" sans privilège (pas de socket Docker, rootfs en
#     lecture seule, utilisateur nobody) derrière Traefik + Authelia : il ne
#     fait que déposer des demandes dans /opt/seedbox/api/spool ;
#   - ouvrier côté hôte (systemd : seedbox-api-worker.path/.service) qui
#     revalide chaque demande et lance add_user_service.sh / remove_service.sh.
#
# Usage: ./setup_api.sh             # active (ou met à jour) l'API
#        ./setup_api.sh --refresh   # met à jour le code si l'API est active
#        ./setup_api.sh --disable   # désactive et retire l'API
#######################

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
API_DIR="$INSTALL_DIR/api"
SPOOL="$API_DIR/spool"
API_UID=65534
API_IMAGE="python:3.13.15-alpine"
UNIT_DIR="/etc/systemd/system"

for lib in lib_ports lib_traefik lib_services; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || error "$lib.sh introuvable"
done

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
[ -f "$DOCKER_COMPOSE_FILE" ] && [ -f "$ENV_FILE" ] || error "Installation introuvable dans $INSTALL_DIR"
MODE="${1:-enable}"

env_set() {   # $1=clé $2=valeur (remplace ou ajoute)
    if grep -q "^$1=" "$ENV_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$ENV_FILE"
    else
        echo "$1=$2" >> "$ENV_FILE"
    fi
}

# Retire le bloc seedbox-api du compose (atomique + validation)
remove_block() {
    grep -q '^  seedbox-api:' "$DOCKER_COMPOSE_FILE" || return 0
    local tmp="${DOCKER_COMPOSE_FILE%.yml}.new.yml"
    awk '/^  [^ #]/ { skip = ($1 == "seedbox-api:") } /^[^ ]/ { skip = 0 } !skip { print }' \
        "$DOCKER_COMPOSE_FILE" > "$tmp"
    compose_validate "$tmp" || { rm -f "$tmp"; error "Compose invalide après retrait de seedbox-api"; }
    mv "$tmp" "$DOCKER_COMPOSE_FILE"
}

# Bloc docker-compose du conteneur de l'API
api_block() {
    local re dom
    # Regex Go : "\." doublé pour la chaîne YAML entre guillemets, "$$" pour
    # docker-compose (sed plutôt que ${//} : comportement stable selon bash)
    dom=$(printf '%s' "$DOMAIN" | sed 's/\./\\\\./g')
    re='^[a-z][a-z0-9]{0,31}\\.'"${dom}"'$$'
    cat << EOF

  seedbox-api:
    image: ${API_IMAGE}
    container_name: seedbox-api
    user: "${API_UID}:${API_UID}"
    command: ["python3", "-u", "/app/seedbox_api.py"]
    read_only: true
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    environment:
      - SEEDBOX_API_KEY=\${SEEDBOX_API_KEY}
      - DOMAIN=\${DOMAIN}
      - PYTHONDONTWRITEBYTECODE=1
    volumes:
      - ./api/app:/app:ro
      - ./api/spool:/spool
    networks:
      - traefik_proxy
    labels:
      - "traefik.enable=true"
      - "traefik.docker.network=traefik_proxy"
      - "traefik.http.routers.seedbox-api.rule=HostRegexp(\`${re}\`) && PathPrefix(\`/seedbox-api\`)"
      - "traefik.http.routers.seedbox-api.entrypoints=websecure"
      - "traefik.http.routers.seedbox-api.tls=true"
      - "traefik.http.routers.seedbox-api.middlewares=authelia@docker,seedbox-api-key"
      - "traefik.http.middlewares.seedbox-api-key.headers.customrequestheaders.X-Seedbox-Api-Key=\${SEEDBOX_API_KEY}"
      - "traefik.http.services.seedbox-api.loadbalancer.server.port=8000"
    restart: unless-stopped
EOF
}

# Tuile « Mes services » des tableaux de bord Homarr
refresh_homarr() {
    "$SCRIPT_DIR/homarr_provision.sh" --all >/dev/null 2>&1 || warn "Tableaux de bord Homarr non mis à jour (homarr_provision.sh --all)"
}

#######################
# Désactivation
#######################
if [ "$MODE" = --disable ]; then
    log "Désactivation de l'API libre-service..."
    systemctl disable --now seedbox-api-worker.path seedbox-api-worker.timer >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/seedbox-api-worker.path" "$UNIT_DIR/seedbox-api-worker.timer" \
          "$UNIT_DIR/seedbox-api-worker.service"
    systemctl daemon-reload 2>/dev/null || true
    remove_block
    docker rm -f seedbox-api >/dev/null 2>&1 || true
    env_set SEEDBOX_API false
    refresh_homarr
    log "${GREEN}✓${NC} API désactivée"
    exit 0
fi

if [ "$MODE" = --refresh ] && ! grep -q '^SEEDBOX_API=true' "$ENV_FILE"; then
    exit 0   # API non activée : rien à faire
fi
[ "$MODE" = enable ] || [ "$MODE" = --refresh ] || error "Usage: $0 [--refresh|--disable]"

#######################
# Activation / mise à jour
#######################
traefik_require "$ENV_FILE"
grep -q '^  traefik:' "$DOCKER_COMPOSE_FILE" || error "Service traefik absent du docker-compose.yml"
[[ "$DOMAIN" =~ ^[a-z0-9.-]+$ ]] || error "Domaine inattendu : $DOMAIN"
command -v systemctl >/dev/null || error "systemd requis"

log "Installation de l'API libre-service..."

# Clé partagée Traefik -> API (les autres conteneurs ne la connaissent pas)
if ! grep -qE '^SEEDBOX_API_KEY=[a-f0-9]{64}$' "$ENV_FILE"; then
    env_set SEEDBOX_API_KEY "$(openssl rand -hex 32)"
fi
env_set SEEDBOX_API true
chmod 600 "$ENV_FILE"

# Code et file d'attente
mkdir -p "$API_DIR/app" "$SPOOL"/{requests,running,results,tmp}
install -m 644 "$SCRIPT_DIR/seedbox_api.py" "$API_DIR/app/seedbox_api.py"
chown root:root "$API_DIR" "$API_DIR/app"; chmod 755 "$API_DIR" "$API_DIR/app"
chown -R "$API_UID:$API_UID" "$SPOOL"; chmod 750 "$SPOOL" "$SPOOL"/*

# Ouvrier côté hôte
cat > "$UNIT_DIR/seedbox-api-worker.service" << EOF
[Unit]
Description=Seedbox - traitement des demandes de l'API libre-service
After=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/seedbox_api_worker.sh
TimeoutStartSec=30min
EOF
cat > "$UNIT_DIR/seedbox-api-worker.path" << EOF
[Unit]
Description=Seedbox - surveillance des demandes de l'API libre-service

[Path]
DirectoryNotEmpty=$SPOOL/requests
Unit=seedbox-api-worker.service

[Install]
WantedBy=multi-user.target
EOF
# État des conteneurs (voyants de la page) rafraîchi chaque minute
cat > "$UNIT_DIR/seedbox-api-worker.timer" << EOF
[Unit]
Description=Seedbox - état des services pour l'API libre-service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Unit=seedbox-api-worker.service

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now seedbox-api-worker.path seedbox-api-worker.timer >/dev/null

# Conteneur (bloc régénéré à chaque fois : suit un changement de domaine)
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"
remove_block
TMP="${DOCKER_COMPOSE_FILE%.yml}.new.yml"
cp "$DOCKER_COMPOSE_FILE" "$TMP"
api_block >> "$TMP"
if ! compose_validate "$TMP"; then
    rm -f "$TMP"; cp "${DOCKER_COMPOSE_FILE}.bak" "$DOCKER_COMPOSE_FILE"
    error "docker-compose.yml invalide — aucune modification appliquée"
fi
mv "$TMP" "$DOCKER_COMPOSE_FILE"

cd "$INSTALL_DIR"
compose_cmd up -d --force-recreate seedbox-api || error "Démarrage de seedbox-api impossible (docker logs seedbox-api)"
"$SCRIPT_DIR/seedbox_api_worker.sh" --state || warn "État initial non généré"
refresh_homarr

log "${GREEN}✓${NC} API libre-service active"
info "Chaque utilisateur : https://<utilisateur>.${DOMAIN}/seedbox-api/ (lien sur Homarr)"
info "Services proposés : sonarr radarr prowlarr seerr calibre ; redémarrage de tous ses services"
info "Journal des actions : journalctl -t seedbox-api"
