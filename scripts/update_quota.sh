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

# Vérifier si les quotas sont activés
if ! command -v setquota &>/dev/null; then
    error "Les quotas ne sont pas installés sur ce système"
fi

# Afficher le quota actuel
log "Quota actuel pour $USERNAME:"
quota -v -u "$USERNAME" 2>/dev/null || info "Aucun quota défini"

# Configurer le nouveau quota
log "Configuration du nouveau quota: ${QUOTA_GB}GB..."
QUOTA_KB=$((QUOTA_GB * 1024 * 1024))

if setquota -u "$USERNAME" 0 "$QUOTA_KB" 0 0 / 2>/dev/null; then
    log "${GREEN}✓${NC} Quota modifié avec succès !"
    echo ""
    info "Nouveau quota pour $USERNAME:"
    quota -v -u "$USERNAME"
else
    error "Impossible de configurer le quota"
fi
