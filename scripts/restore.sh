#!/bin/bash
#######################
# restore.sh — Restauration de la configuration depuis une sauvegarde
#
# Restaure une archive créée par backup.sh. AVANT toute modification, crée un
# snapshot de sécurité (pour pouvoir annuler la restauration), arrête la stack,
# restaure les fichiers, redémarre et lance le healthcheck.
#
# Usage :
#   restore.sh                       # menu : choisir une sauvegarde
#   restore.sh /chemin/vers/backup.tar.gz
#######################

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }

compose() {
    if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
    else docker compose "$@"; fi
}

[ "${EUID:-$(id -u)}" -eq 0 ] || error "Ce script doit être exécuté en tant que root"
[ -d "$INSTALL_DIR" ] || error "Répertoire d'installation introuvable : $INSTALL_DIR"

# 1) Déterminer l'archive à restaurer
ARCHIVE="${1:-}"
if [ -z "$ARCHIVE" ]; then
    mapfile -t BACKUPS < <(ls -1t "$BACKUP_DIR"/seedbox-config-*.tar.gz 2>/dev/null)
    [ "${#BACKUPS[@]}" -gt 0 ] || error "Aucune sauvegarde trouvée dans $BACKUP_DIR"
    echo ""
    info "Sauvegardes disponibles (plus récentes en premier) :"
    i=1
    for b in "${BACKUPS[@]}"; do
        printf "  %2d) %s  (%s)\n" "$i" "$(basename "$b")" "$(du -h "$b" | cut -f1)"
        i=$((i+1))
    done
    echo ""
    read -r -p "Numéro de la sauvegarde à restaurer (0 = annuler) : " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#BACKUPS[@]}" ] || { info "Annulé"; exit 0; }
    ARCHIVE="${BACKUPS[$((n-1))]}"
fi
[ -f "$ARCHIVE" ] || error "Archive introuvable : $ARCHIVE"

# Vérifier que l'archive est lisible
tar tzf "$ARCHIVE" >/dev/null 2>&1 || error "Archive illisible ou corrompue : $ARCHIVE"

echo ""
warn "La restauration va ÉCRASER la configuration actuelle par : $(basename "$ARCHIVE")"
warn "(Les téléchargements/médias ne sont pas touchés.)"
read -r -p "Confirmer ? Tapez 'restaurer' : " confirm
[ "$confirm" = "restaurer" ] || { info "Annulé"; exit 0; }

# 2) Snapshot de sécurité AVANT restauration (permet d'annuler l'annulation)
log "Snapshot de sécurité avant restauration..."
if [ -x "$SCRIPT_DIR/backup.sh" ]; then
    SAFE=$("$SCRIPT_DIR/backup.sh" --auto --label pre-restore | tail -1)
    [ -n "$SAFE" ] && success "Snapshot : $SAFE"
else
    warn "backup.sh introuvable — pas de snapshot de sécurité"
fi

# 3) Arrêter la stack
if [ -f "$INSTALL_DIR/docker-compose.yml" ] && docker info >/dev/null 2>&1; then
    log "Arrêt des services..."
    ( cd "$INSTALL_DIR" && compose down ) || warn "Arrêt partiel des services"
fi

# 4) Restaurer les fichiers
log "Restauration des fichiers de configuration..."
tar xzf "$ARCHIVE" -C "$INSTALL_DIR" || error "Échec de l'extraction (config potentiellement incohérente ; snapshot : ${SAFE:-aucun})"

# 5) Restaurer les mappings de quotas
if [ -f "$INSTALL_DIR/.backup_meta/projid" ]; then
    cp "$INSTALL_DIR/.backup_meta/projid"   /etc/projid   2>/dev/null && info "/etc/projid restauré"
fi
if [ -f "$INSTALL_DIR/.backup_meta/projects" ]; then
    cp "$INSTALL_DIR/.backup_meta/projects" /etc/projects 2>/dev/null && info "/etc/projects restauré"
fi
rm -rf "$INSTALL_DIR/.backup_meta"

# 6) Redémarrer
if [ -f "$INSTALL_DIR/docker-compose.yml" ] && docker info >/dev/null 2>&1; then
    log "Redémarrage des services..."
    ( cd "$INSTALL_DIR" && compose up -d ) || warn "Certains services n'ont pas redémarré"
    docker restart authelia >/dev/null 2>&1 || true
fi

success "Restauration terminée depuis $(basename "$ARCHIVE")"
[ -n "${SAFE:-}" ] && info "Pour annuler cette restauration : sudo $SCRIPT_DIR/restore.sh \"$SAFE\""

# 7) Vérification
if [ -x "$SCRIPT_DIR/healthcheck.sh" ]; then
    echo ""
    log "Vérification du système..."
    INSTALL_DIR="$INSTALL_DIR" "$SCRIPT_DIR/healthcheck.sh" || warn "Le healthcheck signale des problèmes (voir ci-dessus)."
fi
