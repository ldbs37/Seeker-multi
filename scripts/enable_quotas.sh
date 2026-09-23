#!/bin/bash
#######################
# enable_quotas.sh — Active les QUOTAS PROJET sur le système de fichiers
# contenant la seedbox (par défaut /opt/seedbox).
#
#   - XFS  : ajoute l'option de montage `pquota`
#   - ext4 : active la feature `project` + l'option de montage `prjquota`
#
# ⚠️ Modifie /etc/fstab (sauvegarde automatique). Sur le système de fichiers
#    RACINE, un REDÉMARRAGE est nécessaire pour activer les quotas.
#
# Usage : sudo ./enable_quotas.sh [chemin]   (défaut : /opt/seedbox)
#######################

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()   { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info()  { echo -e "${BLUE}[INFO]${NC} $1"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || error "Ce script doit être exécuté en tant que root"
command -v findmnt >/dev/null 2>&1 || error "findmnt requis (paquet util-linux)"

TARGET="${1:-${INSTALL_DIR:-/opt/seedbox}}"
mkdir -p "$TARGET" 2>/dev/null || true

MOUNT=$(findmnt -T "$TARGET" -no TARGET)
FSTYPE=$(findmnt -T "$TARGET" -no FSTYPE)
SOURCE=$(findmnt -T "$TARGET" -no SOURCE)
OPTS=$(findmnt -T "$TARGET" -no OPTIONS)

info "Cible        : $TARGET"
info "Montage      : $MOUNT ($FSTYPE) sur $SOURCE"
info "Options      : $OPTS"
echo ""

case "$FSTYPE" in
    xfs|ext2|ext3|ext4) : ;;
    *) error "Système de fichiers '$FSTYPE' non pris en charge (ext4 ou xfs requis)" ;;
esac

# Paquets nécessaires
if ! command -v setquota >/dev/null 2>&1; then
    warn "Paquet 'quota' absent — installation..."
    apt-get update -qq && apt-get install -y quota || error "Échec de l'installation de 'quota'"
fi
if [ "$FSTYPE" = "xfs" ] && ! command -v xfs_quota >/dev/null 2>&1; then
    warn "xfsprogs absent — installation..."
    apt-get install -y xfsprogs || error "Échec de l'installation de 'xfsprogs'"
fi

echo -e "${YELLOW}Ce script va modifier /etc/fstab pour activer les quotas projet sur $MOUNT.${NC}"
read -r -p "Continuer ? (o/N) : " confirm
[[ "$confirm" =~ ^[oO]$ ]] || error "Annulé"

# Sauvegarde fstab
BACKUP="/etc/fstab.bak.$(date +%Y%m%d%H%M%S)"
cp /etc/fstab "$BACKUP"
log "Sauvegarde de /etc/fstab -> $BACKUP"

# Option de montage à garantir selon le FS
if [ "$FSTYPE" = "xfs" ]; then
    QOPT="pquota"
else
    QOPT="prjquota"
fi

# Ajoute l'option de quota au champ 4 de la ligne fstab du montage cible,
# uniquement si elle est absente. Ne touche à aucune autre ligne.
if findmnt -T "$TARGET" -no OPTIONS | tr ',' '\n' | grep -qx "$QOPT"; then
    info "Option '$QOPT' déjà présente sur le montage actif."
elif awk -v m="$MOUNT" -v opt="$QOPT" '
        $0 ~ /^[[:space:]]*#/ { next }
        { n=split($0,f); if (f[2]==m) { print (index(f[4],opt)?"present":"absent"); exit } }
     ' /etc/fstab | grep -qx present; then
    info "Option '$QOPT' déjà présente dans /etc/fstab."
else
    awk -v m="$MOUNT" -v opt="$QOPT" 'BEGIN{OFS="\t"}
        /^[[:space:]]*#/ { print; next }
        { if (NF>=4 && $2==m) { $4=$4","opt; print; done=1; next } print }
    ' /etc/fstab > /etc/fstab.tmp && mv /etc/fstab.tmp /etc/fstab
    log "Option '$QOPT' ajoutée à la ligne fstab de $MOUNT."
fi

# ext4 : la feature 'project' doit exister sur le FS (nécessite le FS démonté)
if [ "$FSTYPE" != "xfs" ]; then
    if tune2fs -l "$SOURCE" 2>/dev/null | grep -qi 'project'; then
        info "Feature ext4 'project' déjà présente."
    else
        if [ "$MOUNT" = "/" ]; then
            warn "La feature ext4 'project' n'est pas activée et le FS est monté (racine)."
            warn "Activez-la hors ligne puis relancez ce script :"
            echo "    sudo tune2fs -O project $SOURCE   # FS démonté (mode rescue / live USB)"
            error "Activation 'project' impossible à chaud sur la racine — redémarrage/hors-ligne requis"
        else
            warn "Activation de la feature 'project' (démontage temporaire de $MOUNT)..."
            umount "$MOUNT" || error "Impossible de démonter $MOUNT (fermez ce qui l'utilise)"
            tune2fs -O project "$SOURCE" || { mount "$MOUNT"; error "tune2fs -O project a échoué"; }
            mount "$MOUNT"
            log "Feature 'project' activée."
        fi
    fi
fi

# Activation effective
if [ "$MOUNT" = "/" ]; then
    warn "Le montage est la RACINE : un REDÉMARRAGE est nécessaire pour appliquer '$QOPT'."
    info "Après redémarrage, vérifiez avec :"
    if [ "$FSTYPE" = "xfs" ]; then
        echo "    xfs_quota -x -c 'state -p' /"
    else
        echo "    quotaon -Ppv /   # puis  repquota -Ps /"
    fi
    info "Ensuite, (ré)appliquez les quotas des utilisateurs avec update_quota.sh."
else
    log "Remontage de $MOUNT avec les nouvelles options..."
    mount -o remount "$MOUNT" || warn "Remontage échoué — un redémarrage peut être nécessaire"
    if [ "$FSTYPE" = "xfs" ]; then
        if ! xfs_quota -x -c 'state -p' "$MOUNT" 2>/dev/null | grep -qi 'Accounting: ON'; then
            warn "Quota projet XFS pas encore actif — un REDÉMARRAGE est probablement nécessaire (XFS active les quotas au montage)."
        else
            log "✓ Quota projet XFS actif sur $MOUNT"
        fi
    else
        quotacheck -cuPm "$MOUNT" 2>/dev/null || quotacheck -cuPmf "$MOUNT" 2>/dev/null || warn "quotacheck a signalé un problème"
        quotaon -Pv "$MOUNT" 2>/dev/null || warn "quotaon a échoué"
        log "✓ Quotas projet ext4 activés sur $MOUNT"
    fi
fi

echo ""
log "Terminé. En cas de souci, restaurez : sudo cp $BACKUP /etc/fstab"
