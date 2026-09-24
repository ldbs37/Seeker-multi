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
