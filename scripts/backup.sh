#!/bin/bash
#######################
# backup.sh — Sauvegarde COMPLÈTE de la configuration de la seedbox
#
# Sauvegarde tout ce qui définit l'installation (config, secrets, certificats,
# base utilisateurs, configs par-service et par-utilisateur, mappings de
# quotas) — mais PAS les gros volumes (téléchargements, médias, caches).
#
# Usage :
#   backup.sh                 # sauvegarde interactive
#   backup.sh --auto          # sans prompt (pour appels automatiques)
#   backup.sh --label preupdate   # ajoute un libellé au nom du fichier
#
# Sortie : chemin du fichier .tar.gz créé (sur stdout, dernière ligne).
#######################

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/seedbox}"
RETENTION="${RETENTION:-20}"   # nombre de sauvegardes conservées

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }
info()    { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
success() { echo -e "${GREEN}✓${NC} $1" >&2; }

AUTO=false; LABEL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --auto) AUTO=true ;;
        --label) shift; LABEL="${1:-}" ;;
        *) warn "Argument ignoré : $1" ;;
    esac
    shift
done

[ "${EUID:-$(id -u)}" -eq 0 ] || error "Ce script doit être exécuté en tant que root"
[ -d "$INSTALL_DIR" ] || error "Répertoire d'installation introuvable : $INSTALL_DIR"

# Les archives contiennent des secrets (config Authelia, hashs) : root seul
umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
TS=$(date +%Y%m%d-%H%M%S)
SAFE_LABEL=$(echo "$LABEL" | tr -c 'A-Za-z0-9_-' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
NAME="seedbox-config-${SAFE_LABEL:+${SAFE_LABEL}-}${TS}.tar.gz"
OUT="$BACKUP_DIR/$NAME"

if [ "$AUTO" != true ]; then
    info "Sauvegarde de la CONFIG (sans téléchargements/médias/caches)."
    info "Destination : $OUT"
    read -r -p "Continuer ? (o/N) : " c
    [[ "$c" =~ ^[oO]$ ]] || { info "Annulé"; exit 0; }
fi

# Copier les mappings de quotas (hors INSTALL_DIR) dans l'archive
META="$INSTALL_DIR/.backup_meta"
mkdir -p "$META"
cp /etc/projid   "$META/projid"   2>/dev/null || true
cp /etc/projects "$META/projects" 2>/dev/null || true
echo "$TS" > "$META/created_at"

log "Création de l'archive..."
# En deux temps : tout SAUF ./data (médias, téléchargements…), puis uniquement
# les dossiers config/ des utilisateurs (GNU tar appliquerait l'exclusion
# aussi aux chemins explicites s'ils étaient dans la même commande).
TAR="${OUT%.gz}"
rc=0
tar cf "$TAR" -C "$INSTALL_DIR" \
    --exclude='./data' \
    --exclude='./jellyfin/cache' \
    --exclude='./scrutiny/influxdb' \
    --exclude='./duplicati/backups' \
    --exclude='./plex' \
    --exclude='*.sock' \
    --exclude='*.log' \
    . 2>/dev/null || rc=$?
USER_CONFIGS=()
if [ $rc -eq 0 ]; then
    shopt -s nullglob
    for d in "$INSTALL_DIR"/data/users/*/config; do USER_CONFIGS+=("./${d#"$INSTALL_DIR"/}"); done
    shopt -u nullglob
    if [ ${#USER_CONFIGS[@]} -gt 0 ]; then
        tar rf "$TAR" -C "$INSTALL_DIR" "${USER_CONFIGS[@]}" 2>/dev/null || rc=$?
    fi
fi
[ $rc -eq 0 ] && gzip -f "$TAR" || rc=1
rm -rf "$META"
[ $rc -eq 0 ] && [ -f "$OUT" ] || { rm -f "$TAR" "$OUT"; error "Échec de la création de l'archive"; }

success "Sauvegarde créée : $OUT ($(du -h "$OUT" | cut -f1))"

# Rétention : ne garder que les $RETENTION plus récentes
if [ "$RETENTION" -gt 0 ]; then
    ls -1t "$BACKUP_DIR"/seedbox-config-*.tar.gz 2>/dev/null | tail -n +"$((RETENTION+1))" | while read -r old; do
        rm -f "$old" && info "Ancienne sauvegarde supprimée : $(basename "$old")"
    done
fi

# Chemin de l'archive sur stdout (récupérable par un appelant)
echo "$OUT"
