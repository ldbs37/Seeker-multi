#!/bin/bash
#######################
# enable_quotas.sh — Active les QUOTAS PROJET sur le système de fichiers
# contenant la seedbox (par défaut /opt/seedbox).
#
#   - XFS  : option de montage `pquota` (racine : rootflags=pquota dans GRUB)
#   - ext4 : fonctionnalités `project` + `quota` (tune2fs, disque démonté) et
#            option de montage `prjquota`. Sur la RACINE, l'étape tune2fs se fait
#            en mode rescue : le script l'indique et ne modifie rien avant.
#
# ⚠️ Modifie /etc/fstab (sauvegarde automatique), uniquement une fois le
#    système de fichiers prêt.
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

# ext4 : les quotas PROJET exigent les fonctionnalités 'project' ET 'quota'
# (quotas internes, créées par tune2fs -O project,quota -Q prjquota), qui ne
# s'activent que FS démonté. Vérifié AVANT de toucher à /etc/fstab : une option
# prjquota sur un FS qui ne la supporte pas empêcherait un remontage propre.
EXT4_READY=true
ext4_has_features() {
    local f
    f=$(tune2fs -l "$SOURCE" 2>/dev/null | grep -i '^Filesystem features:')
    [[ " $f " == *" project "* ]] && [[ " $f " == *" quota "* ]]
}
TUNE_CMD="e2fsck -f $SOURCE && tune2fs -O project,quota -Q prjquota $SOURCE"
if [ "$FSTYPE" != "xfs" ] && ! ext4_has_features; then
    EXT4_READY=false
    if [ "$MOUNT" = "/" ]; then
        warn "Le système de fichiers racine ($SOURCE) n'a pas les fonctionnalités ext4"
        warn "'project' et 'quota'. Elles ne s'activent que disque DÉMONTÉ :"
        echo ""
        echo "  1. Démarrez le serveur en mode RESCUE (console de l'hébergeur) ou sur une clé live"
        echo "  2. Vérifiez que $SOURCE n'est PAS monté :  lsblk -f"
        echo "  3. Exécutez :  $TUNE_CMD"
        echo "     (dans le rescue, le nom du disque peut différer : repérez-le avec lsblk -f)"
        echo "  4. Redémarrez normalement, puis relancez :  sudo $0"
        echo ""
        error "Aucune modification effectuée (fstab intact)"
    fi
fi

echo -e "${YELLOW}Ce script va modifier /etc/fstab pour activer les quotas projet sur $MOUNT.${NC}"
[ "$EXT4_READY" = false ] && echo -e "${YELLOW}$MOUNT sera temporairement démonté pour activer les fonctionnalités ext4.${NC}"
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

# ext4 non racine sans les fonctionnalités : démontage temporaire
if [ "$EXT4_READY" = false ]; then
    warn "Activation des fonctionnalités ext4 (démontage temporaire de $MOUNT)..."
    umount "$MOUNT" || error "Impossible de démonter $MOUNT (fermez ce qui l'utilise : docker compose down)"
    if ! { e2fsck -f -p "$SOURCE" && tune2fs -O project,quota -Q prjquota "$SOURCE"; }; then
        mount "$MOUNT"
        error "Activation échouée ($TUNE_CMD) — $MOUNT remonté sans changement"
    fi
    mount "$MOUNT" || error "Remontage de $MOUNT impossible : vérifiez /etc/fstab"
    log "Fonctionnalités ext4 'project' et 'quota' activées."
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

# Activation effective
if [ "$FSTYPE" = "xfs" ]; then
    if [ "$MOUNT" = "/" ]; then
        warn "XFS racine : l'option de fstab est ignorée au démarrage."
        info "Ajoutez 'rootflags=pquota' à GRUB_CMDLINE_LINUX dans /etc/default/grub,"
        info "puis : sudo update-grub && sudo reboot   (vérification : xfs_quota -x -c 'state -p' /)"
    else
        mount -o remount "$MOUNT" 2>/dev/null || true
        if xfs_quota -x -c 'state -p' "$MOUNT" 2>/dev/null | grep -qi 'Accounting: ON'; then
            log "✓ Quota projet XFS actif sur $MOUNT"
        else
            warn "Quota projet XFS pas encore actif : REDÉMARREZ (XFS active les quotas au montage)."
        fi
    fi
else
    # Quotas internes : comptage toujours actif ; quotaon active l'application
    # des limites tout de suite (l'option fstab la rend permanente)
    quotaon -Pv "$MOUNT" >/dev/null 2>&1 || true
    if repquota -Ps "$MOUNT" >/dev/null 2>&1; then
        log "✓ Quotas projet ext4 actifs sur $MOUNT"
        info "Appliquez les quotas des utilisateurs existants : sudo $(dirname "$0")/update_quota.sh <user> <Go>"
    else
        warn "Quotas pas encore actifs : redémarrez, puis vérifiez avec  repquota -Ps $MOUNT"
    fi
fi

echo ""
log "Terminé. En cas de souci, restaurez : sudo cp $BACKUP /etc/fstab"
