#!/bin/bash

#######################
# Script d'installation et configuration Traefik
# Active le mode reverse proxy avec SSL automatique
# Usage: ./setup_traefik.sh <domain> <email>
#######################

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonctions
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Configuration
INSTALL_DIR="/opt/seedbox"
TRAEFIK_DIR="$INSTALL_DIR/traefik"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

# Vérification des arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <email>"
    echo ""
    echo "Exemple:"
    echo "  sudo ./setup_traefik.sh example.com admin@example.com"
    echo ""
    echo "Prérequis:"
    echo "  - Nom de domaine pointant vers ce serveur"
    echo "  - DNS wildcard : *.domain.com → IP serveur"
    echo "  - Ports 80/443 ouverts dans le firewall"
    exit 1
fi

DOMAIN=$1
EMAIL=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérifier que Docker est installé
if ! command -v docker &>/dev/null; then
    error "Docker n'est pas installé. Installez-le d'abord."
fi

log "Installation de Traefik pour le domaine $DOMAIN..."

#######################
# 1. Créer les répertoires
#######################

log "Création des répertoires Traefik..."
mkdir -p "$TRAEFIK_DIR/letsencrypt"
mkdir -p "$TRAEFIK_DIR/logs"
touch "$TRAEFIK_DIR/letsencrypt/acme.json"
chmod 600 "$TRAEFIK_DIR/letsencrypt/acme.json"

#######################
# 2. Configuration Traefik
#######################

log "Création de la configuration Traefik..."

cat > "$TRAEFIK_DIR/traefik.yml" << EOF
# Configuration Traefik pour Seedbox Multi-Utilisateurs

api:
  dashboard: true
  insecure: false  # Dashboard protégé par Authelia

entryPoints:
  web:
    address: ":80"
    http:
      aliasHeadersStrategy: delete
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    address: ":443"
    http:
      # Noms de fichiers avec #, ?, %, ; (Filebrowser, torrents) : autorisés
      # explicitement, les futures versions de Traefik les refusant par défaut
      # Supprime les en-têtes imitant ceux gérés par Traefik/Authelia
      # (ex. Remote_User pour Remote-User, lus à l'identique par les backends
      # Python/WSGI comme Bazarr ou Calibre-Web)
      aliasHeadersStrategy: delete
      encodedCharacters:
        allowEncodedHash: true
        allowEncodedQuestionMark: true
        allowEncodedPercent: true
        allowEncodedSemicolon: true
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: $EMAIL
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik_proxy
    watch: true

log:
  level: INFO
  filePath: /logs/traefik.log

accessLog:
  filePath: /logs/access.log
EOF

log "✓ Configuration Traefik créée"

#######################
# 3. Créer le réseau Docker
#######################

log "Création du réseau Docker traefik_proxy..."
if ! docker network inspect traefik_proxy >/dev/null 2>&1; then
    docker network create traefik_proxy
    log "✓ Réseau traefik_proxy créé"
else
    info "Réseau traefik_proxy existe déjà"
fi

#######################
# 4. Sauvegarder docker-compose.yml
#######################

[ -f "$DOCKER_COMPOSE_FILE" ] || error "docker-compose.yml introuvable ($DOCKER_COMPOSE_FILE) — lancez d'abord l'installation"
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.pre-traefik-backup"
log "✓ Sauvegarde de docker-compose.yml créée"

#######################
# 5. Ajouter Traefik au docker-compose.yml
#######################

log "Ajout de Traefik au docker-compose.yml..."

# Vérifier si Traefik existe déjà (clé de service exacte, pas "traefik_proxy:")
if grep -q "^  traefik:" "$DOCKER_COMPOSE_FILE"; then
    warn "Traefik existe déjà dans docker-compose.yml, ignoré"
else
    # Ajouter le service Traefik
    cat >> "$DOCKER_COMPOSE_FILE" << EOF

  traefik:
    image: traefik:v3.7.13
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - traefik_proxy
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/letsencrypt:/letsencrypt
      - ./traefik/logs:/logs
    labels:
      - "traefik.enable=true"

      # Dashboard Traefik
      - "traefik.http.routers.dashboard.rule=Host(\`traefik.$DOMAIN\`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=authelia@docker"
    environment:
      - TZ=\${TZ:-Europe/Paris}
EOF

    log "✓ Traefik ajouté au docker-compose.yml"
fi

#######################
# 6. Mettre à jour Authelia pour Traefik
#######################

log "Configuration d'Authelia pour Traefik..."

AUTHELIA_CONFIG="$INSTALL_DIR/authelia/configuration.yml"

if [ -f "$AUTHELIA_CONFIG" ]; then
    # Sauvegarder
    cp "$AUTHELIA_CONFIG" "${AUTHELIA_CONFIG}.pre-traefik-backup"

    # Si le domaine a changé depuis l'installation, remplacer l'ancien domaine
    # partout (cookie de session, authelia_url, règles d'accès et regex).
    OLD_DOMAIN=""
    [ -f "$INSTALL_DIR/.env" ] && OLD_DOMAIN=$(grep '^DOMAIN=' "$INSTALL_DIR/.env" | cut -d'=' -f2)
    if [ -n "$OLD_DOMAIN" ] && [ "$OLD_DOMAIN" != "$DOMAIN" ]; then
        old_lit=$(printf '%s' "$OLD_DOMAIN" | sed 's/[.[\*^$/]/\\&/g')      # ancien, littéral
        old_re=$(printf '%s' "$OLD_DOMAIN" | sed 's/\./\\\\\\./g')           # ancien, forme regex (a\.b)
        new_re=$(printf '%s' "$DOMAIN" | sed 's/\./\\\\./g')
        sed -i "s/${old_re}/${new_re}/g; s/${old_lit}/${DOMAIN}/g" "$AUTHELIA_CONFIG"
        log "✓ Domaine Authelia mis à jour : $OLD_DOMAIN -> $DOMAIN"
    else
        log "✓ Configuration Authelia déjà alignée sur $DOMAIN"
    fi
fi

# Les services existants (dont Authelia et son middleware forward-auth) sont
# câblés à Traefik par generate_traefik_labels.sh (migration). À l'installation
# en mode Traefik, ils le sont déjà via generate_docker_compose.
if grep -q "traefik.http.middlewares.authelia.forwardauth" "$DOCKER_COMPOSE_FILE"; then
    MIGRATION_NEEDED=false
    log "✓ Services déjà configurés pour Traefik"
else
    MIGRATION_NEEDED=true
    warn "Services existants non encore câblés à Traefik (migration requise)"
fi

#######################
# 7. Ajouter le réseau au docker-compose.yml
#######################

log "Ajout du réseau traefik_proxy au docker-compose.yml..."

if ! grep -q "^  traefik_proxy:" "$DOCKER_COMPOSE_FILE"; then
    # Inséré EN TÊTE (avant "services:") : les scripts ajoutent ensuite des
    # services en fin de fichier (>>) ; un bloc networks: final les avalerait.
    sed -i '0,/^services:/s//networks:\n  traefik_proxy:\n    external: true\n\nservices:/' "$DOCKER_COMPOSE_FILE"
    log "✓ Réseau ajouté au docker-compose.yml"
else
    info "Réseau déjà présent dans docker-compose.yml"
fi

#######################
# 8. Configurer UFW (si installé)
#######################

if command -v ufw &>/dev/null; then
    log "Configuration UFW pour Traefik..."
    ufw allow 80/tcp comment 'Traefik HTTP'
    ufw allow 443/tcp comment 'Traefik HTTPS'
    log "✓ Ports 80/443 ouverts dans UFW"
fi

#######################
# 9. Créer le fichier .env avec le domaine
#######################

ENV_FILE="$INSTALL_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    # Mettre à jour le domaine s'il existe
    if grep -q "^DOMAIN=" "$ENV_FILE"; then
        sed -i "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" "$ENV_FILE"
    else
        echo "DOMAIN=$DOMAIN" >> "$ENV_FILE"
    fi
else
    echo "DOMAIN=$DOMAIN" > "$ENV_FILE"
fi

log "✓ Domaine configuré dans .env"

#######################
# Résumé
#######################

echo ""
info "═══════════════════════════════════════════════════════════"
info "Installation Traefik terminée avec succès !"
info "═══════════════════════════════════════════════════════════"
info ""
info "📝 Configuration :"
info "   - Domaine : $DOMAIN"
info "   - Email : $EMAIL"
info "   - Réseau : traefik_proxy"
info ""
info "🌐 Services accessibles :"
info "   - Dashboard Traefik : https://traefik.$DOMAIN"
info "   - Authelia : https://auth.$DOMAIN"
info ""
info "⚠️  IMPORTANT - Prochaines étapes :"
info ""
info "   1. Vérifier DNS :"
info "      Assurez-vous que *.${DOMAIN} pointe vers ce serveur"
info ""
if [ "$MIGRATION_NEEDED" = true ]; then
    info "   2. Migrer les services existants vers Traefik (labels, réseau,"
    info "      SSO, ports restreints) puis redémarrer — tout est automatique :"
    info "      sudo $INSTALL_DIR/scripts/generate_traefik_labels.sh"
else
    info "   2. Démarrer / redémarrer les services :"
    info "      cd $INSTALL_DIR && docker compose up -d"
fi
info ""
info "   3. Tester :"
info "      curl https://auth.$DOMAIN"
info ""
info "💡 Pour ajouter de nouveaux services :"
info "   Les scripts add_user.sh et add_user_service.sh génèreront"
info "   automatiquement les labels Traefik"
info ""
info "═══════════════════════════════════════════════════════════"
