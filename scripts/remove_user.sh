#!/bin/bash

#######################
# Script de suppression d'utilisateur
# Usage: ./remove_user.sh <username> [--keep-data] [--yes]
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
AUTHELIA_DB="$INSTALL_DIR/authelia/users_database.yml"

for lib in lib_ports lib_traefik lib_services lib_quota; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

[ $# -ge 1 ] || error "Usage: $0 <username> [--keep-data] [--yes]"
USERNAME=$1
KEEP_DATA=false
ASSUME_YES=false
shift
for arg in "$@"; do
    case "$arg" in
        --keep-data) KEEP_DATA=true ;;
        --yes) ASSUME_YES=true ;;
        *) error "Argument inconnu : $arg" ;;
    esac
done

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
[[ "$USERNAME" =~ ^[a-z][a-z0-9]{0,31}$ ]] || error "Nom d'utilisateur invalide : $USERNAME"
id "$USERNAME" &>/dev/null || error "L'utilisateur $USERNAME n'existe pas"

# Authelia refuse de démarrer avec une base utilisateurs vide : on ne
# supprime pas le dernier compte (sinon plus personne ne peut se connecter).
if [ -f "$AUTHELIA_DB" ] && grep -q "^  ${USERNAME}:" "$AUTHELIA_DB"; then
    remaining=$(grep -cE '^  [a-z][a-z0-9]*:' "$AUTHELIA_DB")
    [ "$remaining" -gt 1 ] || error "$USERNAME est le dernier compte Authelia : créez d'abord un autre utilisateur"
    admins=$(awk '/^  [a-z][a-z0-9]*:/{u=$1} /^      - admins$/{print u}' "$AUTHELIA_DB" | wc -l)
    if [ "$admins" -le 1 ] && awk -v u="  ${USERNAME}:" '$0==u{f=1;next} /^  [^ ]/{f=0} f && /^      - admins$/{found=1} END{exit !found}' "$AUTHELIA_DB"; then
        warn "$USERNAME est le DERNIER administrateur : plus personne n'aura accès aux services d'administration."
    fi
fi

# Confirmation
warn "ATTENTION: Vous êtes sur le point de supprimer l'utilisateur $USERNAME"
if [ "$KEEP_DATA" = false ]; then
    warn "Toutes les données seront supprimées définitivement !"
else
    info "Les données seront conservées dans $INSTALL_DIR/data/users/$USERNAME"
fi
if [ "$ASSUME_YES" != true ]; then
    read -r -p "Êtes-vous sûr ? (tapez 'yes' pour confirmer): " confirm
    [ "$confirm" = "yes" ] || { log "Opération annulée"; exit 0; }
fi

USER_ID=$(id -u "$USERNAME")

# Homarr partagé : tableau de bord et applis de l'utilisateur
[ -x "$SCRIPT_DIR/homarr_provision.sh" ] && { "$SCRIPT_DIR/homarr_provision.sh" --remove "$USERNAME" >/dev/null 2>&1 || true; }

# 1) Arrêt et suppression des conteneurs de l'utilisateur
log "Arrêt des services..."
for s in $USER_SERVICES; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${s}-${USERNAME}"; then
        log "Arrêt de ${s}-${USERNAME}..."
        docker rm -f "${s}-${USERNAME}" >/dev/null 2>&1 || true
    fi
done

# 2) Retrait de ses services du docker-compose.yml (sinon ils seraient
#    recréés au prochain `up -d`). Correspondance EXACTE des noms de service.
log "Mise à jour de docker-compose.yml..."
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"
TMP="${DOCKER_COMPOSE_FILE%.yml}.new.yml"
awk -v user="$USERNAME" -v svcs="$USER_SERVICES" '
    BEGIN { n = split(svcs, a, " "); for (i = 1; i <= n; i++) want[a[i] "-" user ":"] = 1; skip = 0 }
    /^  [^ #]/ { skip = ($1 in want) }      # nouvelle clé de service
    /^[^ ]/    { skip = 0 }                 # clé de premier niveau
    !skip      { print }
' "$DOCKER_COMPOSE_FILE" > "$TMP"
if compose_validate "$TMP"; then
    mv "$TMP" "$DOCKER_COMPOSE_FILE"
else
    rm -f "$TMP"
    error "docker-compose.yml serait invalide — aucune modification (sauvegarde : ${DOCKER_COMPOSE_FILE}.bak)"
fi

# 3) Pare-feu : fermer le port torrent de l'utilisateur
TORRENT_PORT=$(user_port "$USER_ID" torrent)
if command -v ufw &>/dev/null; then
    ufw delete allow "$TORRENT_PORT/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$TORRENT_PORT/udp" >/dev/null 2>&1 || true
fi

# 4) Compte Authelia
log "Suppression du compte Authelia..."
if [ -f "$AUTHELIA_DB" ]; then
    awk -v u="  ${USERNAME}:" '
        $0 == u     { skip = 1; next }
        /^  [^ ]/   { skip = 0 }
        skip && (/^    / || /^$/) { next }
        { skip = 0; print }
    ' "$AUTHELIA_DB" > "$AUTHELIA_DB.tmp" && mv "$AUTHELIA_DB.tmp" "$AUTHELIA_DB"
    chmod 600 "$AUTHELIA_DB"
    docker restart authelia >/dev/null 2>&1 || warn "Impossible de redémarrer Authelia"
fi

# 5) Quota projet (tant que l'utilisateur système existe encore)
MNT=$(quota_mount "$INSTALL_DIR/data"); MNT=${MNT:-/}
case "$(quota_fstype "$INSTALL_DIR/data")" in
    xfs)  command -v xfs_quota >/dev/null 2>&1 && xfs_quota -x -c "limit -p bhard=0 $USER_ID" "$MNT" >/dev/null 2>&1 || true ;;
    ext*) command -v setquota  >/dev/null 2>&1 && setquota -P "$USER_ID" 0 0 0 0 "$MNT" >/dev/null 2>&1 || true ;;
esac
[ -f /etc/projid ]   && sed -i "/^${USERNAME}:/d" /etc/projid
[ -f /etc/projects ] && sed -i "/^${USER_ID}:/d"   /etc/projects

# 6) Données
if [ "$KEEP_DATA" = false ]; then
    log "Suppression des données utilisateur..."
    rm -rf "${INSTALL_DIR:?}/data/users/${USERNAME:?}"
    for s in $USER_SERVICES; do
        rm -rf "${INSTALL_DIR:?}/${s}/${USERNAME:?}"
    done
else
    info "Données conservées dans $INSTALL_DIR/data/users/$USERNAME"
fi

# 7) Compte système (et son groupe)
log "Suppression de l'utilisateur système..."
USER_HOME=$(getent passwd "$USERNAME" | cut -d: -f6)
userdel "$USERNAME" 2>/dev/null || warn "Impossible de supprimer l'utilisateur système"
# Home éventuel (comptes créés par une ancienne version, avec shell)
if [ "$KEEP_DATA" = false ] && [[ "$USER_HOME" == /home/"$USERNAME" ]] && [ -d "$USER_HOME" ]; then
    rm -rf "${USER_HOME:?}"
fi
getent group "$USERNAME" >/dev/null && { groupdel "$USERNAME" 2>/dev/null || true; }

log "${GREEN}✓${NC} Utilisateur $USERNAME supprimé avec succès !"
if [ "$KEEP_DATA" = true ]; then
    info "Les données ont été conservées ; add_user.sh $USERNAME … les réattribuera au nouveau compte."
fi

# API libre-service : état des services à jour (sauf si appelé par son ouvrier)
[ -n "${SEEDBOX_API_WORKER:-}" ] || "$SCRIPT_DIR/seedbox_api_worker.sh" --state >/dev/null 2>&1 || true
