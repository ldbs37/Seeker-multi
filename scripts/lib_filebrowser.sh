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
#######################

# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
FBQ_IMAGE="gtstef/filebrowser:1.5.6-stable"
FBQ_PORT=8080

# Valeur hexadécimale d'une clé « clé: "valeur" » de la section auth d'un config.yaml
# existant (secrets conservés d'une génération à l'autre). $1=fichier $2=clé
_fbq_get() { sed -n "s/^  $2: \"\\([0-9a-f]*\\)\"$/\\1/p" "$1" 2>/dev/null | head -1; }

# Écrit la configuration d'une instance. Idempotent (secrets conservés).
# $1=fichier config.yaml $2=utilisateur [$3=mot de passe seedbox]
# Variables : USE_TRAEFIK, DOMAIN ; en-tête : sso_header (lib_traefik.sh)
#
# Compte de l'utilisateur = administrateur de SON instance (adminUsername).
#  - Connexion unique (en-tête) : compte créé à sa première visite ;
#    adminPassword aléatoire, jamais utilisé.
#  - Mot de passe (port direct) : FileBrowser réapplique adminPassword à
#    chaque démarrage ; c'est donc le mot de passe seedbox (fichier en 600),
#    réécrit par update_password.sh. Sans $3, la valeur existante est gardée.
fbq_write_config() {
    local file="$1" user="$2" pass="${3:-}" key adminpw header="" base="/" ext="" auth lock=false
    mkdir -p "$(dirname "$file")"
    key=$(_fbq_get "$file" key); [ -n "$key" ] || key=$(openssl rand -hex 32)
    if [ "${USE_TRAEFIK:-false}" = true ]; then
        # externalUrl avec le chemin de base : sinon lien de partage en « //drive »
        base=$(traefik_service_path filebrowser); ext="https://${user}.${DOMAIN}${base}"
        header=$(sso_header 2>/dev/null || true)
    fi
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
    cat > "$file" << EOF
# Généré par lib_filebrowser.sh (seedbox) — régénéré par les scripts :
# les modifications manuelles peuvent être écrasées.
server:
  port: ${FBQ_PORT}
  baseURL: "${base}"
  externalUrl: "${ext}"
  database: "/home/filebrowser/data/database.db"
  cacheDir: "/home/filebrowser/data/cache"
  disableUpdateCheck: true
  logging:
    - levels: "info|warning|error"
  sources:
    - path: "/srv"
      name: "${user}"
      config:
        defaultEnabled: true
frontend:
  name: "Fichiers de ${user}"
  disableDefaultLinks: true
auth:
  tokenExpirationHours: 12
  key: "${key}"
  adminUsername: "${user}"
  adminPassword: ${adminpw}
  methods:
${auth}
userDefaults:
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
  account:
    lockPassword: ${lock}
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
    chmod 600 "$file"
}
