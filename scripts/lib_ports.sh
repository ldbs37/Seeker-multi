#!/bin/bash
#######################
# lib_ports.sh — UID des utilisateurs seedbox et ports associés
#
# UID : plage dédiée à partir de 2001 (évite les comptes humains 1000-1999 et
#       surtout `nobody`=65534, qui faisait attribuer l'UID 65535).
#       Le GID est identique à l'UID (le groupe du même numéro doit être libre).
# Ports (mode port direct + port torrent) : un bloc de 20 ports par
#       utilisateur à partir de 20000, sans collision possible :
#         20000 + (index × 20) + décalage du service
#       index = UID - 2001 (0 pour le premier utilisateur).
#
# À sourcer : source "$(dirname "$0")/lib_ports.sh"
#######################

SEEDBOX_UID_MIN=2001
SEEDBOX_UID_MAX=4276          # 20000 + 2275×20 + 19 = 65519 ≤ 65535
SEEDBOX_PORT_BASE=20000
SEEDBOX_PORT_BLOCK=20

# Décalage de chaque service dans le bloc de l'utilisateur
service_port_offset() {
    case "$1" in
        qbittorrent) echo 0 ;;  homarr) echo 1 ;;     filebrowser) echo 2 ;;
        sonarr) echo 3 ;;       radarr) echo 4 ;;     readarr) echo 5 ;;
        bazarr) echo 6 ;;       prowlarr) echo 7 ;;   overseerr) echo 8 ;;
        calibre) echo 9 ;;      torrent) echo 10 ;;
        *) return 1 ;;
    esac
}

# Port hôte d'un service pour un utilisateur. $1=uid $2=service
user_port() {
    local uid="$1" off idx
    off=$(service_port_offset "$2") || return 1
    if [ "$uid" -ge "$SEEDBOX_UID_MIN" ]; then
        idx=$((uid - SEEDBOX_UID_MIN))
    else
        idx=$((uid - 1001))   # comptes créés par une ancienne version
    fi
    [ "$idx" -ge 0 ] || idx=0
    echo $((SEEDBOX_PORT_BASE + idx * SEEDBOX_PORT_BLOCK + off))
}

# Prochain UID libre (UID ET GID du même numéro inutilisés). stdout = uid
next_seedbox_uid() {
    local u
    for ((u = SEEDBOX_UID_MIN; u <= SEEDBOX_UID_MAX; u++)); do
        if ! getent passwd "$u" >/dev/null && ! getent group "$u" >/dev/null; then
            echo "$u"
            return 0
        fi
    done
    return 1
}
