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
#   https://<user>.<domaine>/drive           -> FileBrowser Quantum (baseURL ; /files redirigé)
#   https://<user>.<domaine>/sonarr …        -> *arr (UrlBase pré-configurée)
#   https://<user>.<domaine>/bazarr          -> Bazarr (base_url pré-configurée)
#   https://<user>.<domaine>/calibre         -> Calibre-Web (en-tête X-Script-Name)
#   https://seerr-<user>.<domaine>/          -> Seerr (successeur d'Overseerr,
#                                               pas de sous-chemins : sous-domaine dédié)
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
        filebrowser) echo "/drive" ;;
        sonarr|radarr|readarr|bazarr|prowlarr|calibre) echo "/$1" ;;
        seerr)       echo "SUBDOMAIN" ;;
        *) return 1 ;;
    esac
}

# Port interne (dans le conteneur) d'un service en mode Traefik
traefik_service_port() {
    case "$1" in
        homarr) echo 7575 ;;      qbittorrent) echo 8080 ;;  filebrowser) echo 8080 ;;
        sonarr) echo 8989 ;;      radarr) echo 7878 ;;       readarr) echo 8787 ;;
        bazarr) echo 6767 ;;      prowlarr) echo 9696 ;;     seerr) echo 5055 ;;
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
    local net=traefik_proxy sso_ip sso_hdr
    sso_ip=$(sso_traefik_ip); sso_hdr=$(sso_header)

    echo "    networks:"
    echo "      - traefik_proxy"
    # qBittorrent joint par Traefik via le réseau dédié (connexion unique,
    # voir « Connexion unique » plus bas)
    if [ "$svc" = qbittorrent ] && [ -n "$sso_ip" ]; then
        echo "      - ${SSO_NET}"; net=$SSO_NET
    fi
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo "      - \"traefik.docker.network=${net}\""
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
            # Retour d'Authelia après connexion : le navigateur envoie
            # « Referer: https://auth.<domaine>/ », que la protection CSRF de
            # qBittorrent rejette (« Unauthorized » jusqu'au rafraîchissement).
            # Referer retiré ; le contrôle par l'en-tête Origin (requêtes POST
            # et inter-sites) reste actif.
            echo "      - \"traefik.http.middlewares.${r}-noref.headers.customrequestheaders.Referer=\""
            mw="${mw},${r}-slash,${r}-strip,${r}-noref"
            ;;
        calibre)
            echo "      - \"traefik.http.middlewares.${r}-hdr.headers.customrequestheaders.X-Script-Name=/calibre\""
            mw="${mw},${r}-hdr"
            ;;
        filebrowser)
            # Connexion unique : utilisateur du routeur (contrôlé par Authelia)
            # dans l'en-tête secret ; toute valeur envoyée par le client est remplacée
            if [ -n "$sso_hdr" ]; then
                echo "      - \"traefik.http.middlewares.${r}-sso.headers.customrequestheaders.${sso_hdr}=${user}\""
                mw="${mw},${r}-sso"
            fi
            # Liens de partage publics (FileBrowser Quantum) : seul chemin servi
            # SANS Authelia ; accès anonyme, en-tête de connexion retiré (valeur vide)
            echo "      - \"traefik.http.routers.${r}-public.rule=Host(\`${host}\`) && PathPrefix(\`${path}/public/\`)\""
            echo "      - \"traefik.http.routers.${r}-public.entrypoints=websecure\""
            echo "      - \"traefik.http.routers.${r}-public.tls.certresolver=letsencrypt\""
            echo "      - \"traefik.http.routers.${r}-public.service=${r}\""
            if [ -n "$sso_hdr" ]; then
                echo "      - \"traefik.http.middlewares.${r}-anon.headers.customrequestheaders.${sso_hdr}=\""
                echo "      - \"traefik.http.routers.${r}-public.middlewares=${r}-anon\""
            fi
            echo "      - \"traefik.http.routers.${r}.service=${r}\""
            # Ancienne adresse /files (Filebrowser d'origine) → /drive
            echo "      - \"traefik.http.routers.${r}-old.rule=Host(\`${host}\`) && PathPrefix(\`/files\`)\""
            echo "      - \"traefik.http.routers.${r}-old.entrypoints=websecure\""
            echo "      - \"traefik.http.routers.${r}-old.tls.certresolver=letsencrypt\""
            echo "      - \"traefik.http.routers.${r}-old.service=${r}\""
            echo "      - \"traefik.http.middlewares.${r}-old.redirectregex.regex=^(https?://[^/]+)/files(.*)\$\$\""
            echo "      - \"traefik.http.middlewares.${r}-old.redirectregex.replacement=\$\${1}${path}\$\${2}\""
            echo "      - \"traefik.http.routers.${r}-old.middlewares=${r}-old\""
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

#######################
# Connexion unique pour qBittorrent et Filebrowser (qui ont leur propre écran
# de connexion) : Authelia a déjà identifié l'utilisateur, Traefik le leur
# transmet, sans ouvrir d'accès aux autres conteneurs (les *arr d'un autre
# utilisateur, par exemple, joignent aussi ces services par le réseau Docker).
#
#  - qBittorrent : dispense de connexion pour la SEULE adresse de Traefik
#    (liste blanche /32), sur un réseau dédié « seedbox_sso » où Traefik a une
#    adresse fixe. Prise en charge du reverse-proxy désactivée : sinon un
#    conteneur pourrait se faire passer pour Traefik (X-Forwarded-For).
#  - FileBrowser Quantum : authentification « proxy » par un en-tête au nom SECRET
#    (SSO_HEADER du .env), posé par Traefik avec le nom de l'utilisateur du
#    routeur (déjà contrôlé par Authelia) ; inconnu des autres conteneurs.
# Sans ces réglages (ancienne installation non migrée), les deux services
# gardent simplement leur mot de passe.
#######################

SSO_NET="seedbox_sso"

_sso_env() { grep "^$1=" "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2-; }
sso_header() { _sso_env SSO_HEADER; }
sso_traefik_ip() { _sso_env TRAEFIK_SSO_IP; }

# Nom secret de l'en-tête Filebrowser (.env, créé une fois)
sso_env_ensure() {
    local env="$INSTALL_DIR/.env"
    [ -f "$env" ] || return 1
    grep -qE '^SSO_HEADER=X-Seedbox-User-[0-9a-f]{24}$' "$env" \
        || echo "SSO_HEADER=X-Seedbox-User-$(openssl rand -hex 12)" >> "$env"
    chmod 600 "$env"
}

# Réseau dédié Traefik ↔ qBittorrent, sur un sous-réseau sans chevauchement
# (réseaux Docker et routes de l'hôte). Adresse fixe de Traefik :
# TRAEFIK_SSO_IP du .env. Idempotent.
sso_net_ensure() {
    local env="$INSTALL_DIR/.env" subnet ip used nets
    sso_env_ensure || return 1
    if ! docker network inspect "$SSO_NET" >/dev/null 2>&1; then
        nets=$(docker network ls -q 2>/dev/null)
        # shellcheck disable=SC2086  # un argument par réseau
        used=$( { [ -n "$nets" ] && docker network inspect $nets -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
                  ip -4 route 2>/dev/null | awk '{print $1}'; } | tr ' ' '\n' | grep / )
        subnet=$(USED="$used" python3 -c '
import ipaddress, os
used = []
for s in os.environ["USED"].split():
    try: used.append(ipaddress.ip_network(s, strict=False))
    except ValueError: pass
for c in ("172.31.254.0/24", "10.254.254.0/24", "192.168.254.0/24", "172.30.254.0/24"):
    n = ipaddress.ip_network(c)
    if not any(n.overlaps(u) for u in used):
        print(c); break')
        [ -n "$subnet" ] || { echo "Aucun sous-réseau libre pour $SSO_NET" >&2; return 1; }
        docker network create --internal --subnet "$subnet" "$SSO_NET" >/dev/null || return 1
    fi
    subnet=$(docker network inspect "$SSO_NET" -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null)
    ip=$(python3 -c 'import ipaddress,sys; print(ipaddress.ip_network(sys.argv[1])[2])' "$subnet" 2>/dev/null)
    [ -n "$ip" ] || return 1
    sed -i '/^TRAEFIK_SSO_IP=/d' "$env"
    echo "TRAEFIK_SSO_IP=$ip" >> "$env"
    chmod 600 "$env"
}

# Ajoute au compose le réseau dédié : déclaration, et Traefik à son adresse
# fixe. Idempotent. $1 = fichier compose. Retour 0 si modifié.
compose_ensure_sso_net() {
    local ip; ip=$(sso_traefik_ip)
    [ -n "$ip" ] || return 1
    SSO_NET="$SSO_NET" SSO_IP="$ip" python3 - "$1" << 'PY'
import os, re, sys
path, net, ip = sys.argv[1], os.environ["SSO_NET"], os.environ["SSO_IP"]
s = open(path).read(); orig = s
# Déclaration dans le bloc networks: de tête
if not re.search(r"^  %s:\n    external: true" % re.escape(net), s, re.M):
    s = re.sub(r"^networks:\n", "networks:\n  %s:\n    external: true\n" % net, s, count=1, flags=re.M)
# Service traefik : réseaux réécrits (traefik_proxy + réseau dédié, adresse fixe)
m = re.search(r"^  traefik:\n(?:(?:    .*|)\n)*?(?=^  \S|^\S|\Z)", s, re.M)
if m:
    block = m.group(0)
    nb = re.sub(r"^    networks:\n(?:      .*\n)+", "", block, count=1, flags=re.M)
    nb = nb.replace("  traefik:\n", "  traefik:\n    networks:\n      traefik_proxy: {}\n"
                    "      %s:\n        ipv4_address: %s\n" % (net, ip), 1)
    s = s.replace(block, nb, 1)
if s != orig:
    open(path, "w").write(s)
    sys.exit(0)
sys.exit(1)
PY
}

# qBittorrent : dispense de connexion pour Traefik seul. $1 = qBittorrent.conf
qbit_sso_configure() {
    local ip; ip=$(sso_traefik_ip)
    [ -n "$ip" ] || return 1
    ini_set "$1" Preferences 'WebUI\AuthSubnetWhitelistEnabled' 'true'
    ini_set "$1" Preferences 'WebUI\AuthSubnetWhitelist' "$ip/32"
    ini_set "$1" Preferences 'WebUI\ReverseProxySupportEnabled' 'false'
}

# FileBrowser Quantum : configuration régénérée (connexion unique par
# l'en-tête) puis conteneur redémarré s'il existe. $1=utilisateur
filebrowser_sso_configure() {
    local user="$1" cfg
    cfg="$INSTALL_DIR/data/users/$user/config/filebrowser"
    [ -n "$(sso_header)" ] || return 1
    fbq_write_config "$cfg/config.yaml" "$user" || return 1
    chown -R "$(id -u "$user"):$(id -g "$user")" "$cfg" 2>/dev/null || true
    docker restart "filebrowser-$user" >/dev/null 2>&1 || true
}
