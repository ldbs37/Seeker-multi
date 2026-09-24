#!/bin/bash

#######################
# Migration d'une installation en mode "port direct" vers Traefik + SSO
# Usage: ./generate_traefik_labels.sh [--yes]
#
# Prérequis : setup_traefik.sh <domaine> <email> déjà exécuté (réseau
# traefik_proxy, config statique et service "traefik" dans le compose).
#
# Reconstruit docker-compose.yml en mode Traefik plutôt que de modifier le YAML
# à la main : services système régénérés (labels, SSO, ports locaux), service
# traefik conservé tel quel, services utilisateurs régénérés (routage par
# chemin, sans ports publiés hormis le port torrent). Préconfigure les applis
# (URL de base des *arr/Bazarr, reverse-proxy qBittorrent), sauvegarde la
# configuration avant, valide avant d'appliquer, puis vérifie (healthcheck).
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

for lib in lib_ports lib_traefik lib_qbittorrent lib_services lib_compose_base lib_homarr; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
[ -f "$DOCKER_COMPOSE_FILE" ] || error "docker-compose.yml introuvable ($DOCKER_COMPOSE_FILE)"
[ -f "$ENV_FILE" ] || error ".env introuvable ($ENV_FILE)"
grep -q '^  traefik:' "$DOCKER_COMPOSE_FILE" \
    || error "Service Traefik absent : exécutez d'abord setup_traefik.sh <domaine> <email>"

envget() { grep "^$1=" "$ENV_FILE" | cut -d'=' -f2; }
DOMAIN=$(envget DOMAIN); TZ=$(envget TZ); ADMIN_UID=$(envget ADMIN_UID); ADMIN_GID=$(envget ADMIN_GID)
TZ=${TZ:-Europe/Paris}; ADMIN_UID=${ADMIN_UID:-1000}; ADMIN_GID=${ADMIN_GID:-1000}
[ -n "$DOMAIN" ] || error "DOMAIN absent du .env"
# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
USE_TRAEFIK=true

log "Migration vers Traefik pour le domaine $DOMAIN..."

#######################
# Inventaire du compose actuel
#######################
mapfile -t NAMES < <(compose_service_names "$DOCKER_COMPOSE_FILE")
detect_system_services "$DOCKER_COMPOSE_FILE"
USER_ENTRIES=(); CUSTOM=(); DROPPED=()
for n in "${NAMES[@]}"; do
    [[ " $SYSTEM_SERVICES traefik " == *" $n "* ]] && continue
    svc=${n%-*}; usr=${n##*-}
    if [[ "$n" == *-* ]] && [[ " $USER_SERVICES " == *" $svc "* ]] && id "$usr" &>/dev/null; then
        # Mode Traefik : Homarr partagé ; les Homarr individuels sont retirés
        # (leurs fichiers restent dans data/users/<user>/config/homarr)
        [ "$svc" = homarr ] && { DROPPED+=("$n"); continue; }
        USER_ENTRIES+=("$svc:$usr")
    else
        CUSTOM+=("$n")
    fi
done
info "Services utilisateurs : ${#USER_ENTRIES[@]} ; blocs personnalisés conservés : ${CUSTOM[*]:-aucun}"

if [ "${1:-}" != "--yes" ]; then
    warn "Le docker-compose.yml va être reconstruit (sauvegarde automatique)."
    read -r -p "Continuer ? (o/N): " c
    [[ "$c" =~ ^[oO]$ ]] || { info "Annulé"; exit 0; }
fi

#######################
# Sauvegardes
#######################
[ -x "$SCRIPT_DIR/backup.sh" ] && INSTALL_DIR="$INSTALL_DIR" "$SCRIPT_DIR/backup.sh" --auto --label pre-traefik >/dev/null 2>&1 \
    && log "✓ Snapshot de configuration créé (restore.sh pour revenir en arrière)"
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.pre-migration"
cp "$ENV_FILE" "${ENV_FILE}.pre-migration"
AUTHELIA_CFG="$INSTALL_DIR/authelia/configuration.yml"
[ -f "$AUTHELIA_CFG" ] && cp -p "$AUTHELIA_CFG" "${AUTHELIA_CFG}.pre-migration"
AUTHELIA_DB="$INSTALL_DIR/authelia/users_database.yml"
[ -f "$AUTHELIA_DB" ] && cp -p "$AUTHELIA_DB" "${AUTHELIA_DB}.pre-migration"

#######################
# Construction du nouveau compose
#######################
TMP="${DOCKER_COMPOSE_FILE%.yml}.new.yml"
generate_docker_compose "$TMP"           # services système + .env (USE_TRAEFIK=true)
# Homarr partagé : secrets (.env, avant la validation) et client OIDC Authelia
AUTHELIA_CHANGED=false
if homarr_prepare; then AUTHELIA_CHANGED=true; fi
# Groupes personnels u-<user> (droits sur les tableaux de bord Homarr)
authelia_ensure_user_groups "$INSTALL_DIR/authelia/users_database.yml" && AUTHELIA_CHANGED=true
compose_extract_blocks "${DOCKER_COMPOSE_FILE}.pre-migration" traefik >> "$TMP"
# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
FB_PASSWORD_HASH=""
for e in "${USER_ENTRIES[@]}"; do
    svc=${e%%:*}; USERNAME=${e#*:}
    USER_ID=$(id -u "$USERNAME"); USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
    service_block "$svc" >> "$TMP"
done
[ ${#CUSTOM[@]} -gt 0 ] && compose_extract_blocks "${DOCKER_COMPOSE_FILE}.pre-migration" "${CUSTOM[@]}" >> "$TMP"

if ! compose_validate "$TMP"; then
    rm -f "$TMP"
    cp "${ENV_FILE}.pre-migration" "$ENV_FILE"
    [ -f "${AUTHELIA_CFG}.pre-migration" ] && cp -p "${AUTHELIA_CFG}.pre-migration" "$AUTHELIA_CFG"
    [ -f "${AUTHELIA_DB}.pre-migration" ] && cp -p "${AUTHELIA_DB}.pre-migration" "$AUTHELIA_DB"
    error "Le compose généré est invalide — aucune modification appliquée"
fi

#######################
# Application
#######################
log "Arrêt des services utilisateurs pour préconfiguration..."
for e in "${USER_ENTRIES[@]}"; do
    docker stop "${e%%:*}-${e#*:}" >/dev/null 2>&1 || true
done

PROXY_NET=$(docker network inspect traefik_proxy -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
declare -A DONE_USERS=()
for e in "${USER_ENTRIES[@]}"; do
    svc=${e%%:*}; USERNAME=${e#*:}; USER_ID=$(id -u "$USERNAME")
    # shellcheck disable=SC2034  # lue par les bibliothèques sourcées
    USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
    cfg=$(service_config_dir "$svc")
    case "$svc" in
        qbittorrent)
            conf="$cfg/qBittorrent/qBittorrent.conf"
            if [ -f "$conf" ] && [ -n "$PROXY_NET" ]; then
                ini_set "$conf" Preferences 'WebUI\ReverseProxySupportEnabled' 'true'
                ini_set "$conf" Preferences 'WebUI\TrustedReverseProxiesList' "$PROXY_NET"
                chown "$USER_ID:$USER_ID" "$conf"
            fi ;;
        *) traefik_prepare_app "$svc" "$cfg" "$USER_ID" ;;
    esac
    DONE_USERS[$USERNAME]=1
done

mv "$TMP" "$DOCKER_COMPOSE_FILE"
log "✓ docker-compose.yml reconstruit en mode Traefik"

log "Redémarrage des services..."
cd "$INSTALL_DIR"
if ! compose_cmd up -d --remove-orphans; then
    warn "Échec du démarrage — restauration de la configuration précédente"
    cp "${DOCKER_COMPOSE_FILE}.pre-migration" "$DOCKER_COMPOSE_FILE"
    cp "${ENV_FILE}.pre-migration" "$ENV_FILE"
    [ -f "${AUTHELIA_CFG}.pre-migration" ] && cp -p "${AUTHELIA_CFG}.pre-migration" "$AUTHELIA_CFG"
    [ -f "${AUTHELIA_DB}.pre-migration" ] && cp -p "${AUTHELIA_DB}.pre-migration" "$AUTHELIA_DB"
    compose_cmd up -d --remove-orphans || true
    error "Migration annulée (configuration restaurée)"
fi

for u in "${!DONE_USERS[@]}"; do
    "$SCRIPT_DIR/configure_homarr.sh" "$u" >/dev/null 2>&1 || warn "Homarr de $u non régénéré"
done

# Accueil https://<domaine> (Homarr partagé) : règle d'accès + redirection
# après connexion (configurations Authelia antérieures), client OIDC
authelia_ensure_home "$INSTALL_DIR/authelia/configuration.yml" "$DOMAIN" && AUTHELIA_CHANGED=true
if [ "$AUTHELIA_CHANGED" = true ]; then
    docker restart authelia >/dev/null 2>&1 \
        && log "✓ Authelia : connexion unique Homarr + redirection vers le tableau de bord" \
        || warn "Redémarrez Authelia : docker restart authelia"
fi
[ ${#DROPPED[@]} -gt 0 ] && info "Homarr individuels retirés (remplacés par https://$DOMAIN) : ${DROPPED[*]}"

log "${GREEN}✓${NC} Migration terminée"
info "Portail SSO : https://auth.$DOMAIN"
for u in "${!DONE_USERS[@]}"; do info "   $u : https://$u.$DOMAIN"; done
info "Les certificats Let's Encrypt sont obtenus au premier accès (DNS *.${DOMAIN} requis)."

# Homarr partagé : tableaux de bord des utilisateurs (si la clé d'API est définie)
[ -x "$SCRIPT_DIR/homarr_provision.sh" ] && { "$SCRIPT_DIR/homarr_provision.sh" --all || true; }

[ -x "$SCRIPT_DIR/healthcheck.sh" ] && { echo ""; "$SCRIPT_DIR/healthcheck.sh" --quiet || true; }
