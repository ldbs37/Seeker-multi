#!/bin/bash
#######################
# lib_traefik.sh — Routage Traefik des services UTILISATEUR (source unique)
#
# Utilisée par add_user.sh, add_user_service.sh et generate_traefik_labels.sh.
# À sourcer : source "$(dirname "$0")/lib_traefik.sh"
#
# Schéma d'URL (par chemin) :
#   https://<user>.<domaine>/                -> Homarr (tableau de bord)
#   https://<user>.<domaine>/qbittorrent     -> qBittorrent (préfixe retiré)
#   https://<user>.<domaine>/files           -> Filebrowser (FB_BASEURL)
#   https://<user>.<domaine>/sonarr …        -> *arr (UrlBase pré-configurée)
#   https://<user>.<domaine>/bazarr          -> Bazarr (base_url pré-configurée)
#   https://<user>.<domaine>/calibre         -> Calibre-Web (en-tête X-Script-Name)
#   https://overseerr-<user>.<domaine>/      -> Overseerr (ne supporte pas les
#                                               sous-chemins : sous-domaine dédié)
# Tous protégés par Authelia (authelia@docker), isolés par utilisateur via les
# règles domain_regex (?P<User>…) de la configuration Authelia.
#######################

# Détecte le mode d'accès depuis .env ; définit USE_TRAEFIK et DOMAIN.
# $1 = chemin du .env
traefik_detect() {
    local env_file="$1"
    USE_TRAEFIK=false
    DOMAIN=""
    [ -f "$env_file" ] || return 0
    DOMAIN=$(grep '^DOMAIN=' "$env_file" | cut -d'=' -f2)
    if grep -q '^USE_TRAEFIK=' "$env_file"; then
        grep -q '^USE_TRAEFIK=true' "$env_file" && USE_TRAEFIK=true
    elif [ -n "$DOMAIN" ]; then
        # Rétro-compatibilité : ancien .env sans flag explicite
        # shellcheck disable=SC2034  # lue par les bibliothèques sourcées
        USE_TRAEFIK=true
    fi
    return 0
}

# Chemin public d'un service ("" = racine, "SUBDOMAIN" = sous-domaine dédié)
traefik_service_path() {
    case "$1" in
        homarr)      echo "" ;;
        qbittorrent) echo "/qbittorrent" ;;
        filebrowser) echo "/files" ;;
        sonarr|radarr|readarr|bazarr|prowlarr|calibre) echo "/$1" ;;
        overseerr)   echo "SUBDOMAIN" ;;
        *) return 1 ;;
    esac
}

# Port interne (dans le conteneur) d'un service en mode Traefik
traefik_service_port() {
    case "$1" in
        homarr) echo 7575 ;;      qbittorrent) echo 8080 ;;  filebrowser) echo 80 ;;
        sonarr) echo 8989 ;;      radarr) echo 7878 ;;       readarr) echo 8787 ;;
        bazarr) echo 6767 ;;      prowlarr) echo 9696 ;;     overseerr) echo 5055 ;;
        calibre) echo 8083 ;;
        *) return 1 ;;
    esac
}

# URL publique d'un service (mode Traefik). $1=service $2=user
traefik_service_url() {
    local path; path=$(traefik_service_path "$1") || return 1
    if [ "$path" = "SUBDOMAIN" ]; then
        echo "https://$1-$2.${DOMAIN}"
    else
        echo "https://$2.${DOMAIN}${path}"
    fi
}

# Émet (stdout) les clés `networks:` et `labels:` d'un service utilisateur,
# indentées pour un bloc de service docker-compose.
# $1=service $2=utilisateur [$3=port interne, défaut selon le service]
# NB : backticks littéraux (non échappés) et `$$` pour docker-compose.
traefik_user_labels() {
    local svc="$1" user="$2" port="${3:-}" path r host rule mw
    path=$(traefik_service_path "$svc") || return 1
    [ -n "$port" ] || port=$(traefik_service_port "$svc")
    r="${svc}-${user}"                         # nom de routeur unique
    if [ "$path" = "SUBDOMAIN" ]; then
        host="${svc}-${user}.${DOMAIN}"; rule="Host(\`${host}\`)"
    else
        host="${user}.${DOMAIN}"
        rule="Host(\`${host}\`)"
        [ -n "$path" ] && rule="${rule} && PathPrefix(\`${path}\`)"
    fi
    mw="authelia@docker"

    echo "    networks:"
    echo "      - traefik_proxy"
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo "      - \"traefik.docker.network=traefik_proxy\""
    echo "      - \"traefik.http.routers.${r}.rule=${rule}\""
    echo "      - \"traefik.http.routers.${r}.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.${r}.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.services.${r}.loadbalancer.server.port=${port}\""
    case "$svc" in
        qbittorrent)
            # qBittorrent ne gère pas d'URL de base : on ajoute le "/" final
            # (sinon les ressources relatives partent à la racine) puis on
            # retire le préfixe avant de transmettre.
            echo "      - \"traefik.http.middlewares.${r}-slash.redirectregex.regex=^(https?://[^/]+/qbittorrent)\$\$\""
            echo "      - \"traefik.http.middlewares.${r}-slash.redirectregex.replacement=\$\${1}/\""
            echo "      - \"traefik.http.middlewares.${r}-strip.stripprefix.prefixes=/qbittorrent\""
            mw="${mw},${r}-slash,${r}-strip"
            ;;
        calibre)
            echo "      - \"traefik.http.middlewares.${r}-hdr.headers.customrequestheaders.X-Script-Name=/calibre\""
            mw="${mw},${r}-hdr"
            ;;
    esac
    echo "      - \"traefik.http.routers.${r}.middlewares=${mw}\""
}

# Pré-configure l'URL de base d'une appli servie sous un chemin (mode Traefik).
# Idempotent ; à appeler AVANT le premier démarrage (ou conteneur arrêté).
# $1=service $2=dossier monté sur /config $3=uid propriétaire
traefik_prepare_app() {
    local svc="$1" cfg="$2" uid="$3" path f
    path=$(traefik_service_path "$svc") || return 0
    mkdir -p "$cfg"
    case "$svc" in
        sonarr|radarr|readarr|prowlarr)
            f="$cfg/config.xml"
            if [ ! -f "$f" ]; then
                # Config minimale : l'appli complète les autres clés au 1er démarrage
                printf '<Config>\n  <UrlBase>%s</UrlBase>\n</Config>\n' "$path" > "$f"
            elif grep -q '<UrlBase>' "$f"; then
                sed -i "s#<UrlBase>.*</UrlBase>#<UrlBase>${path}</UrlBase>#" "$f"
            else
                sed -i "s#<Config>#<Config>\n  <UrlBase>${path}</UrlBase>#" "$f"
            fi
            ;;
        bazarr)
            f="$cfg/config/config.yaml"
            mkdir -p "$cfg/config"
            if [ ! -f "$f" ]; then
                printf 'general:\n  base_url: %s\n' "$path" > "$f"
            elif grep -qE '^  base_url:' "$f"; then
                sed -i -E "s#^  base_url:.*#  base_url: ${path}#" "$f"
            elif grep -q '^general:' "$f"; then
                sed -i "s#^general:#general:\n  base_url: ${path}#" "$f"
            else
                printf 'general:\n  base_url: %s\n' "$path" >> "$f"
            fi
            ;;
        *) return 0 ;;
    esac
    chown -R "$uid:$uid" "$cfg" 2>/dev/null || true
}
