#!/bin/bash
#######################
# lib_services.sh — Définition des services UTILISATEUR (source unique)
#
# Génère les blocs docker-compose de chaque service d'un utilisateur (routés
# par Traefik, derrière Authelia). Utilisée par add_user.sh,
# add_user_service.sh et generate_traefik_labels.sh.
#
# Pré-requis (variables) : USERNAME USER_ID USER_DIR INSTALL_DIR TZ
#                          DOMAIN.
# Dépendances : lib_ports.sh, lib_traefik.sh (sourcées par l'appelant) ;
# lib_lang.sh, lib_filebrowser.sh (sourcées ici).
#
# Organisation des données d'un utilisateur ($USER_DIR, monté sur /data) :
#   downloads/ tv/ movies/ books/ config/
# Un montage /data unique pour qBittorrent et les *arr permet les imports par
# hardlink (pas de copie : l'espace disque n'est pas doublé pendant le seed).
#######################

# shellcheck source=lib_lang.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_lang.sh"
# shellcheck source=lib_filebrowser.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_filebrowser.sh"

# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
USER_SERVICES="qbittorrent filebrowser sonarr radarr readarr bazarr prowlarr seerr calibre"
# Plus proposés (installations existantes conservées) : Readarr (abandonné
# par ses auteurs), Bazarr
# shellcheck disable=SC2034  # lue par les scripts qui sourcent cette lib
USER_SERVICES_RETIRED="readarr bazarr"
# Homarr 0.16 individuel (ancien mode port direct) : plus créé ; reconnu pour
# être retiré (migration, suppression d'un utilisateur)
# shellcheck disable=SC2034  # lue par les scripts qui sourcent cette lib
USER_SERVICES_LEGACY="homarr"

FLARESOLVERR_IMAGE="ghcr.io/flaresolverr/flaresolverr:v3.5.2"

service_image() {
    case "$1" in
        qbittorrent) echo "linuxserver/qbittorrent:5.2.3" ;;
        # FileBrowser Quantum (Filebrowser d'origine archivé le 2026-09-01)
        filebrowser) echo "$FBQ_IMAGE" ;;
        sonarr)      echo "linuxserver/sonarr:4.0.20" ;;
        radarr)      echo "linuxserver/radarr:6.4.4" ;;
        readarr)     echo "lscr.io/linuxserver/readarr:develop" ;;
        bazarr)      echo "linuxserver/bazarr:1.6.1" ;;
        prowlarr)    echo "linuxserver/prowlarr:2.6.5" ;;
        # Seerr : successeur d'Overseerr/Jellyseerr (fusion) ; connexion via
        # Jellyfin, Plex ou Emby (Overseerr n'acceptait que Plex)
        seerr)       echo "seerr/seerr:v3.4.1" ;;
        calibre)     echo "linuxserver/calibre-web:0.6.27" ;;
        *) return 1 ;;
    esac
}

# Dossier de configuration (côté hôte) d'un service
service_config_dir() {
    case "$1" in
        qbittorrent|filebrowser) echo "$USER_DIR/config/$1" ;;
        *) echo "$INSTALL_DIR/$1/$USERNAME" ;;
    esac
}

# Prépare dossiers et fichiers AVANT le premier démarrage du service.
# $1=service [$2=mot de passe en clair, pour qBittorrent]
service_prepare() {
    local svc="$1" pass="${2:-}" cfg
    cfg=$(service_config_dir "$svc")
    mkdir -p "$cfg" "$USER_DIR"/{downloads,tv,movies,books}
    case "$svc" in
        qbittorrent)
            local conf="$cfg/qBittorrent/qBittorrent.conf"
            qbit_seed_defaults "$conf"
            if [ -n "$pass" ]; then
                qbit_configure "$conf" "$USERNAME" "$pass" \
                    || warn "Mot de passe qBittorrent non défini (voir logs du conteneur)"
                # Connexion unique : Traefik seul dispensé de mot de passe
                qbit_sso_configure "$conf"
            fi
            qbit_lang_configure "$conf"
            qbit_share_limits_configure "$conf"
            # Interface web VueTorrent (sinon interface d'origine)
            if vuetorrent_ensure; then qbit_vuetorrent_configure "$conf"
            else warn "VueTorrent non téléchargé : interface d'origine de qBittorrent"; fi
            ;;
        filebrowser)
            # Mot de passe : repli si la connexion unique n'est pas prête
            fbq_write_config "$cfg/config.yaml" "$USERNAME" "$pass" ;;
    esac
    traefik_prepare_app "$svc" "$cfg" "$USER_ID"
    chown -R "$USER_ID:$USER_ID" "$cfg" "$USER_DIR"/{downloads,tv,movies,books} \
        "$USER_DIR/config" 2>/dev/null || true
}

# Émet le bloc docker-compose d'un service (stdout). $1=service
service_block() {
    local svc="$1" name img cfg tport
    name="${svc}-${USERNAME}"
    img=$(service_image "$svc") || return 1
    cfg=$(service_config_dir "$svc")
    tport=$(user_port "$USER_ID" torrent)

    echo ""
    echo "  ${name}:"
    echo "    image: ${img}"
    echo "    container_name: ${name}"
    # Filebrowser (image officielle) ignore PUID/PGID ; Seerr tourne en
    # utilisateur fixe (node, 1000) : UID imposé pour écrire sa configuration
    case "$svc" in
        filebrowser|seerr) echo "    user: \"${USER_ID}:${USER_ID}\"" ;;
    esac
    [ "$svc" = seerr ] && echo "    init: true"
    echo "    environment:"
    echo "      - PUID=${USER_ID}"
    echo "      - PGID=${USER_ID}"
    echo "      - TZ=${TZ}"
    case "$svc" in
        qbittorrent)
            echo "      - WEBUI_PORT=8080"
            echo "      - TORRENTING_PORT=${tport}"
            ;;
        filebrowser)
            # Configuration (et base) : config.yaml généré par lib_filebrowser.sh
            echo "      - FILEBROWSER_CONFIG=/home/filebrowser/data/config.yaml"
            ;;
    esac
    echo "    volumes:"
    case "$svc" in
        qbittorrent|sonarr|radarr|readarr|bazarr)
            echo "      - ${cfg}:/config"
            echo "      - ${USER_DIR}:/data"
            # Interface VueTorrent partagée (lib_qbittorrent.sh), lecture seule
            [ "$svc" = qbittorrent ] && [ -d "$INSTALL_DIR/vuetorrent/public" ] \
                && echo "      - ${INSTALL_DIR}/vuetorrent:/vuetorrent:ro"
            ;;
        filebrowser)
            echo "      - ${USER_DIR}:/srv"
            echo "      - ${cfg}:/home/filebrowser/data" ;;
        prowlarr)
            echo "      - ${cfg}:/config" ;;
        seerr)
            echo "      - ${cfg}:/app/config" ;;
        calibre)
            echo "      - ${cfg}:/config"
            echo "      - ${USER_DIR}/books:/books" ;;
    esac
    # Priorité disque la plus basse (poids 10 contre 100 par défaut, effectif
    # avec l'ordonnanceur BFQ : lib_priority.sh) : les applications passent
    # avant les téléchargements
    if [ "$svc" = qbittorrent ]; then
        echo "    blkio_config:"
        echo "      weight: 10"
    fi
    # Seul port publié : le port torrent entrant (TCP+UDP) ; les interfaces
    # passent par Traefik
    if [ "$svc" = qbittorrent ]; then
        echo "    ports:"
        echo "      - \"${tport}:${tport}\""
        echo "      - \"${tport}:${tport}/udp\""
    fi
    if [ "$svc" = filebrowser ]; then
        # Le HEALTHCHECK de l'image teste le port 80 ; ici 8080 (+ /drive)
        local hpath
        hpath="$(traefik_service_path filebrowser)/health"
        echo "    healthcheck:"
        echo "      test: [\"CMD\", \"curl\", \"-fs\", \"http://localhost:${FBQ_PORT}${hpath}\"]"
        echo "      interval: 30s"
        echo "      timeout: 5s"
        echo "      retries: 3"
        echo "      start_period: 20s"
    fi
    traefik_user_labels "$svc" "$USERNAME"
    echo "    restart: unless-stopped"
    # FlareSolverr propre à l'utilisateur, sur son réseau (un FlareSolverr
    # partagé, navigateur piloté par tous, pourrait joindre les services des
    # autres utilisateurs)
    [ "$svc" = prowlarr ] && user_flaresolverr_block
    return 0
}

# Bloc docker-compose du FlareSolverr de l'utilisateur (stdout)
user_flaresolverr_block() {
    echo ""
    echo "  flaresolverr-${USERNAME}:"
    echo "    image: ${FLARESOLVERR_IMAGE}"
    echo "    container_name: flaresolverr-${USERNAME}"
    echo "    environment:"
    echo "      - LOG_LEVEL=info"
    echo "      - TZ=${TZ}"
    echo "    networks:"
    echo "      - $(user_net "$USERNAME")"
    echo "    restart: unless-stopped"
}

# Commande docker compose disponible (v2 plugin ou v1 autonome)
compose_cmd() {
    if docker compose version >/dev/null 2>&1; then docker compose "$@"
    elif command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
    else return 127; fi
}

# Valide un fichier compose (interpolation via le .env de $INSTALL_DIR).
# Retour 0 si valide ou si aucun outil compose n'est disponible pour vérifier.
compose_validate() {
    local out rc
    out=$(compose_cmd -f "$1" --project-directory "$INSTALL_DIR" config -q 2>&1); rc=$?
    [ "$rc" -eq 127 ] && return 0
    [ "$rc" -eq 0 ] || echo "$out" >&2
    return "$rc"
}

# Ajoute les services au docker-compose.yml de façon ATOMIQUE : écriture dans
# une copie, validation, puis remplacement. Le fichier réel n'est jamais cassé.
# $1=fichier compose ; $2.. = services
compose_append_services() {
    local file="$1" tmp s; shift
    tmp="${file%.yml}.new.yml"
    cp "$file" "$tmp" || return 1
    for s in "$@"; do
        service_block "$s" >> "$tmp" || { rm -f "$tmp"; return 1; }
    done
    # Réseau privé de l'utilisateur : déclaré, Traefik et Homarr raccordés
    compose_sync_user_nets "$tmp"
    [ $? -eq 2 ] && { rm -f "$tmp"; return 1; }
    if compose_validate "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# URL d'accès d'un service (affichage). $1=service
service_url() {
    traefik_service_url "$1" "$USERNAME"
}
