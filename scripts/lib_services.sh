#!/bin/bash
#######################
# lib_services.sh — Définition des services UTILISATEUR (source unique)
#
# Génère les blocs docker-compose de chaque service d'un utilisateur, pour les
# deux modes (Traefik ou port direct). Utilisée par add_user.sh et
# add_user_service.sh.
#
# Pré-requis (variables) : USERNAME USER_ID USER_DIR INSTALL_DIR TZ USE_TRAEFIK
#                          DOMAIN.
# Dépendances : lib_ports.sh, lib_traefik.sh (sourcées par l'appelant) ;
# lib_filebrowser.sh (sourcée ici).
#
# Organisation des données d'un utilisateur ($USER_DIR, monté sur /data) :
#   downloads/ tv/ movies/ books/ config/
# Un montage /data unique pour qBittorrent et les *arr permet les imports par
# hardlink (pas de copie : l'espace disque n'est pas doublé pendant le seed).
#######################

# shellcheck source=lib_filebrowser.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib_filebrowser.sh"

# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
USER_SERVICES="qbittorrent homarr filebrowser sonarr radarr readarr bazarr prowlarr seerr calibre"

service_image() {
    case "$1" in
        qbittorrent) echo "linuxserver/qbittorrent:5.2.3" ;;
        homarr)      echo "ghcr.io/ajnart/homarr:0.16.1" ;;
        # FileBrowser Quantum (Filebrowser d'origine archivé le 2026-09-01)
        filebrowser) echo "$FBQ_IMAGE" ;;
        sonarr)      echo "linuxserver/sonarr:4.0.20" ;;
        radarr)      echo "linuxserver/radarr:6.4.4" ;;
        readarr)     echo "lscr.io/linuxserver/readarr:develop" ;;
        bazarr)      echo "linuxserver/bazarr:1.6.1" ;;
        prowlarr)    echo "linuxserver/prowlarr:2.6.5" ;;
        # Seerr : successeur d'Overseerr/Jellyseerr (fusion) ; connexion via
        # Jellyfin, Plex ou Emby (Overseerr n'acceptait que Plex)
        seerr)       echo "seerr/seerr:v3.0.1" ;;
        calibre)     echo "linuxserver/calibre-web:0.6.27" ;;
        *) return 1 ;;
    esac
}

# Dossier de configuration (côté hôte) d'un service
service_config_dir() {
    case "$1" in
        qbittorrent|homarr|filebrowser) echo "$USER_DIR/config/$1" ;;
        *) echo "$INSTALL_DIR/$1/$USERNAME" ;;
    esac
}

# Prépare dossiers et fichiers AVANT le premier démarrage du service.
# $1=service [$2=mot de passe en clair, pour qBittorrent]
service_prepare() {
    local svc="$1" pass="${2:-}" cfg proxy_net=""
    cfg=$(service_config_dir "$svc")
    mkdir -p "$cfg" "$USER_DIR"/{downloads,tv,movies,books}
    case "$svc" in
        qbittorrent)
            local conf="$cfg/qBittorrent/qBittorrent.conf"
            qbit_seed_defaults "$conf"
            if [ -n "$pass" ]; then
                if [ "$USE_TRAEFIK" = true ]; then
                    proxy_net=$(docker network inspect traefik_proxy \
                        -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || true)
                fi
                qbit_configure "$conf" "$USERNAME" "$pass" "$proxy_net" \
                    || warn "Mot de passe qBittorrent non défini (voir logs du conteneur)"
                # Connexion unique via Traefik (remplace la prise en charge du proxy)
                [ "$USE_TRAEFIK" = true ] && qbit_sso_configure "$conf"
            fi
            # Interface web VueTorrent (sinon interface d'origine)
            if vuetorrent_ensure; then qbit_vuetorrent_configure "$conf"
            else warn "VueTorrent non téléchargé : interface d'origine de qBittorrent"; fi
            ;;
        homarr) mkdir -p "$USER_DIR/config/homarr-icons" ;;
        filebrowser)
            # Mot de passe utile en mode port direct seulement (sinon connexion unique)
            fbq_write_config "$cfg/config.yaml" "$USERNAME" "$pass" ;;
    esac
    [ "$USE_TRAEFIK" = true ] && traefik_prepare_app "$svc" "$cfg" "$USER_ID"
    chown -R "$USER_ID:$USER_ID" "$cfg" "$USER_DIR"/{downloads,tv,movies,books} \
        "$USER_DIR/config" 2>/dev/null || true
}

# Émet le bloc docker-compose d'un service (stdout). $1=service
service_block() {
    local svc="$1" name img cfg port inner tport
    name="${svc}-${USERNAME}"
    img=$(service_image "$svc") || return 1
    cfg=$(service_config_dir "$svc")
    port=$(user_port "$USER_ID" "$svc")
    inner=$(traefik_service_port "$svc")
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
        homarr)
            # Pas de fenêtre « migrez vers Homarr 1.0 » (réécriture complète,
            # migration manuelle ; la 0.16 reste pleinement fonctionnelle)
            echo "      - DISABLE_UPGRADE_MODAL=true"
            ;;
        qbittorrent)
            # WebUI : port interne = port publié en mode direct
            if [ "$USE_TRAEFIK" = true ]; then echo "      - WEBUI_PORT=8080"
            else echo "      - WEBUI_PORT=${port}"; inner=$port; fi
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
        homarr)
            echo "      - ${cfg}:/app/data/configs"
            echo "      - ${USER_DIR}/config/homarr-icons:/app/public/icons" ;;
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
    # Ports publiés : WebUI en mode direct ; port torrent (TCP+UDP) toujours
    if [ "$USE_TRAEFIK" != true ] || [ "$svc" = qbittorrent ]; then
        echo "    ports:"
        [ "$USE_TRAEFIK" != true ] && echo "      - \"${port}:${inner}\""
        if [ "$svc" = qbittorrent ]; then
            echo "      - \"${tport}:${tport}\""
            echo "      - \"${tport}:${tport}/udp\""
        fi
    fi
    if [ "$svc" = homarr ]; then
        # Le HEALTHCHECK de l'image teste localhost, mais Next.js n'écoute que
        # sur l'IP du conteneur ($HOSTNAME) : conteneur « unhealthy » à tort,
        # donc ignoré par Traefik (404). Test sur le nom du conteneur.
        echo "    healthcheck:"
        echo "      test: [\"CMD-SHELL\", \"wget -q --spider http://\$\$(hostname):7575 || exit 1\"]"
        echo "      interval: 30s"
        echo "      timeout: 5s"
        echo "      retries: 3"
        echo "      start_period: 30s"
    fi
    if [ "$svc" = filebrowser ]; then
        # Le HEALTHCHECK de l'image teste le port 80 ; ici 8080 (+ /files)
        local hpath="/health"
        [ "$USE_TRAEFIK" = true ] && hpath="$(traefik_service_path filebrowser)/health"
        echo "    healthcheck:"
        echo "      test: [\"CMD\", \"curl\", \"-fs\", \"http://localhost:${FBQ_PORT}${hpath}\"]"
        echo "      interval: 30s"
        echo "      timeout: 5s"
        echo "      retries: 3"
        echo "      start_period: 20s"
    fi
    [ "$USE_TRAEFIK" = true ] && traefik_user_labels "$svc" "$USERNAME"
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
    if compose_validate "$tmp"; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
        return 1
    fi
}

# URL d'accès d'un service (affichage). $1=service
service_url() {
    if [ "$USE_TRAEFIK" = true ]; then
        traefik_service_url "$1" "$USERNAME"
    else
        local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
        echo "http://${ip:-votre-serveur}:$(user_port "$USER_ID" "$1")"
    fi
}
