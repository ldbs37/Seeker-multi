#!/bin/bash
#######################
# lib_compose_base.sh — Services SYSTÈME du docker-compose.yml (source unique)
#
# Utilisée par install.sh, add_service.sh et generate_traefik_labels.sh
# (migration vers Traefik). À sourcer.
#
# Variables : INSTALL_DIR TZ DOMAIN ADMIN_UID ADMIN_GID
#             INSTALL_<SERVICE>=true|false pour les services optionnels.
#
# Sécurité : les interfaces d'administration et FlareSolverr sont publiées sur
# ${ADMIN_BIND:-127.0.0.1} (variable du .env). Par défaut elles ne sont donc
# joignables que localement (et via Traefik + SSO Authelia). Mettre
# ADMIN_BIND=0.0.0.0 dans .env pour les exposer (déconseillé : pas d'auth).
#######################

# Services système retirés par une version précédente (remplacés) : jamais
# conservés comme blocs « personnalisés » lors d'une reconstruction
# (home : redirection nginx, remplacée par le Homarr partagé ; flaresolverr :
# remplacé par un FlareSolverr par utilisateur ayant Prowlarr)
# shellcheck disable=SC2034  # lue par les scripts qui sourcent cette lib
SYSTEM_SERVICES_OBSOLETE="home flaresolverr"
# (Plex et Tautulli ne sont plus proposés : un bloc existant est conservé tel
# quel, comme bloc personnalisé)
SYSTEM_SERVICES="authelia homarr scrutiny uptime-kuma watchtower duplicati jellyfin dashdot portainer"

# Variable INSTALL_* correspondant à un service système optionnel
system_service_flag() {
    case "$1" in
        jellyfin) echo INSTALL_JELLYFIN ;;
        scrutiny) echo INSTALL_SCRUTINY ;;   uptime-kuma) echo INSTALL_UPTIME_KUMA ;;
        watchtower) echo INSTALL_WATCHTOWER ;; duplicati) echo INSTALL_DUPLICATI ;;
        dashdot) echo INSTALL_DASHDOT ;;
        portainer) echo INSTALL_PORTAINER ;;
        *) return 1 ;;
    esac
}

# Positionne les INSTALL_*=true d'après les services présents dans un compose
detect_system_services() {
    local file="$1" s flag
    for s in $SYSTEM_SERVICES; do
        flag=$(system_service_flag "$s") || continue
        if grep -q "^  ${s}:" "$file" 2>/dev/null; then
            printf -v "$flag" '%s' true
        else
            printf -v "$flag" '%s' false
        fi
    done
}

# Réseau + labels Traefik d'un service système. $1=routeur $2=sous-domaine
# $3=port interne $4=protéger par Authelia (true/false)
_sys_labels() {
    local name=$1 sub=$2 port=$3 protect=$4
    echo "    networks:"
    echo "      - traefik_proxy"
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo "      - \"traefik.docker.network=traefik_proxy\""
    echo "      - \"traefik.http.routers.${name}.rule=Host(\`${sub}.${DOMAIN}\`)\""
    echo "      - \"traefik.http.routers.${name}.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.${name}.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.services.${name}.loadbalancer.server.port=${port}\""
    [ "$protect" = "true" ] && echo "      - \"traefik.http.routers.${name}.middlewares=authelia@docker\""
    return 0
}

_block_authelia() {
    cat << 'EOF'

  authelia:
    image: authelia/authelia:4.39.28
    container_name: authelia
    volumes:
      - ./authelia:/config
    environment:
      - TZ=${TZ}
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:9091:9091"
EOF
    # Portail SSO + middleware forward-auth "authelia@docker" utilisé par
    # tous les services protégés (endpoint moderne /api/authz/forward-auth)
    echo "    networks:"
    echo "      - traefik_proxy"
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo "      - \"traefik.docker.network=traefik_proxy\""
    echo "      - \"traefik.http.routers.authelia.rule=Host(\`auth.${DOMAIN}\`)\""
    echo "      - \"traefik.http.routers.authelia.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.authelia.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.services.authelia.loadbalancer.server.port=9091\""
    echo "      - \"traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/authz/forward-auth\""
    echo "      - \"traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true\""
    echo "      - \"traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email\""
    echo "    restart: unless-stopped"
}

# Homarr 1.x partagé sur https://<domaine>, connexion unique
# via Authelia (OIDC, voir lib_homarr.sh). Authelia y redirige après une
# connexion directe (default_redirection_url) ; https://<user>.<domaine>/
# renvoie au tableau de bord de l'utilisateur (routeur de priorité minimale :
# les autres routeurs du même hôte — /qbittorrent, /drive… — et les
# sous-domaines nommés restent prioritaires).
_block_homarr() {
    local re
    # Regex Go : "\." doublé pour YAML, "$$" pour docker-compose
    re='^[a-z][a-z0-9]{0,31}\\.'"$(printf '%s' "$DOMAIN" | sed 's/\./\\\\./g')"'$$'
    cat << 'EOF'

  homarr:
    image: ghcr.io/homarr-labs/homarr:v1.77.2
    container_name: homarr
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
      - SECRET_ENCRYPTION_KEY=${HOMARR_SECRET_KEY}
      - AUTH_PROVIDERS=oidc
      - AUTH_OIDC_ISSUER=https://auth.${DOMAIN}
      - AUTH_OIDC_CLIENT_ID=homarr
      - AUTH_OIDC_CLIENT_SECRET=${HOMARR_OIDC_SECRET}
      - AUTH_OIDC_CLIENT_NAME=Authelia
      - AUTH_OIDC_AUTO_LOGIN=true
      # Déconnexion Homarr → déconnexion Authelia (sinon la connexion
      # automatique reconnecte aussitôt), puis retour à l'accueil
      - AUTH_LOGOUT_REDIRECT_URL=https://auth.${DOMAIN}/logout?rd=https://${DOMAIN}/logout-done
      # Session Homarr courte : si l'on change de compte Authelia sans passer
      # par une déconnexion, Homarr redemande l'identité (reconnexion
      # automatique et invisible via Authelia) au bout d'une heure au plus
      - AUTH_SESSION_EXPIRY_TIME=1h
    volumes:
      - ./homarr/appdata:/appdata
EOF
    echo "    networks:"
    echo "      - traefik_proxy"
    echo "    labels:"
    echo "      - \"traefik.enable=true\""
    echo "      - \"traefik.docker.network=traefik_proxy\""
    echo "      - \"traefik.http.routers.homarr.rule=Host(\`${DOMAIN}\`)\""
    echo "      - \"traefik.http.routers.homarr.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.homarr.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.routers.homarr.middlewares=authelia@docker\""
    echo "      - \"traefik.http.routers.homarr.service=homarr\""
    echo "      - \"traefik.http.services.homarr.loadbalancer.server.port=7575\""
    echo "      - \"traefik.http.routers.user-root.rule=HostRegexp(\`${re}\`) && Path(\`/\`)\""
    echo "      - \"traefik.http.routers.user-root.priority=1\""
    echo "      - \"traefik.http.routers.user-root.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.user-root.tls=true\""
    echo "      - \"traefik.http.routers.user-root.service=homarr\""
    echo "      - \"traefik.http.routers.user-root.middlewares=user-root-redirect\""
    # https://<user>.<domaine>/ → https://<domaine>/boards/<user> (tableau de
    # bord créé par homarr_provision.sh) ; "$$" : docker-compose
    echo "      - \"traefik.http.middlewares.user-root-redirect.redirectregex.regex=^https?://([a-z][a-z0-9]{0,31})\\\\.[^/]+/?\$\$\""
    echo "      - \"traefik.http.middlewares.user-root-redirect.redirectregex.replacement=https://${DOMAIN}/boards/\$\${1}\""
    # Déconnexion : Homarr recharge la page dès que sa session disparaît
    # (SessionQueryScopeGuard), avant d'avoir suivi AUTH_LOGOUT_REDIRECT_URL ;
    # sa connexion automatique repassait alors par Authelia, toujours ouvert.
    # Traefik marque la réponse à la déconnexion (cookie d'une minute) puis
    # renvoie ce rechargement (/ ou /auth/login) vers la déconnexion Authelia,
    # en effaçant le cookie (pas de boucle). Le cookie de marquage remplace
    # ceux de la réponse : sans effet, Homarr supprime la session en base.
    echo "      - \"traefik.http.routers.homarr-signout.rule=Host(\`${DOMAIN}\`) && Method(\`POST\`) && Path(\`/api/auth/signout\`)\""
    echo "      - \"traefik.http.routers.homarr-signout.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.homarr-signout.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.routers.homarr-signout.service=homarr\""
    echo "      - \"traefik.http.routers.homarr-signout.middlewares=authelia@docker,homarr-logout-mark\""
    echo "      - \"traefik.http.middlewares.homarr-logout-mark.headers.customresponseheaders.Set-Cookie=seedbox_logout=1; Path=/; Max-Age=60; Secure; HttpOnly; SameSite=Lax\""
    echo "      - \"traefik.http.routers.homarr-logout.rule=Host(\`${DOMAIN}\`) && (Path(\`/\`) || Path(\`/auth/login\`)) && HeaderRegexp(\`Cookie\`, \`(^|; )seedbox_logout=1\`)\""
    echo "      - \"traefik.http.routers.homarr-logout.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.homarr-logout.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.routers.homarr-logout.service=homarr\""
    echo "      - \"traefik.http.routers.homarr-logout.middlewares=homarr-logout-clear,homarr-logout-redirect\""
    echo "      - \"traefik.http.middlewares.homarr-logout-clear.headers.customresponseheaders.Set-Cookie=seedbox_logout=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax\""
    echo "      - \"traefik.http.middlewares.homarr-logout-redirect.redirectregex.regex=^.*\$\$\""
    echo "      - \"traefik.http.middlewares.homarr-logout-redirect.redirectregex.replacement=https://auth.${DOMAIN}/logout?rd=https://${DOMAIN}/logout-done\""
    # Fin de TOUTE déconnexion (Homarr, VueTorrent, FileBrowser → Authelia →
    # /logout-done) : session Homarr effacée (cookie homarr.session-token,
    # propre à ${DOMAIN}), puis accueil. Sans cela, après un changement de
    # compte Authelia, Homarr gardait la session du compte précédent.
    echo "      - \"traefik.http.routers.logout-done.rule=Host(\`${DOMAIN}\`) && Path(\`/logout-done\`)\""
    echo "      - \"traefik.http.routers.logout-done.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.logout-done.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.routers.logout-done.service=homarr\""
    echo "      - \"traefik.http.routers.logout-done.middlewares=logout-done-clear,logout-done-redirect\""
    echo "      - \"traefik.http.middlewares.logout-done-clear.headers.customresponseheaders.Set-Cookie=homarr.session-token=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Lax\""
    echo "      - \"traefik.http.middlewares.logout-done-redirect.redirectregex.regex=^.*\$\$\""
    # Jellyfin installé : sa session est effacée aussi (maillon suivant)
    local after="https://${DOMAIN}/"
    [ "${INSTALL_JELLYFIN:-false}" = true ] && after="https://jellyfin.${DOMAIN}/logout-done"
    echo "      - \"traefik.http.middlewares.logout-done-redirect.redirectregex.replacement=${after}\""
    echo "    restart: unless-stopped"
}

# Ajoute à une configuration Authelia existante (installations antérieures)
# la règle d'accès de l'accueil et la redirection après connexion.
# $1 = configuration.yml, $2 = domaine. Retour 0 si le fichier a été modifié.
authelia_ensure_home() {
    local cfg="$1" domain="$2"
    [ -f "$cfg" ] || return 1
    AE_DOMAIN="$domain" python3 - "$cfg" << 'PY'
import os, re, sys
path, dom = sys.argv[1], os.environ["AE_DOMAIN"]
s = open(path).read(); orig = s
if not re.search(r"^\s*default_redirection_url:", s, re.M):
    s = re.sub(r"^(\s*)authelia_url: '(https://auth\.[^']+)'\n",
               lambda m: f"{m.group(0)}{m.group(1)}default_redirection_url: 'https://{dom}'\n",
               s, count=1, flags=re.M)
# Règle cherchée uniquement dans access_control (session.cookies contient
# aussi une ligne « - domain: '<domaine>' »)
ac = re.search(r"^access_control:\n(.*?)(?=^\S)", s, re.M | re.S)
if ac and not re.search(r"^\s*- domain: '" + re.escape(dom) + r"'\s*$", ac.group(1), re.M):
    rule = (f"    # Racine du domaine : redirection vers le tableau de bord\n"
            f"    - domain: '{dom}'\n      policy: one_factor\n\n")
    s = re.sub(r"^    - domain_regex:", lambda m: rule + m.group(0), s, count=1, flags=re.M)
# Contrôle d'accès par session uniquement (pas de défi HTTP Basic)
if not re.search(r"^  endpoints:", s, re.M):
    s = re.sub(r"^(server:\n  address: [^\n]*\n)",
               lambda m: m.group(1) + "  endpoints:\n    authz:\n      forward-auth:\n"
               "        implementation: 'ForwardAuth'\n        authn_strategies:\n"
               "          - name: 'CookieSession'\n",
               s, count=1, flags=re.M)
# Sessions trop courtes des anciennes installations (1 h / 5 min d'inactivité)
s = s.replace("  expiration: 1h\n  inactivity: 5m\n",
              "  expiration: 12h\n  inactivity: 2h\n  remember_me: 1M\n", 1)
if s != orig:
    open(path, "w").write(s)
    sys.exit(0)
sys.exit(1)
PY
}

_block_scrutiny() {
    # privileged + /run/udev : accès à tous les disques (pas de liste de
    # périphériques figée, qui échouerait sur NVMe ou mono-disque)
    cat << 'EOF'

  scrutiny:
    image: ghcr.io/analogj/scrutiny:master-omnibus
    container_name: scrutiny
    privileged: true
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:8080:8080"
    volumes:
      - ./scrutiny/config:/opt/scrutiny/config
      - ./scrutiny/influxdb:/opt/scrutiny/influxdb
      - /run/udev:/run/udev:ro
    cap_add:
      - SYS_RAWIO
      - SYS_ADMIN
    environment:
      - TZ=${TZ}
EOF
    _sys_labels scrutiny scrutiny 8080 true
    echo "    restart: unless-stopped"
}

_block_uptime_kuma() {
    cat << 'EOF'

  uptime-kuma:
    image: louislam/uptime-kuma:2.5.5
    container_name: uptime-kuma
    volumes:
      - ./uptime-kuma:/app/data
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:3001:3001"
    environment:
      - TZ=${TZ}
EOF
    _sys_labels uptime-kuma uptime 3001 true
    echo "    restart: unless-stopped"
}

_block_watchtower() {
    cat << 'EOF'

  watchtower:
    image: nickfedor/watchtower:1.22.3
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
      - TZ=${TZ}
    restart: unless-stopped
EOF
}

_block_duplicati() {
    cat << 'EOF'

  duplicati:
    image: linuxserver/duplicati:2.4.0
    container_name: duplicati
    environment:
      # root : lit toute la configuration (.env, Authelia… en 600 root) ;
      # accès réservé aux admins (Authelia) + mot de passe Duplicati
      - PUID=0
      - PGID=0
      - TZ=${TZ}
      # Duplicati 2.1+ : sans clé de chiffrement des réglages, une nouvelle
      # installation reste bloquée au démarrage (Bad Gateway) ; secrets du .env
      - SETTINGS_ENCRYPTION_KEY=${DUPLICATI_ENCRYPTION_KEY}
      - DUPLICATI__WEBSERVICE_PASSWORD=${DUPLICATI_PASSWORD}
      - DUPLICATI__WEBSERVICE_ALLOWED_HOSTNAMES=duplicati.${DOMAIN}
    volumes:
      - ./duplicati/config:/config
      - ./data:/source:ro
      # Configuration de la seedbox (sauvegarde « Configuration seedbox »)
      - .:/seedbox:ro
      # Destination locale des sauvegardes (« /backups » dans Duplicati) ;
      # préférer une destination distante (autre serveur, stockage en ligne)
      - ./duplicati/backups:/backups
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:8200:8200"
EOF
    _sys_labels duplicati duplicati 8200 true
    echo "    restart: unless-stopped"
}

_block_jellyfin() {
    # Serveur média public (authentification propre, applis natives) :
    # ports volontairement exposés, pas de SSO Authelia
    cat << 'EOF'

  jellyfin:
    image: jellyfin/jellyfin:12.1
    container_name: jellyfin
    user: "${ADMIN_UID}:${ADMIN_GID}"
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - ./data:/media:ro
    ports:
      - "8096:8096"
      - "7359:7359/udp"
      - "1900:1900/udp"
    environment:
      - TZ=${TZ}
EOF
    _sys_labels jellyfin jellyfin 8096 false
    # Maillon de la chaîne de déconnexion (voir _block_homarr) : session
    # Jellyfin (stockage du navigateur sur jellyfin.<domaine>) effacée par
    # l'en-tête standard Clear-Site-Data, puis retour à l'accueil
    echo "      - \"traefik.http.routers.jellyfin-logout-done.rule=Host(\`jellyfin.${DOMAIN}\`) && Path(\`/logout-done\`)\""
    echo "      - \"traefik.http.routers.jellyfin-logout-done.entrypoints=websecure\""
    echo "      - \"traefik.http.routers.jellyfin-logout-done.tls.certresolver=letsencrypt\""
    echo "      - \"traefik.http.routers.jellyfin-logout-done.service=jellyfin\""
    echo "      - \"traefik.http.routers.jellyfin-logout-done.middlewares=jellyfin-logout-clear,jellyfin-logout-redirect\""
    echo "      - \"traefik.http.middlewares.jellyfin-logout-clear.headers.customresponseheaders.Clear-Site-Data=\\\"storage\\\"\""
    echo "      - \"traefik.http.middlewares.jellyfin-logout-redirect.redirectregex.regex=^.*\$\$\""
    echo "      - \"traefik.http.middlewares.jellyfin-logout-redirect.redirectregex.replacement=https://${DOMAIN}/\""
    echo "      - \"traefik.http.routers.jellyfin.service=jellyfin\""
    echo "    restart: unless-stopped"
}

_block_dashdot() {
    cat << 'EOF'

  dashdot:
    image: mauricenino/dashdot:6.3.4
    container_name: dashdot
    privileged: true
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:3002:3001"
    volumes:
      - ./dashdot:/data
      - /:/mnt/host:ro
    environment:
      - TZ=${TZ}
      - DASHDOT_ENABLE_CPU_TEMPS=true
EOF
    # Disque système : Dash. calcule mal son espace utilisé (vu sur un disque
    # virtuel de contrôleur RAID : 1,99 To « utilisés » pour 17 Go) ; il
    # affiche à la place la partition système telle que la voit df
    local root_src root_disk
    root_src=$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')
    root_disk=$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1)
    if [[ "$root_src" =~ ^/dev/[A-Za-z0-9/_.-]+$ ]] && [[ "$root_disk" =~ ^[A-Za-z0-9_.-]+$ ]]; then
        echo "      - DASHDOT_FS_VIRTUAL_MOUNTS=${root_src}"
        echo "      - DASHDOT_FS_DEVICE_FILTER=${root_disk}"
    fi
    _sys_labels dashdot dashdot 3001 true
    echo "    restart: unless-stopped"
}

_block_portainer() {
    cat << 'EOF'

  portainer:
    image: portainer/portainer-ce:2.45.1
    container_name: portainer
    ports:
      - "${ADMIN_BIND:-127.0.0.1}:9000:9000"
    volumes:
      - ./portainer:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=${TZ}
EOF
    _sys_labels portainer portainer 9000 true
    echo "    restart: unless-stopped"
}

# Secrets de Duplicati dans le .env (créés une fois, conservés ensuite par
# write_env_file) : clé de chiffrement des réglages, mot de passe de
# l'interface (en plus d'Authelia)
duplicati_env_ensure() {
    local env="$INSTALL_DIR/.env"
    grep -q '^DUPLICATI_ENCRYPTION_KEY=.' "$env" 2>/dev/null \
        || echo "DUPLICATI_ENCRYPTION_KEY=$(openssl rand -hex 32)" >> "$env"
    grep -q '^DUPLICATI_PASSWORD=.' "$env" 2>/dev/null \
        || echo "DUPLICATI_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)" >> "$env"
    # Phrase de chiffrement des sauvegardes (indispensable pour restaurer)
    grep -q '^DUPLICATI_BACKUP_PASSPHRASE=.' "$env" 2>/dev/null \
        || echo "DUPLICATI_BACKUP_PASSPHRASE=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-28)" >> "$env"
    chmod 600 "$env"
}

# Crée les dossiers de données des services système sélectionnés
_system_dirs() {
    mkdir -p "$INSTALL_DIR/authelia" "$INSTALL_DIR/data/users"
    mkdir -p "$INSTALL_DIR/homarr/appdata"
    [ "${INSTALL_SCRUTINY:-false}" = true ]    && mkdir -p "$INSTALL_DIR/scrutiny/config" "$INSTALL_DIR/scrutiny/influxdb"
    [ "${INSTALL_UPTIME_KUMA:-false}" = true ] && mkdir -p "$INSTALL_DIR/uptime-kuma"
    if [ "${INSTALL_DUPLICATI:-false}" = true ]; then
        mkdir -p "$INSTALL_DIR/duplicati/config" "$INSTALL_DIR/duplicati/backups"
        chown "${ADMIN_UID}:${ADMIN_GID}" "$INSTALL_DIR/duplicati/backups" 2>/dev/null || true
        duplicati_env_ensure
    fi
    [ "${INSTALL_DASHDOT:-false}" = true ]     && mkdir -p "$INSTALL_DIR/dashdot"
    [ "${INSTALL_PORTAINER:-false}" = true ]   && mkdir -p "$INSTALL_DIR/portainer"
    if [ "${INSTALL_JELLYFIN:-false}" = true ]; then
        mkdir -p "$INSTALL_DIR/jellyfin/config" "$INSTALL_DIR/jellyfin/cache"
        chown -R "${ADMIN_UID}:${ADMIN_GID}" "$INSTALL_DIR/jellyfin" 2>/dev/null || true
    fi
    return 0
}

# Émet (stdout) l'en-tête et les services système sélectionnés
compose_base_content() {
    printf 'networks:\n'
    # Réseau de la connexion unique qBittorrent (lib_traefik.sh), s'il existe
    grep -q '^TRAEFIK_SSO_IP=' "$INSTALL_DIR/.env" 2>/dev/null \
        && printf '  seedbox_sso:\n    external: true\n'
    printf '  traefik_proxy:\n    external: true\n\n'
    echo "services:"
    _block_authelia
    _block_homarr
    [ "${INSTALL_SCRUTINY:-false}" = true ]    && _block_scrutiny
    [ "${INSTALL_UPTIME_KUMA:-false}" = true ] && _block_uptime_kuma
    [ "${INSTALL_WATCHTOWER:-false}" = true ]  && _block_watchtower
    [ "${INSTALL_DUPLICATI:-false}" = true ]   && _block_duplicati
    [ "${INSTALL_JELLYFIN:-false}" = true ]    && _block_jellyfin
    [ "${INSTALL_DASHDOT:-false}" = true ]     && _block_dashdot
    [ "${INSTALL_PORTAINER:-false}" = true ]   && _block_portainer
    return 0
}

# Écrit le .env (USE_TRAEFIK=true : marque une installation Traefik, seul
# mode pris en charge ; voir traefik_require)
write_env_file() {
    local admin_bind="127.0.0.1"
    if [ -f "$INSTALL_DIR/.env" ] && grep -q '^ADMIN_BIND=' "$INSTALL_DIR/.env"; then
        admin_bind=$(grep '^ADMIN_BIND=' "$INSTALL_DIR/.env" | cut -d'=' -f2)
    fi
    local extra="" lang="${SEEDBOX_LANG:-}"
    # Langue des interfaces (lib_lang.sh) : choisie à l'installation, conservée ensuite
    [ -n "$lang" ] || lang=$(grep '^SEEDBOX_LANG=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d'=' -f2)
    # Autres clés (ex. SEEDBOX_API_KEY de setup_api.sh) conservées telles quelles
    if [ -f "$INSTALL_DIR/.env" ]; then
        extra=$(grep -vE '^(TZ|DOMAIN|ADMIN_UID|ADMIN_GID|USE_TRAEFIK|ADMIN_BIND|SEEDBOX_LANG)=' "$INSTALL_DIR/.env" | grep -E '^[A-Z_][A-Z0-9_]*=' || true)
    fi
    cat > "$INSTALL_DIR/.env" << EOF
TZ=$TZ
DOMAIN=$DOMAIN
ADMIN_UID=$ADMIN_UID
ADMIN_GID=$ADMIN_GID
USE_TRAEFIK=true
ADMIN_BIND=$admin_bind
SEEDBOX_LANG=${lang:-fr}
EOF
    [ -z "$extra" ] || printf '%s\n' "$extra" >> "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"
}

# Génère le docker-compose.yml de base (+ .env). $1 = fichier de sortie
# (défaut : $INSTALL_DIR/docker-compose.yml)
generate_docker_compose() {
    local out="${1:-$INSTALL_DIR/docker-compose.yml}"
    log "Génération de la configuration Docker..."
    _system_dirs
    compose_base_content > "$out"
    write_env_file
    log "✓ Configuration Docker générée"
}

# Extrait (stdout) les blocs verbatim des services nommés d'un compose,
# dans l'ordre du fichier. $1=fichier, $2..=noms de services
compose_extract_blocks() {
    local file="$1"; shift
    awk -v names="$*" '
        BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) want[a[i] ":"] = 1 }
        /^  [^ #]/ { keep = ($1 in want); if (keep) print "" }
        /^[^ ]/    { keep = 0 }
        keep && !/^$/ { print }
    ' "$file"
}

# Liste des noms de services d'un compose (clés sous "services:")
compose_service_names() {
    awk '/^services:/{s=1;next} /^[^ ]/{s=0} s && /^  [^ #]/{sub(":$","",$1); print $1}' "$1"
}
