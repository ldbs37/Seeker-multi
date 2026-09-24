#!/bin/bash

#######################
# Script de modification de quota
# Usage: ./update_quota.sh <username> <quota_gb>
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

# Vérification des arguments
if [ $# -ne 2 ]; then
    error "Usage: $0 <username> <quota_gb>"
fi

USERNAME=$1
QUOTA_GB=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier si l'utilisateur existe
if ! id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME n'existe pas"
fi

# Vérifier que le quota est un nombre
if ! [[ "$QUOTA_GB" =~ ^[0-9]+$ ]]; then
    error "Le quota doit être un nombre entier (en GB)"
fi

# Charger la lib de quotas (quota PROJET par dossier)
QUOTA_LIB="$(dirname "$0")/lib_quota.sh"
[ -f "$QUOTA_LIB" ] || error "lib_quota.sh introuvable à côté de ce script"
# shellcheck source=/dev/null
source "$QUOTA_LIB"

# Dossier et id de projet de l'utilisateur
INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
PROJID=$(id -u "$USERNAME")

[ -d "$USER_DIR" ] || error "Dossier utilisateur introuvable : $USER_DIR"

# Les quotas doivent être actifs sur le système de fichiers
if ! quota_project_active "$USER_DIR"; then
    warn "Les quotas projet ne sont pas actifs sur le système de fichiers."
    info "Activez-les d'abord : sudo $(dirname "$0")/enable_quotas.sh"
    error "Quota non appliqué"
fi

# Appliquer le nouveau quota projet
log "Application du quota projet ${QUOTA_GB}GB sur $USER_DIR (projet $PROJID)..."
quota_register_project "$USERNAME" "$PROJID" "$USER_DIR"
if quota_apply_project "$USER_DIR" "$PROJID" "$QUOTA_GB"; then
    log "${GREEN}✓${NC} Quota modifié avec succès (${QUOTA_GB}GB) !"
else
    error "Impossible de configurer le quota projet"
fi
