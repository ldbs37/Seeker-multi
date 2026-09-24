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

# Prépare Homarr partagé (secrets + OIDC Authelia). À appeler en mode Traefik,
# après la génération du .env et de la configuration Authelia.
# Retour 0 si la configuration Authelia a changé (redémarrage nécessaire).
homarr_prepare() {
    homarr_ensure_env || return 1
    mkdir -p "$INSTALL_DIR/homarr/appdata"
    authelia_ensure_oidc "$INSTALL_DIR/authelia/configuration.yml"
}
