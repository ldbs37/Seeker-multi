#!/bin/bash
#######################
# lib_filebrowser.sh — FileBrowser Quantum (gestion de fichiers + partages)
#
# Remplace Filebrowser (projet archivé le 2026-09-01, sans correctifs de
# sécurité). Une instance par utilisateur, sur ses fichiers (/srv =
# data/users/<user>), exécutée avec son UID ; configuration générée dans
# data/users/<user>/config/filebrowser/config.yaml (monté sur
# /home/filebrowser/data, avec la base et le cache des aperçus).
#
# Mode Traefik : connexion unique par l'en-tête secret posé par Traefik après
# Authelia (auth « proxy », voir lib_traefik.sh) ; mot de passe désactivé.
# Servi sous https://<user>.<domaine>/drive (l'appli ajoute /files/<source>
# à ses propres adresses). Liens de partage publics sous …/drive/public/…,
# seul chemin servi sans Authelia (routeur dédié, lib_traefik.sh).
# Mode port direct : connexion par mot de passe (identifiants seedbox).
#
# Versions 1.x et 2.x : format de configuration et base différents (v2 :
# section « http », base SQLite database.sqlite importée de l'ancienne
# database.db, droits sur les fichiers par source). Le format suit la version
# de l'image de l'utilisateur (fbq_image : celle de $INSTALL_DIR/image_overrides
# pendant un essai test_update.sh, sinon FBQ_IMAGE).
#######################

# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
FBQ_IMAGE="gtstef/filebrowser:1.5.8-stable"
FBQ_PORT=8080

# Valeur hexadécimale d'une clé « clé: "valeur" » de la section auth d'un config.yaml
# existant (secrets conservés d'une génération à l'autre). $1=fichier $2=clé
_fbq_get() { sed -n "s/^  $2: \"\\([0-9a-f]*\\)\"$/\\1/p" "$1" 2>/dev/null | head -1; }

# Image FileBrowser de l'utilisateur $1 (version imposée par un essai, sinon FBQ_IMAGE)
fbq_image() {
    local img
    img=$(sed -n "s/^filebrowser-$1=//p" "${INSTALL_DIR:-/opt/seedbox}/image_overrides" 2>/dev/null | tail -1)
    echo "${img:-$FBQ_IMAGE}"
}

# Version majeure de l'image $1 (« gtstef/filebrowser:2.0.1-stable » → 2)
fbq_major() { local t="${1##*:}"; t="${t#v}"; echo "${t%%.*}"; }

# Écrit la configuration d'une instance. Idempotent (secrets conservés).
# $1=fichier config.yaml $2=utilisateur [$3=mot de passe seedbox]
# Variables : DOMAIN ; en-tête : sso_header (lib_traefik.sh)
#
# Compte de l'utilisateur = administrateur de SON instance (adminUsername).
#  - Connexion unique (en-tête) : compte créé à sa première visite ;
#    adminPassword aléatoire, jamais utilisé.
#  - Mot de passe (repli, en-tête pas encore créé) : FileBrowser réapplique adminPassword à
#    chaque démarrage ; c'est donc le mot de passe seedbox (fichier en 600),
#    réécrit par update_password.sh. Sans $3, la valeur existante est gardée.
fbq_write_config() {
    local file="$1" user="$2" pass="${3:-}" key adminpw header="" base="/" ext="" auth lock=false major
    mkdir -p "$(dirname "$file")"
    key=$(_fbq_get "$file" key); [ -n "$key" ] || key=$(openssl rand -hex 32)
    # externalUrl avec le chemin de base : sinon lien de partage en « //drive »
    base=$(traefik_service_path filebrowser); ext="https://${user}.${DOMAIN}${base}"
    header=$(sso_header 2>/dev/null || true)
    if [ -n "$header" ]; then
        adminpw="\"$(openssl rand -hex 24)\""
        auth="    password:
      enabled: false
    proxy:
      enabled: true
      header: \"${header}\"
      logoutRedirectUrl: \"https://auth.${DOMAIN}/logout?rd=https://${DOMAIN}/logout-done\""
    else
        # YAML entre apostrophes : seule « ' » est à doubler
        if [ -n "$pass" ]; then adminpw="'${pass//\'/\'\'}'"
        else adminpw=$(sed -n 's/^  adminPassword: //p' "$file" 2>/dev/null | head -1); fi
        [ -n "$adminpw" ] || adminpw="\"$(openssl rand -hex 24)\""
        lock=true
        auth="    password:
      enabled: true
      minLength: ${PASSWORD_MIN_LEN:-12}
      signup: false"
    fi
    major=$(fbq_major "$(fbq_image "$user")")
    if [ "${major:-1}" -ge 2 ] 2>/dev/null; then
        _fbq_write_v2 "$file" "$user" "$base" "$ext" "$key" "$adminpw" "$auth" "$lock"
    else
        _fbq_write_v1 "$file" "$user" "$base" "$ext" "$key" "$adminpw" "$auth" "$lock"
    fi
    chmod 600 "$file"
}

# Préférences communes aux deux versions (section userDefaults)
_fbq_user_defaults() {
    cat << EOF
  preview:
    image: true
    video: true
    audio: true
    motionVideoPreview: true
    office: true
    popup: true
    highQuality: true
    folder: true
  ui:
    darkMode: true
    locale: "$(seedbox_lang)"
  listing:
    viewMode: "normal"
EOF
}

# Format 1.x. $1=fichier $2=utilisateur $3=chemin de base $4=adresse externe
# $5=clé $6=adminPassword (YAML) $7=méthodes de connexion $8=lockPassword
_fbq_write_v1() {
    cat > "$1" << EOF
# Généré par lib_filebrowser.sh (seedbox) — régénéré par les scripts :
# les modifications manuelles peuvent être écrasées.
server:
  port: ${FBQ_PORT}
  baseURL: "$3"
  externalUrl: "$4"
  database: "/home/filebrowser/data/database.db"
  cacheDir: "/home/filebrowser/data/cache"
  disableUpdateCheck: true
  logging:
    - levels: "info|warning|error"
  sources:
    - path: "/srv"
      name: "$2"
      config:
        defaultEnabled: true
frontend:
  name: "Fichiers de $2"
  disableDefaultLinks: true
auth:
  tokenExpirationHours: 12
  key: "$5"
  adminUsername: "$2"
  adminPassword: $6
  methods:
$7
userDefaults:
$(_fbq_user_defaults)
  account:
    lockPassword: $8
    permissions:
      api: false
      admin: false
      modify: true
      share: true
      realtime: true
      delete: true
      create: true
      download: true
EOF
}

# Format 2.x (mêmes paramètres). Réglages HTTP dans « http », base SQLite ;
# l'ancienne base (database.db, comptes et liens de partage) est importée au
# premier démarrage : renommée database.db.old (nom exigé par la v2) et
# indiquée dans migrateFrom tant que la nouvelle base n'existe pas.
# Clé de signature des sessions ($5) non écrite : la v2 la garde dans sa base
# (reprise de l'ancienne, sinon créée) et refuse de démarrer si celle de la
# configuration diffère.
_fbq_write_v2() {
    local dir migrate=""
    dir=$(dirname "$1")
    if [ ! -s "$dir/database.sqlite" ]; then
        [ -s "$dir/database.db" ] && [ ! -e "$dir/database.db.old" ] && mv "$dir/database.db" "$dir/database.db.old"
        [ -s "$dir/database.db.old" ] && migrate='
    migrateFrom: "/home/filebrowser/data/database.db.old"'
    fi
    cat > "$1" << EOF
# Généré par lib_filebrowser.sh (seedbox) — régénéré par les scripts :
# les modifications manuelles peuvent être écrasées.
http:
  port: ${FBQ_PORT}
  baseURL: "$3"
  externalUrl: "$4"
  trustProxyHeaders: true
server:
  database:
    path: "/home/filebrowser/data/database.sqlite"${migrate}
  cacheDir: "/home/filebrowser/data/cache"
  disableUpdateCheck: true
  logging:
    - levels: "info|warning|error"
  sources:
    - path: "/srv"
      name: "$2"
      config:
        defaultEnabled: true
        defaultPermissions:
          view: true
          download: true
          modify: true
          delete: true
          create: true
          configured: true
frontend:
  name: "Fichiers de $2"
  disableDefaultLinks: true
auth:
  tokenExpirationHours: 12
  adminUsername: "$2"
  adminPassword: $6
  methods:
$7
userDefaults:
$(_fbq_user_defaults)
  account:
    lockPassword: $8
    permissions:
      api: false
      admin: false
      share: true
      realtime: true
EOF
}
