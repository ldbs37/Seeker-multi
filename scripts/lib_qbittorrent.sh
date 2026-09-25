#!/bin/bash
#######################
# lib_qbittorrent.sh — Identifiants et configuration qBittorrent
#
# qBittorrent stocke le mot de passe WebUI sous la forme :
#   WebUI\Password_PBKDF2="@ByteArray(<sel_b64>:<hash_b64>)"
# avec PBKDF2-HMAC-SHA512, 100 000 itérations, sel aléatoire de 16 octets,
# clé de 64 octets (cf. src/base/utils/password.cpp de qBittorrent).
#
# À sourcer : source "$(dirname "$0")/lib_qbittorrent.sh"
# Le conteneur doit être ARRÊTÉ pendant l'écriture (qBittorrent réécrit sa
# configuration en quittant).
#######################

# Hash PBKDF2 au format qBittorrent. Le mot de passe est passé par variable
# d'environnement (jamais interpolé dans du code ni visible dans `ps`).
# $1 = mot de passe ; stdout = @ByteArray(...)
qbit_hash() {
    if command -v python3 >/dev/null 2>&1; then
        QB_PW="$1" python3 - << 'PY'
import base64, hashlib, os
salt = os.urandom(16)
dk = hashlib.pbkdf2_hmac('sha512', os.environ['QB_PW'].encode('utf-8'), salt, 100000, 64)
print('@ByteArray(%s:%s)' % (base64.b64encode(salt).decode(), base64.b64encode(dk).decode()))
PY
    else
        # Repli OpenSSL 3 (le mot de passe transite en argument : moins discret)
        local salt_hex salt_b64 dk_b64
        salt_b64=$(openssl rand -base64 16) || return 1
        salt_hex=$(printf '%s' "$salt_b64" | base64 -d | od -An -tx1 | tr -d ' \n') || return 1
        dk_b64=$(openssl kdf -keylen 64 -binary -kdfopt digest:SHA512 \
                 -kdfopt "pass:$1" -kdfopt "hexsalt:$salt_hex" -kdfopt iter:100000 PBKDF2 | base64 -w0) || return 1
        echo "@ByteArray(${salt_b64}:${dk_b64})"
    fi
}

# Définit (ou remplace) une clé dans une section d'un fichier INI.
# Clés/valeurs passées via l'environnement : aucune interprétation des "\"
# (les clés qBittorrent contiennent des antislashs : WebUI\Username).
# $1=fichier $2=section (ex: Preferences) $3=clé $4=valeur
ini_set() {
    local file="$1"
    [ -f "$file" ] || : > "$file"
    INI_SEC="[$2]" INI_KEY="$3" INI_VAL="$4" awk '
        BEGIN { sec=ENVIRON["INI_SEC"]; k=ENVIRON["INI_KEY"]; v=ENVIRON["INI_VAL"]; insec=0; done=0 }
        $0 == sec { print; insec=1; next }
        /^\[/ { if (insec && !done) { print k "=" v; done=1 } insec=0; print; next }
        insec && index($0, k "=") == 1 { if (!done) { print k "=" v; done=1 } next }
        { print }
        END { if (!done) { if (!insec) { print ""; print sec } print k "=" v } }
    ' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# Crée qBittorrent.conf s'il n'existe pas, avec les valeurs par défaut de
# l'image linuxserver (qu'elle ne copie PAS si le fichier existe déjà) —
# notamment [LegalNotice] Accepted=true, sans quoi qBittorrent 5 refuse de
# démarrer. Téléchargements dans /data/downloads (montage unique /data partagé
# avec les *arr : les imports se font par hardlink, sans doubler l'espace).
# $1=fichier qBittorrent.conf
qbit_seed_defaults() {
    local conf="$1"
    [ -f "$conf" ] && return 0
    mkdir -p "$(dirname "$conf")"
    cat > "$conf" << 'CONF'
[AutoRun]
enabled=false
program=

[LegalNotice]
Accepted=true

[Preferences]
Connection\UPnP=false
Downloads\SavePath=/data/downloads/
Downloads\TempPath=/data/downloads/incomplete/
WebUI\Address=*
WebUI\ServerDomains=*
CONF
}

# Écrit les identifiants WebUI (et réglages proxy) dans qBittorrent.conf.
# $1=fichier qBittorrent.conf  $2=utilisateur  $3=mot de passe
# $4=(optionnel) sous-réseau du reverse-proxy à approuver (ex: 172.18.0.0/16)
qbit_configure() {
    local conf="$1" user="$2" pass="$3" proxy_net="${4:-}" hash
    mkdir -p "$(dirname "$conf")"
    hash=$(qbit_hash "$pass") || return 1
    [ -n "$hash" ] || return 1
    ini_set "$conf" Preferences 'WebUI\Username' "$user"
    ini_set "$conf" Preferences 'WebUI\Password_PBKDF2' "\"$hash\""
    if [ -n "$proxy_net" ]; then
        # Derrière Traefik : utiliser l'IP réelle du client (X-Forwarded-For),
        # sinon trop d'échecs de connexion d'un utilisateur banniraient l'IP
        # de Traefik pendant 1 h.
        ini_set "$conf" Preferences 'WebUI\ReverseProxySupportEnabled' 'true'
        ini_set "$conf" Preferences 'WebUI\TrustedReverseProxiesList' "$proxy_net"
    fi
}

#######################
# VueTorrent : interface web moderne de qBittorrent (interface « alternative »)
#
# Une copie partagée, version épinglée et empreinte vérifiée, dans
# $INSTALL_DIR/vuetorrent, montée en lecture seule sur /vuetorrent dans
# chaque qBittorrent (plutôt que le mod Docker, qui la retélécharge à chaque
# démarrage). Chemins relatifs : fonctionne sous /qbittorrent (Traefik).
#######################

VUETORRENT_VERSION="2.35.0"
VUETORRENT_SHA256="6e0c0e6acb563710aaf32cd165cf34da0e5d61bc1a68386e4cf97a648fa8171c"

# Installe (ou met à jour) VueTorrent si nécessaire. Retour 0 si disponible.
vuetorrent_ensure() {
    local dir="$INSTALL_DIR/vuetorrent" tmp
    [ "$(cat "$dir/version.txt" 2>/dev/null)" = "$VUETORRENT_VERSION" ] && [ -d "$dir/public" ] && return 0
    tmp=$(mktemp -d) || return 1
    if curl -fsSL -m 120 -o "$tmp/vuetorrent.zip" \
            "https://github.com/VueTorrent/VueTorrent/releases/download/v${VUETORRENT_VERSION}/vuetorrent.zip" \
        && echo "$VUETORRENT_SHA256  $tmp/vuetorrent.zip" | sha256sum -c --quiet - >/dev/null 2>&1 \
        && unzip -q "$tmp/vuetorrent.zip" -d "$tmp" && [ -d "$tmp/vuetorrent/public" ]; then
        rm -rf "${dir:?}.new"
        mv "$tmp/vuetorrent" "$dir.new" && chmod -R a+rX "$dir.new"
        rm -rf "${dir:?}.old"; [ -d "$dir" ] && mv "$dir" "$dir.old"
        mv "$dir.new" "$dir" && rm -rf "${dir:?}.old"
        rm -rf "${tmp:?}"
        vuetorrent_set_defaults || true
        return 0
    fi
    rm -rf "${tmp:?}"
    [ -d "$dir/public" ]    # version précédente encore utilisable
}

# Réglages par défaut de VueTorrent, gardés dans le navigateur (clé
# vuetorrent_webuiSettings) : script inséré dans index.html de la copie
# partagée (idempotent, remplacé à chaque appel), qui complète ce qui manque
# sans toucher au reste :
#  - langue (lib_lang.sh), au premier chargement seulement ; chacun la
#    change ensuite dans VueTorrent ;
#  - mode Traefik : bouton « Déconnexion » → déconnexion Authelia puis
#    accueil (sinon Authelia, toujours connecté, rouvre aussitôt qBittorrent).
vuetorrent_set_defaults() {
    local html="$INSTALL_DIR/vuetorrent/public/index.html" domain="" logout=""
    [ -f "$html" ] || return 1
    if grep -q '^USE_TRAEFIK=true' "$INSTALL_DIR/.env" 2>/dev/null; then
        domain=$(grep '^DOMAIN=' "$INSTALL_DIR/.env" | cut -d= -f2)
        [ -n "$domain" ] && logout="https://auth.${domain}/logout?rd=https://${domain}/"
    fi
    VT_LANG="$(seedbox_lang)" VT_LOGOUT="$logout" python3 -c '
import json, os, re, sys
p = sys.argv[1]; s = open(p, encoding="utf-8").read()
s = re.sub(r"<!-- seedbox-(lang|defaults) -->.*?<!-- /seedbox-(lang|defaults) -->", "", s, flags=re.S)
js = ("try{var k=\"vuetorrent_webuiSettings\",v=localStorage.getItem(k),o=v?JSON.parse(v):{};"
      "if(!v)o.language=%s;var u=%s;if(u&&!o.logoutUrl)o.logoutUrl=u;"
      "localStorage.setItem(k,JSON.stringify(o))}catch(e){}"
      % (json.dumps(os.environ["VT_LANG"]), json.dumps(os.environ["VT_LOGOUT"])))
s = s.replace("<head>", "<head><!-- seedbox-defaults --><script>" + js + "</script><!-- /seedbox-defaults -->", 1)
open(p, "w", encoding="utf-8").write(s)' "$html"
}

# qBittorrent : langue de l'interface d'origine et des messages. $1 = conf
qbit_lang_configure() {
    ini_set "$1" Preferences 'General\Locale' "$(seedbox_lang)"
}

# qBittorrent : VueTorrent comme interface web (conteneur arrêté).
# $1 = qBittorrent.conf
qbit_vuetorrent_configure() {
    [ -d "$INSTALL_DIR/vuetorrent/public" ] || return 1
    ini_set "$1" Preferences 'WebUI\AlternativeUIEnabled' 'true'
    ini_set "$1" Preferences 'WebUI\RootFolder' '/vuetorrent'
}
