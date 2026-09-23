#!/bin/bash
#######################
# lib_quota.sh — Fonctions partagées pour les QUOTAS PROJET
#
# Principe : on limite un DOSSIER (l'espace d'un utilisateur) via un
# "project quota", indépendamment du propriétaire des fichiers.
#   - XFS  : option de montage `pquota` + xfs_quota
#   - ext4 : feature `project` + option `prjquota` + chattr -p + setquota -P
#
# À sourcer : source "$(dirname "$0")/lib_quota.sh"
# Ne définit que des fonctions ; ne modifie rien à l'import.
#######################

# Point de montage contenant un chemin
quota_mount()  { findmnt -T "$1" -no TARGET 2>/dev/null; }
# Type de système de fichiers d'un chemin
quota_fstype() { findmnt -T "$1" -no FSTYPE 2>/dev/null; }

# Les quotas PROJET sont-ils actifs pour ce chemin ? (0 = oui)
quota_project_active() {
    local path="$1" m fs
    command -v findmnt >/dev/null 2>&1 || return 1
    m=$(quota_mount "$path"); fs=$(quota_fstype "$path")
    [ -n "$m" ] || return 1
    case "$fs" in
        xfs)
            command -v xfs_quota >/dev/null 2>&1 || return 1
            xfs_quota -x -c 'state -p' "$m" 2>/dev/null | grep -qi 'Accounting: ON'
            ;;
        ext2|ext3|ext4)
            command -v repquota >/dev/null 2>&1 || return 1
            repquota -Ps "$m" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

# Applique un quota projet à un dossier.
# $1 = dossier, $2 = id projet (entier unique), $3 = quota en Go
# Retour : 0 = appliqué, 1 = échec, 2 = FS non supporté
quota_apply_project() {
    local dir="$1" projid="$2" gb="$3" m fs
    m=$(quota_mount "$dir"); fs=$(quota_fstype "$dir")
    [ -n "$m" ] || return 1
    case "$fs" in
        xfs)
            command -v xfs_quota >/dev/null 2>&1 || return 1
            xfs_quota -x -c "project -s -p $dir $projid" "$m" >/dev/null 2>&1 || return 1
            xfs_quota -x -c "limit -p bhard=${gb}g $projid" "$m" >/dev/null 2>&1 || return 1
            ;;
        ext2|ext3|ext4)
            command -v setquota >/dev/null 2>&1 || return 1
            # +P : héritage du projet, -p : id projet sur tout le sous-arbre
            chattr -R +P -p "$projid" "$dir" >/dev/null 2>&1 || true
            setquota -P "$projid" 0 "$((gb * 1024 * 1024))" 0 0 "$m" >/dev/null 2>&1 || return 1
            ;;
        *) return 2 ;;
    esac
    return 0
}

# Enregistre (idempotent) le mapping nom<->projet dans /etc/projid et /etc/projects
# $1 = nom (utilisateur), $2 = id projet, $3 = dossier
quota_register_project() {
    local name="$1" projid="$2" dir="$3"
    touch /etc/projid /etc/projects 2>/dev/null || return 0
    grep -q "^${name}:" /etc/projid 2>/dev/null   || echo "${name}:${projid}" >> /etc/projid
    grep -q "^${projid}:" /etc/projects 2>/dev/null || echo "${projid}:${dir}" >> /etc/projects
}
