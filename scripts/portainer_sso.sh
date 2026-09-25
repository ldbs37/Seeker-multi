#!/bin/bash
#######################
# portainer_sso.sh — Connexion à Portainer via Authelia, pour une
# installation existante (une nouvelle installation le fait seule) :
# client OIDC « portainer » dans Authelia (groupe admins seulement), bouton
# « Login with OAuth » dans Portainer, session de 7 jours.
# Demande une fois le compte administrateur Portainer et son mot de passe
# (la seedbox ne le conserve pas).
# Usage: sudo ./portainer_sso.sh
#######################

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib_autoconfig.sh" || fail "lib_autoconfig.sh introuvable dans $SCRIPT_DIR"

[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root"
grep -q '^  portainer:' "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || fail "Portainer n'est pas installé"
DOMAIN=$(grep '^DOMAIN=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2)
[ -n "$DOMAIN" ] || fail "DOMAIN absent de $INSTALL_DIR/.env"

ADMIN=$(autoconfig_first_admin "$INSTALL_DIR")
read -r -p "Compte administrateur Portainer [${ADMIN:-admin}]: " PT_USER
PT_USER=${PT_USER:-${ADMIN:-admin}}
read -r -s -p "Mot de passe Portainer de $PT_USER : " PT_PASS; echo

portainer_sso_setup "$PT_USER" "$PT_PASS" "${ADMIN:-$PT_USER}" || exit 1
info "https://portainer.$DOMAIN → « Login with OAuth » (connecté à Authelia : rien à saisir)"
