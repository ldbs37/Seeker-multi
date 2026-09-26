#!/bin/bash
#######################
# lib_qbitmanage.sh — qbit_manage de chaque utilisateur (qbitmanage-<user>,
# sur son réseau privé, à côté de son qBittorrent) : on ne supprime un film
# ou une série qu'à un endroit (Radarr / Sonarr, fichiers compris), le reste
# suit.
#
# - Torrents « sans lien » (étiquette noHL : fichier plus présent dans la
#   bibliothèque, remplacé par une mise à niveau ou supprimé dans Radarr /
#   Sonarr), catégories radarr et tv-sonarr seulement : supprimés avec leurs
#   fichiers après QBM_NOHL_DELAY de partage (7 jours).
# - Autres torrents : partage jusqu'à 14 jours ou ratio 3, puis arrêt
#   (Radarr / Sonarr suppriment ensuite les leurs ; les torrents ajoutés à la
#   main sont seulement arrêtés).
# - Torrents retirés du tracker : supprimés.
# - Fichiers de downloads/ sans torrent : NON touchés (un utilisateur peut y
#   déposer les siens, avec FileBrowser par exemple).
# - Corbeille : downloads/.RecycleBin, vidée après 7 jours.
# Connexion à qBittorrent par sa clé d'API (qBittorrent 5.2+). Configuration
# régénérée à chaque passage si elle porte la marque de la seedbox (sinon
# conservée : modifiée à la main). Vérifié sur qbit_manage 4.13.0 et
# qBittorrent 5.2.3.
#
# Réglage : QBM_NOHL_DELAY=<n>[mhdw] dans $INSTALL_DIR/.env (défaut 7d).
# Variables : INSTALL_DIR, TZ ; fonctions de lib_traefik.sh (user_net).
#######################

QBIT_MANAGE_IMAGE="ghcr.io/stuffanthings/qbit_manage:v4.13.0"
QBM_NOHL_DELAY="${QBM_NOHL_DELAY:-7d}"
QBM_MARK="# seedbox : généré par lib_qbitmanage.sh"

# Bloc docker-compose de qbitmanage-<user> (stdout). Variables : USERNAME,
# USER_ID, USER_DIR
user_qbitmanage_block() {
    echo ""
    echo "  qbitmanage-${USERNAME}:"
    echo "    image: ${QBIT_MANAGE_IMAGE}"
    echo "    container_name: qbitmanage-${USERNAME}"
    echo "    environment:"
    echo "      - PUID=${USER_ID}"
    echo "      - PGID=${USER_ID}"
    echo "      - TZ=${TZ}"
    echo "      - QBT_SCHEDULE=30"
    echo "      - QBT_WEB_SERVER=false"
    echo "    volumes:"
    echo "      - ${INSTALL_DIR}/qbit_manage/${USERNAME}:/config"
    echo "      - ${USER_DIR}:/data"
    echo "    networks:"
    echo "      - $(user_net "$USERNAME")"
    echo "    restart: unless-stopped"
}

# Configuration de qbit_manage (stdout). $1=hôte:port de qBittorrent
# $2=clé d'API $3=racine des données (/data dans le conteneur)
qbm_config() {
    local host="$1" key="$2" root="${3:-/data}"
    cat << EOF
$QBM_MARK (modifié à la main : retirez cette ligne pour le conserver)
commands:
  dry_run: false
  recheck: false
  cat_update: false
  tag_update: false
  rem_unregistered: true
  tag_tracker_error: false
  rem_orphaned: false
  tag_nohardlinks: true
  share_limits: true
  skip_qb_version_check: false
  skip_cleanup: false

qbt:
  host: "$host"
  apikey: "$key"

settings:
  nohardlinks_tag: noHL
  tag_nohardlinks_filter_completed: true
  share_limits_filter_completed: true
  rem_unregistered_filter_completed: false
  disable_qbt_default_share_limits: true

directory:
  root_dir: "$root/downloads/"
  recycle_bin: "$root/downloads/.RecycleBin"

cat:
  radarr: "$root/downloads"
  tv-sonarr: "$root/downloads"
  Uncategorized: "$root/downloads"

tracker:
  other:
    tag: other

# Fichier encore lié dans la bibliothèque (movies/, tv/) = torrent utile
nohardlinks:
  radarr:
    ignore_root_dir: true
  tv-sonarr:
    ignore_root_dir: true

share_limits:
  # Ancienne version remplacée, ou média supprimé dans Radarr / Sonarr
  sans_lien:
    priority: 1
    include_all_tags:
      - noHL
    categories:
      - radarr
      - tv-sonarr
    max_seeding_time: $QBM_NOHL_DELAY
    cleanup: true
    share_limit_action: Stop
  # Tous les autres : 14 jours ou ratio 3, puis arrêt
  partage:
    priority: 99
    max_ratio: 3
    max_seeding_time: 14d
    cleanup: false
    share_limit_action: Stop

recyclebin:
  enabled: true
  empty_after_x_days: 7
  save_torrents: false
  split_by_category: false
EOF
}

# Écrit la configuration de $1 (clé d'API de son qBittorrent) et redémarre
# son qbit_manage si elle a changé. Retour 0 si à jour.
qbm_configure() {
    local user="$1" dir conf key new sum delay
    grep -q "^  qbitmanage-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || return 0
    dir="$INSTALL_DIR/qbit_manage/$user"; conf="$dir/config.yml"
    mkdir -p "$dir"
    if [ -f "$conf" ] && ! grep -qF "$QBM_MARK" "$conf"; then
        return 0   # modifiée à la main : conservée
    fi
    # Délai choisi dans .env (QBM_NOHL_DELAY=3d), sinon 7 jours
    delay=$(sed -n 's/^QBM_NOHL_DELAY=\([0-9]\+[mhdw]\)$/\1/p' "$INSTALL_DIR/.env" 2>/dev/null | tail -1)
    [ -n "$delay" ] && QBM_NOHL_DELAY="$delay"
    key=$(qbit_ensure_api_key "$user") && [ -n "$key" ] || { echo "Clé d'API qBittorrent de $user indisponible" >&2; return 1; }
    new=$(qbm_config "qbittorrent-$user:8080" "$key")
    # qbit_manage réécrit son fichier (valeurs par défaut ajoutées) : on
    # compare l'empreinte de ce que la seedbox a généré
    sum=$(printf '%s\n' "$new" | sha256sum | cut -d' ' -f1)
    [ -f "$conf" ] && [ "$(cat "$dir/.seedbox.sha256" 2>/dev/null)" = "$sum" ] && return 0
    printf '%s\n' "$new" > "$conf"
    echo "$sum" > "$dir/.seedbox.sha256"
    chown -R "$(id -u "$user"):$(id -g "$user")" "$dir" 2>/dev/null || true
    chmod 600 "$conf"
    docker restart "qbitmanage-$user" >/dev/null 2>&1 || true
}
