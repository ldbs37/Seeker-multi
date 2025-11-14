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
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    address: ":443"
    http:
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

if [ -f "$DOCKER_COMPOSE_FILE" ]; then
    cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.pre-traefik-backup"
    log "✓ Sauvegarde de docker-compose.yml créée"
fi

#######################
# 5. Ajouter Traefik au docker-compose.yml
#######################

log "Ajout de Traefik au docker-compose.yml..."

# Vérifier si Traefik existe déjà
if grep -q "traefik:" "$DOCKER_COMPOSE_FILE"; then
    warn "Traefik existe déjà dans docker-compose.yml, ignoré"
else
    # Ajouter le service Traefik
    cat >> "$DOCKER_COMPOSE_FILE" << EOF

  traefik:
    image: traefik:v3.0
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
      - TZ=Europe/Paris
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

    # Mettre à jour le domaine de session
    sed -i "s/domain: .*/domain: $DOMAIN/" "$AUTHELIA_CONFIG"

    log "✓ Configuration Authelia mise à jour"
fi

# Ajouter les labels Authelia si pas déjà présents
if ! grep -q "traefik.http.middlewares.authelia.forwardauth" "$DOCKER_COMPOSE_FILE"; then
    log "Ajout des labels Authelia pour Forward Auth..."

    # Trouver la section authelia et ajouter les labels
    sed -i '/authelia:/,/^  [a-z]/ {
        /^  [a-z]/i\    labels:\
      - "traefik.enable=true"\
      - "traefik.http.routers.authelia.rule=Host(\`auth.'$DOMAIN'\`)"\
      - "traefik.http.routers.authelia.entrypoints=websecure"\
      - "traefik.http.routers.authelia.tls.certresolver=letsencrypt"\
      - "traefik.http.services.authelia.loadbalancer.server.port=9091"\
      - "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/verify?rd=https://auth.'$DOMAIN'"\
      - "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"\
      - "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
    }' "$DOCKER_COMPOSE_FILE"

    log "✓ Labels Authelia ajoutés"
fi

#######################
# 7. Ajouter le réseau au docker-compose.yml
#######################

log "Ajout du réseau traefik_proxy au docker-compose.yml..."

if ! grep -q "traefik_proxy:" "$DOCKER_COMPOSE_FILE"; then
    cat >> "$DOCKER_COMPOSE_FILE" << EOF

networks:
  traefik_proxy:
    external: true
EOF
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
info "   2. Générer les labels pour les services existants :"
info "      sudo ./generate_traefik_labels.sh"
info ""
info "   3. Redémarrer les services :"
info "      cd $INSTALL_DIR"
info "      docker-compose down"
info "      docker-compose up -d"
info ""
info "   4. Tester :"
info "      curl https://auth.$DOMAIN"
info ""
info "💡 Pour ajouter de nouveaux services :"
info "   Les scripts add_user.sh et add_user_service.sh génèreront"
info "   automatiquement les labels Traefik"
info ""
info "═══════════════════════════════════════════════════════════"
