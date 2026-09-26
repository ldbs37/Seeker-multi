#!/bin/bash
#######################
# lib_priority.sh — Les applications passent avant les téléchargements
# (disque et réseau). Rien n'est bridé quand le serveur est calme :
# qBittorrent garde tout le débit disponible et cède seulement la place.
#
# - Disque : ordonnanceur BFQ sur les disques physiques des données (seul
#   ordonnanceur Linux qui répartit selon des poids ; règle udev pour les
#   redémarrages) et poids 10 pour les conteneurs qBittorrent
#   (blkio_config, lib_services.sh) contre 100 pour les autres.
# - Réseau (sortant) : file « prio » à 3 niveaux (fq_codel dans chacun) sur
#   l'interface de sortie ; le trafic des conteneurs qBittorrent (adresses
#   relues chaque minute : elles changent au redémarrage) va dans le niveau
#   le plus bas, tout le reste (Traefik, Jellyfin…) dans celui du milieu.
#
# Variables : INSTALL_DIR.
#######################

PRIO_CHAIN="SEEDBOX_PRIO"
PRIO_UDEV="/etc/udev/rules.d/60-seedbox-bfq.rules"

# Disques physiques portant $1 (partitions, LVM, RAID logiciel remontés)
_prio_disks() {
    local src
    src=$(findmnt -no SOURCE --target "$1" 2>/dev/null | sed 's/\[.*//')
    [ -n "$src" ] || return 0
    lsblk -snpo NAME,TYPE "$src" 2>/dev/null | awk '$2 == "disk" { sub(".*/", "", $1); print $1 }' | sort -u
}

# Ordonnanceur BFQ sur les disques des données (immédiat + règle udev)
priority_disk_apply() {
    local d sched rules=""
    for d in $(_prio_disks "$INSTALL_DIR/data"); do
        sched="/sys/block/$d/queue/scheduler"
        [ -w "$sched" ] || continue
        if ! grep -qw bfq "$sched"; then
            modprobe bfq 2>/dev/null || true
            grep -qw bfq "$sched" || { echo "BFQ indisponible pour $d : priorité disque inactive" >&2; continue; }
        fi
        grep -q '\[bfq\]' "$sched" || echo bfq > "$sched" 2>/dev/null \
            || { echo "BFQ non appliqué à $d" >&2; continue; }
        rules+="ACTION==\"add|change\", KERNEL==\"$d\", ATTR{queue/scheduler}=\"bfq\""$'\n'
    done
    if [ -n "$rules" ]; then
        mkdir -p "$(dirname "$PRIO_UDEV")"
        printf '# Seedbox : priorité disque des applications sur les téléchargements (lib_priority.sh)\n%s' "$rules" > "$PRIO_UDEV"
    fi
    return 0
}

# Interface de sortie (route par défaut)
_prio_iface() { ip -4 route show default 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'; }

# File « prio » à 3 niveaux (installée si absente) : 1:1 (réservé), 1:2
# (défaut : tout le trafic), 1:3 (téléchargements)
priority_net_qdisc() {
    local ifc="$1"
    tc qdisc show dev "$ifc" 2>/dev/null | grep -q '^qdisc prio 1: root' && return 0
    tc qdisc replace dev "$ifc" root handle 1: prio bands 3 priomap 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1 || return 1
    tc qdisc add dev "$ifc" parent 1:1 fq_codel 2>/dev/null || true
    tc qdisc add dev "$ifc" parent 1:2 fq_codel 2>/dev/null || true
    tc qdisc add dev "$ifc" parent 1:3 fq_codel 2>/dev/null || true
}

# Adresses des conteneurs qBittorrent (tous leurs réseaux)
_prio_qbit_ips() {
    local c
    for c in $(docker ps --format '{{.Names}}' 2>/dev/null | grep '^qbittorrent-'); do
        docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$c" 2>/dev/null
    done | tr ' ' '\n' | grep -E '^[0-9.]+$' | sort -u
}

# Trafic sortant des conteneurs qBittorrent → niveau le plus bas (règles
# réécrites seulement si les adresses ont changé)
priority_net_sync() {
    local ifc ips cur want ip
    ifc=$(_prio_iface); [ -n "$ifc" ] || { echo "Interface de sortie introuvable" >&2; return 1; }
    priority_net_qdisc "$ifc" || { echo "File réseau prio non installée sur $ifc" >&2; return 1; }
    iptables -t mangle -N "$PRIO_CHAIN" 2>/dev/null || true
    iptables -t mangle -C POSTROUTING -o "$ifc" -j "$PRIO_CHAIN" 2>/dev/null \
        || iptables -t mangle -A POSTROUTING -o "$ifc" -j "$PRIO_CHAIN"
    ips=$(_prio_qbit_ips)
    want=$(for ip in $ips; do echo "-A $PRIO_CHAIN -s $ip/32 -j CLASSIFY --set-class 0001:0003"; done)
    cur=$(iptables -t mangle -S "$PRIO_CHAIN" 2>/dev/null | grep '^-A ')
    [ "$want" = "$cur" ] && return 0
    iptables -t mangle -F "$PRIO_CHAIN"
    for ip in $ips; do
        iptables -t mangle -A "$PRIO_CHAIN" -s "$ip/32" -j CLASSIFY --set-class 1:3
    done
}

# Tout appliquer (installation, migration, minuteur)
priority_apply() {
    priority_disk_apply
    priority_net_sync
}

# Tout retirer (retour au comportement d'origine)
priority_remove() {
    local ifc
    ifc=$(_prio_iface)
    if [ -n "$ifc" ]; then
        iptables -t mangle -D POSTROUTING -o "$ifc" -j "$PRIO_CHAIN" 2>/dev/null || true
        tc qdisc show dev "$ifc" 2>/dev/null | grep -q '^qdisc prio 1: root' && tc qdisc del dev "$ifc" root 2>/dev/null
    fi
    iptables -t mangle -F "$PRIO_CHAIN" 2>/dev/null; iptables -t mangle -X "$PRIO_CHAIN" 2>/dev/null
    rm -f "$PRIO_UDEV"
    return 0
}

# Minuteur systemd : adresses resynchronisées chaque minute et au démarrage
priority_timer_ensure() {
    command -v systemctl >/dev/null 2>&1 || return 0
    cat > /etc/systemd/system/seedbox-priority.service << EOF
[Unit]
Description=Seedbox - priorité des applications sur les téléchargements (disque, réseau)
After=docker.service network-online.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/priority.sh --apply
EOF
    cat > /etc/systemd/system/seedbox-priority.timer << 'EOF'
[Unit]
Description=Seedbox - priorité des applications (resynchronisation)

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now seedbox-priority.timer >/dev/null 2>&1 || true
}
