#!/bin/bash
#######################
# lib_calibre.sh — Calibre-web d'un utilisateur, configuré automatiquement
# (mode Traefik) :
# - connexion unique : Traefik transmet le nom de l'utilisateur (contrôlé par
#   Authelia) dans l'en-tête secret SSO_HEADER ; le compte administrateur
#   par défaut (« admin », mot de passe public admin123) est renommé au nom de
#   l'utilisateur et reçoit un mot de passe aléatoire ;
# - bibliothèque : /books (data/users/<user>/books), créée vide si besoin
#   (schéma officiel de Calibre, version épinglée, empreinte vérifiée).
# Vérifié sur Calibre-web 0.6.27. Idempotent.
#
# Variables : INSTALL_DIR ; fonctions de lib_traefik.sh (sso_header).
#######################

CALIBRE_SCHEMA_VERSION="v9.15.0"
CALIBRE_SCHEMA_SHA256="51078b49bb966a21e9d1eb6ad20925650f0ef91b40a50c966f61cf81b6bb3cb7"

# Schéma SQL d'une bibliothèque Calibre (téléchargé une fois). Affiche le chemin.
calibre_schema() {
    local f="$INSTALL_DIR/calibre/metadata_sqlite-${CALIBRE_SCHEMA_VERSION}.sql"
    if ! echo "$CALIBRE_SCHEMA_SHA256  $f" | sha256sum -c --quiet - >/dev/null 2>&1; then
        mkdir -p "$INSTALL_DIR/calibre"
        curl -fsSL -m 60 -o "$f.tmp" \
            "https://raw.githubusercontent.com/kovidgoyal/calibre/${CALIBRE_SCHEMA_VERSION}/resources/metadata_sqlite.sql" \
            && echo "$CALIBRE_SCHEMA_SHA256  $f.tmp" | sha256sum -c --quiet - >/dev/null 2>&1 \
            && mv "$f.tmp" "$f" || { rm -f "$f.tmp"; return 1; }
    fi
    echo "$f"
}

# Bibliothèque vide dans $1 (dossier des livres) si elle n'existe pas.
# $2 = uid:gid propriétaire
calibre_library_ensure() {
    local dir="$1" owner="$2" schema
    [ -f "$dir/metadata.db" ] && return 0
    schema=$(calibre_schema) || return 1
    mkdir -p "$dir"
    python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[2]); c.executescript(open(sys.argv[1]).read()); c.commit()' \
        "$schema" "$dir/metadata.db" || { rm -f "$dir/metadata.db"; return 1; }
    chown "$owner" "$dir/metadata.db" 2>/dev/null || true
}

# Réglages de Calibre-web (app.db, créé au premier démarrage) : conteneur
# arrêté pendant l'écriture. $1=utilisateur
calibre_configure() {
    local user="$1" db="$INSTALL_DIR/calibre/$1/app.db" hdr owner state
    hdr=$(sso_header); [ -n "$hdr" ] || return 1
    for _ in $(seq 1 30); do [ -s "$db" ] && break; sleep 2; done
    [ -s "$db" ] || return 1
    owner="$(id -u "$user"):$(id -g "$user")"
    calibre_library_ensure "$INSTALL_DIR/data/users/$user/books" "$owner" || return 1
    # Déjà configuré ? (sinon arrêt, écriture, redémarrage)
    state=$(python3 -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
s = c.execute("select config_allow_reverse_proxy_header_login, config_reverse_proxy_login_header_name, config_calibre_dir from settings").fetchone()
u = c.execute("select name from user where id = 1").fetchone()
print("ok" if s and s[0] == 1 and s[1] == sys.argv[2] and s[2] == "/books" and u and u[0] == sys.argv[3] else "todo")' \
        "$db" "$hdr" "$user" 2>/dev/null)
    [ "$state" = ok ] && return 0
    docker stop "calibre-$user" >/dev/null 2>&1 || true
    CW_PW="$(openssl rand -hex 24)" python3 -c 'import hashlib, os, sqlite3, sys
db, hdr, user = sys.argv[1:4]
salt = os.urandom(12).hex(); it = 600000
h = "pbkdf2:sha256:%d$%s$%s" % (it, salt, hashlib.pbkdf2_hmac("sha256", os.environ["CW_PW"].encode(), salt.encode(), it).hex())
c = sqlite3.connect(db)
c.execute("update settings set config_allow_reverse_proxy_header_login = 1, "
          "config_reverse_proxy_login_header_name = ?, config_calibre_dir = ?", (hdr, "/books"))
# Compte administrateur par défaut (admin / admin123) : nom de l utilisateur,
# mot de passe aléatoire (la connexion passe par Authelia)
if c.execute("select name from user where id = 1").fetchone()[0] != user:
    c.execute("update user set name = ?, password = ? where id = 1", (user, h))
c.commit()' "$db" "$hdr" "$user" || { docker start "calibre-$user" >/dev/null 2>&1; return 1; }
    docker start "calibre-$user" >/dev/null 2>&1 || true
}
