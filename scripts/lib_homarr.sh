#!/bin/bash
#######################
# lib_homarr.sh — Homarr 1.x partagé + connexion unique via Authelia (OIDC)
#
# Mode Traefik uniquement : un seul Homarr sur https://<domaine>, connexion
# automatique par Authelia (fournisseur OIDC, client "homarr") ; chaque
# https://<user>.<domaine>/ y renvoie. En mode port direct (pas d'Authelia
# devant les services), chaque utilisateur garde son Homarr 0.16.
#
# Variables : INSTALL_DIR, DOMAIN. Les secrets sont dans $INSTALL_DIR/.env :
#   HOMARR_SECRET_KEY   clé de chiffrement de Homarr (64 hexa)
#   HOMARR_OIDC_SECRET  secret du client OIDC (en clair ; haché côté Authelia)
#######################

HOMARR_AUTHELIA_IMAGE="authelia/authelia:4.39.28"

# Ajoute les secrets manquants au .env (idempotent, jamais régénérés)
homarr_ensure_env() {
    local env="$INSTALL_DIR/.env"
    [ -f "$env" ] || return 1
    grep -qE '^HOMARR_SECRET_KEY=[0-9a-f]{64}$' "$env" \
        || echo "HOMARR_SECRET_KEY=$(openssl rand -hex 32)" >> "$env"
    grep -qE '^HOMARR_OIDC_SECRET=[0-9a-f]{64}$' "$env" \
        || echo "HOMARR_OIDC_SECRET=$(openssl rand -hex 32)" >> "$env"
    chmod 600 "$env"
}

# Ajoute à la configuration Authelia le fournisseur OIDC et le client Homarr,
# s'ils sont absents. $1 = configuration.yml. Retour 0 si modifiée.
# Validé avec Authelia 4.39 : flux « authorization code » complet, et
# claims_policy pour que groupes/nom/email soient dans l'id_token (Homarr y
# lit les groupes ; Authelia ne les y met plus par défaut).
authelia_ensure_oidc() {
    local cfg="$1" secret hash key hmac
    [ -f "$cfg" ] || return 1
    grep -q '^identity_providers:' "$cfg" && return 1
    secret=$(grep '^HOMARR_OIDC_SECRET=' "$INSTALL_DIR/.env" | cut -d= -f2)
    [ -n "$secret" ] || return 1
    hash=$(docker run --rm "$HOMARR_AUTHELIA_IMAGE" authelia crypto hash generate pbkdf2 \
        --variant sha512 --password "$secret" 2>/dev/null | awk '/Digest:/{print $2}')
    [[ "$hash" == '$pbkdf2-sha512$'* ]] || { echo "hachage du secret OIDC impossible" >&2; return 2; }
    key=$(openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 2>/dev/null | sed 's/^/          /')
    [ -n "$key" ] || return 2
    hmac=$(openssl rand -hex 32)
    cat >> "$cfg" << EOF

# Connexion unique (OIDC) pour Homarr — ajouté par lib_homarr.sh
identity_providers:
  oidc:
    hmac_secret: '${hmac}'
    jwks:
      - key_id: 'seedbox'
        algorithm: 'RS256'
        use: 'sig'
        key: |
${key}
    claims_policies:
      homarr:
        id_token:
          - 'groups'
          - 'email'
          - 'email_verified'
          - 'preferred_username'
          - 'name'
    clients:
      - client_id: 'homarr'
        client_name: 'Homarr'
        client_secret: '${hash}'
        claims_policy: 'homarr'
        public: false
        authorization_policy: 'one_factor'
        consent_mode: 'implicit'
        redirect_uris:
          - 'https://${DOMAIN}/api/auth/callback/oidc'
        scopes:
          - 'openid'
          - 'email'
          - 'profile'
          - 'groups'
        token_endpoint_auth_method: 'client_secret_basic'
EOF
    chmod 600 "$cfg"
    return 0
}

# Groupe personnel « u-<user> » de chaque compte seedbox dans la base Authelia
# (transmis à Homarr à la connexion : droits sur son tableau de bord).
# $1 = users_database.yml. Retour 0 si le fichier a été modifié.
authelia_ensure_user_groups() {
    local db="$1" tmp
    [ -f "$db" ] || return 1
    tmp="$db.tmp"
    awk '
        # Bloc utilisateur : "  nom:" ; ajoute "      - u-nom" sous "    groups:"
        /^  [a-z][a-z0-9]*:[[:space:]]*$/ { user = $1; sub(/:$/, "", user); has = 0 }
        /^    groups:/                     { ingroups = 1; print; next }
        ingroups && /^      - /            { if ($2 == "u-" user) has = 1; print; next }
        ingroups                           { if (!has && user != "") print "      - u-" user; ingroups = 0; changed = 1 }
        { print }
        END {
            if (ingroups && !has && user != "") { print "      - u-" user; changed = 1 }
            exit !changed
        }
    ' "$db" > "$tmp" || { rm -f "$tmp"; return 1; }
    if ! cmp -s "$db" "$tmp"; then
        cat "$tmp" > "$db"; rm -f "$tmp"; return 0
    fi
    rm -f "$tmp"; return 1
}

# Configuration initiale de Homarr, sans intervention (au lieu de l'assistant
# et de la création manuelle d'un jeton d'API). Idempotent :
#   - assistant marqué terminé (Homarr crée seul ses réglages au démarrage) ;
#   - groupe « admins » (nom du groupe Authelia) avec le droit « admin »,
#     comme l'étape « groupe » de l'assistant ; ses membres sont synchronisés
#     depuis Authelia à chaque connexion ;
#   - compte de service « seedbox-api » (admin, sans mot de passe : aucune
#     connexion possible) propriétaire de la clé d'API ;
#   - clé d'API « <id>.<jeton> » (jeton haché en bcrypt, comme Homarr) dans
#     le .env (HOMARR_API_KEY), utilisée par homarr_provision.sh.
# À appeler conteneur homarr démarré au moins une fois (base créée).
# Retour 0 si quelque chose a été configuré.
homarr_bootstrap() {
    local db="$INSTALL_DIR/homarr/appdata/db/db.sqlite" env="$INSTALL_DIR/.env"
    local state key="" kid="" tok="" hash=""
    # Base créée par Homarr à son premier démarrage (jusqu'à 2 min)
    for _ in $(seq 1 60); do
        [ -f "$db" ] && python3 -c 'import sqlite3,sys; sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True).execute("select step from onboarding").fetchone()' "$db" 2>/dev/null && break
        sleep 2
    done
    [ -f "$db" ] || return 1
    key=$(grep '^HOMARR_API_KEY=' "$env" 2>/dev/null | cut -d= -f2-)
    state=$(HM_KEY="$key" python3 - "$db" << 'PY'
import os, sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
todo = []
try:
    step = db.execute("select step from onboarding").fetchone()
    if not step or step[0] != "finish": todo.append("onboarding")
    if not db.execute('select 1 from "groupPermission" where permission = ?', ("admin",)).fetchone(): todo.append("admin")
    if not db.execute('select 1 from "user" where id = ?', ("seedbox-api",)).fetchone(): todo.append("bot")
    kid = os.environ["HM_KEY"].split(".")[0]
    if not kid or not db.execute('select 1 from "apiKey" where id = ?', (kid,)).fetchone(): todo.append("key")
except sqlite3.Error:
    todo = ["erreur"]
print(" ".join(todo))
PY
)
    [ -n "$state" ] || return 1
    [ "$state" = erreur ] && { echo "Base Homarr illisible" >&2; return 2; }
    if [[ " $state " == *" key "* ]]; then
        kid=$(openssl rand -hex 12); tok=$(openssl rand -hex 24)
        # bcrypt coût 10 (comme Homarr) ; préfixe $2y$ d'htpasswd = $2b$
        hash=$(htpasswd -nbBC 10 "" "$tok" 2>/dev/null | cut -d: -f2 | sed 's/^\$2y\$/$2b$/')
        [[ "$hash" == '$2b$10$'* ]] || { echo "Hachage bcrypt impossible (htpasswd)" >&2; return 2; }
    fi
    docker stop homarr >/dev/null 2>&1 || true
    cp -p "$db" "$db.bak-$(date +%Y%m%d%H%M%S)"
    HM_TODO="$state" HM_KID="$kid" HM_HASH="$hash" python3 - "$db" << 'PY'
import os, secrets, sqlite3, sys
db = sqlite3.connect(sys.argv[1]); todo = os.environ["HM_TODO"].split()
if "onboarding" in todo:
    if db.execute("select 1 from onboarding").fetchone():
        db.execute("update onboarding set step = 'finish', previous_step = null")
    else:
        db.execute("insert into onboarding(id, step) values (?, 'finish')", (secrets.token_hex(12),))
row = db.execute('select id from "group" where name = ?', ("admins",)).fetchone()
if row:
    gid = row[0]
else:
    gid = secrets.token_hex(12)
    pos = db.execute('select coalesce(max(position), 0) from "group"').fetchone()[0] + 1
    db.execute('insert into "group"(id, name, position) values (?, ?, ?)', (gid, "admins", pos))
if "admin" in todo:
    db.execute('insert into "groupPermission"(group_id, permission) values (?, ?)', (gid, "admin"))
if "bot" in todo:
    db.execute('insert into "user"(id, name, provider) values (?, ?, ?)', ("seedbox-api", "seedbox-api", "credentials"))
if not db.execute('select 1 from "groupMember" where group_id = ? and user_id = ?', (gid, "seedbox-api")).fetchone():
    db.execute('insert into "groupMember"(group_id, user_id) values (?, ?)', (gid, "seedbox-api"))
if "key" in todo:
    db.execute('insert into "apiKey"(id, api_key, user_id) values (?, ?, ?)',
               (os.environ["HM_KID"], os.environ["HM_HASH"], "seedbox-api"))
db.commit()
PY
    local rc=$?
    docker start homarr >/dev/null 2>&1 || true
    [ "$rc" -eq 0 ] || { echo "Écriture dans la base Homarr échouée (sauvegarde : $db.bak-*)" >&2; return 2; }
    if [ -n "$kid" ]; then
        sed -i '/^HOMARR_API_KEY=/d' "$env"
        echo "HOMARR_API_KEY=$kid.$tok" >> "$env"
        chmod 600 "$env"
    fi
    return 0
}

# Prépare Homarr partagé (secrets + OIDC Authelia). À appeler en mode Traefik,
# après la génération du .env et de la configuration Authelia.
# Retour 0 si la configuration Authelia a changé (redémarrage nécessaire).
homarr_prepare() {
    homarr_ensure_env || return 1
    mkdir -p "$INSTALL_DIR/homarr/appdata"
    authelia_ensure_oidc "$INSTALL_DIR/authelia/configuration.yml"
}
