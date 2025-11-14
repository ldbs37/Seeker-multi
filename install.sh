#!/bin/bash

#######################
# Installation Seedbox Multi-Utilisateurs - Version Simplifiée
# Sans Traefik, avec authentification centralisée Authelia
#######################

set -e
set -u
set -o pipefail

#######################
# Variables et constantes
#######################

# Variables de configuration par défaut
DOMAIN="votredomaine.com"
EMAIL="votre@email.com"
INSTALL_DIR="/opt/seedbox"
TZ="Europe/Paris"
DEFAULT_QUOTA="500" # En GB

# Variables Docker
DOCKER_NETWORK="seedbox_network"

# Variables des UID/GID de base
ADMIN_UID="1000"
ADMIN_GID="1000"
START_UID="1001"

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Fonctions de base pour les logs
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Tableau pour stocker les utilisateurs
declare -a INITIAL_USERS

# Services optionnels
INSTALL_PLEX=false
INSTALL_JELLYFIN=false
INSTALL_SCRUTINY=false
INSTALL_UPTIME_KUMA=false
INSTALL_DASHDOT=false
INSTALL_TAUTULLI=false
INSTALL_PORTAINER=false
INSTALL_ORGANIZR=false
INSTALL_WATCHTOWER=false
INSTALL_DUPLICATI=false

# Identifiants Portainer
PORTAINER_USER=""
PORTAINER_PASSWORD=""

# Identifiants Jellyfin
JELLYFIN_USER=""
JELLYFIN_PASSWORD=""

#######################
# Fonctions utilitaires
#######################

# Validation d'email
validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        error "Format d'email invalide: $email"
    fi
}

# Validation de nom d'utilisateur
validate_username() {
    local username=$1
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "Nom d'utilisateur invalide: $username"
    fi
}

# Validation de mot de passe
validate_password() {
    local password=$1
    if [ ${#password} -lt 8 ]; then
        error "Le mot de passe doit contenir au moins 8 caractères"
    fi
}

# Vérification de commande
check_command() {
    local cmd=$1
    if ! command -v "$cmd" &>/dev/null; then
        error "Commande '$cmd' non trouvée"
    fi
}

# Test de connexion internet
check_internet() {
    if ! ping -c 1 8.8.8.8 &>/dev/null; then
        error "Pas de connexion Internet"
    fi
}

# Affichage de la progression
show_progress() {
    local current=$1
    local total=$2
    local prefix=${3:-"Progress"}
    local width=50
    local percentage=$((current * 100 / total))
    local completed=$((width * current / total))
    local remaining=$((width - completed))

    printf "\r%s [%s%s] %d%%" \
        "$prefix" \
        "$(printf '#%.0s' $(seq 1 "$completed" 2>/dev/null || echo))" \
        "$(printf ' %.0s' $(seq 1 "$remaining" 2>/dev/null || echo))" \
        "$percentage"

    if [ "$current" -eq "$total" ]; then
        echo
    fi
}

#######################
# Vérifications système
#######################

check_system() {
    log "Vérification du système..."

    # Vérification root
    if [[ $EUID -ne 0 ]]; then
        error "Ce script doit être exécuté en tant que root"
    fi

    # Vérification connexion internet
    check_internet

    # Vérification espace disque (minimum 20GB)
    local available_space
    available_space=$(df -BG / | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "${available_space}" -lt 20 ]; then
        error "Espace disque insuffisant : ${available_space}G disponible, 20G requis"
    fi

    # Vérification RAM (minimum 4GB)
    local available_ram
    available_ram=$(free -g | awk '/^Mem:/{print $2}')
    if [ "${available_ram}" -lt 4 ]; then
        error "RAM insuffisante : ${available_ram}G disponible, 4G requis"
    fi

    # Vérification du système de fichiers
    local fs_type
    fs_type=$(df -T / | tail -1 | awk '{print $2}')
    if [[ ! "$fs_type" =~ ^(ext[234]|xfs)$ ]]; then
        warn "Système de fichiers '$fs_type' détecté"
        warn "Les quotas fonctionnent mieux sur ext4 ou xfs"
        warn "Des problèmes peuvent survenir avec btrfs ou zfs"
        echo ""
        read -p "Continuer malgré tout ? (o/N): " confirm
        [[ ! $confirm =~ ^[oO]$ ]] && error "Installation annulée"
    fi

    log "✓ Vérifications système OK"
}

#######################
# Installation des dépendances
#######################

install_dependencies() {
    log "Installation des dépendances..."

    apt-get update
    apt-get install -y \
        curl \
        git \
        apt-transport-https \
        ca-certificates \
        gnupg \
        lsb-release \
        sudo \
        quota \
        fail2ban \
        ufw \
        wget \
        unzip \
        netcat \
        apache2-utils \
        bc

    log "✓ Dépendances installées"
}

install_docker() {
    log "Installation de Docker..."

    if command -v docker &>/dev/null; then
        log "Docker déjà installé"
        return
    fi

    # Installation via le script officiel
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh

    # Installation de Docker Compose
    DOCKER_COMPOSE_VERSION="v2.29.7"
    curl -L "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose

    # Démarrage
    systemctl start docker
    systemctl enable docker

    log "✓ Docker installé"
}

#######################
# Configuration système
#######################

setup_system() {
    log "Configuration du système..."

    # Fuseau horaire
    timedatectl set-timezone "$TZ" 2>/dev/null || warn "Impossible de configurer le fuseau horaire"

    # Pare-feu
    if command -v ufw &>/dev/null; then
        ufw default deny incoming
        ufw default allow outgoing
        ufw allow ssh
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 32400/tcp  # Plex
        echo "y" | ufw enable 2>/dev/null || true
    fi

    # Fail2ban
    if [ -f "/etc/fail2ban/jail.local" ]; then
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak
    fi

    cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
EOF

    systemctl restart fail2ban 2>/dev/null || true

    log "✓ Système configuré"
}

#######################
# Préparation des dossiers
#######################

prepare_directories() {
    log "Création de la structure de dossiers..."

    mkdir -p "$INSTALL_DIR"
    mkdir -p "$INSTALL_DIR/data/users"
    mkdir -p "$INSTALL_DIR/authelia"
    mkdir -p "$INSTALL_DIR/plex"
    mkdir -p "$INSTALL_DIR/scripts"

    # Copier les scripts de gestion
    if [ -d "$(dirname "$0")/scripts" ]; then
        cp -r "$(dirname "$0")/scripts/"* "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/"*.sh
    fi

    # Copier le menu interactif
    if [ -f "$(dirname "$0")/menu.sh" ]; then
        cp "$(dirname "$0")/menu.sh" "$INSTALL_DIR/menu.sh"
        chmod +x "$INSTALL_DIR/menu.sh"
    fi

    log "✓ Dossiers créés"
}

#######################
# Configuration Authelia
#######################

configure_authelia() {
    log "Configuration d'Authelia..."

    local config_dir="$INSTALL_DIR/authelia"
    local encryption_key=$(openssl rand -hex 64)
    local session_secret=$(openssl rand -hex 32)

    # Configuration principale
    cat > "$config_dir/configuration.yml" << EOF
---
server:
  host: 0.0.0.0
  port: 9091

log:
  level: info

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: one_factor

session:
  name: authelia_session
  secret: ${session_secret}
  expiration: 3600
  inactivity: 300
  domain: ${DOMAIN}

storage:
  local:
    path: /config/db.sqlite3
  encryption_key: ${encryption_key}

notifier:
  filesystem:
    filename: /config/notification.txt
EOF

    # Fichier utilisateurs
    cat > "$config_dir/users_database.yml" << 'EOF'
users:
EOF

    chmod 600 "$config_dir/configuration.yml"
    chmod 600 "$config_dir/users_database.yml"

    log "✓ Authelia configuré"
}

#######################
# Génération du docker-compose.yml
#######################

generate_docker_compose() {
    log "Génération de la configuration Docker..."

    local compose_file="$INSTALL_DIR/docker-compose.yml"

    cat > "$compose_file" << 'EOF'
version: '3.8'

services:
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    volumes:
      - ./authelia:/config
    environment:
      - TZ=${TZ}
    ports:
      - "9091:9091"
    restart: unless-stopped
EOF

    # Plex optionnel
    if [ "$INSTALL_PLEX" = true ]; then
        cat >> "$compose_file" << 'EOF'

  plex:
    image: linuxserver/plex:latest
    container_name: plex
    network_mode: host
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
      - VERSION=docker
    volumes:
      - ./plex:/config
      - ./data:/data
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/plex"
    fi

    cat >> "$compose_file" << 'EOF'

  flaresolverr:
    image: ghcr.io/flaresolverr/flaresolverr:latest
    container_name: flaresolverr
    environment:
      - LOG_LEVEL=info
      - TZ=${TZ}
    ports:
      - "8191:8191"
    restart: unless-stopped
EOF

    # Ajouter les services optionnels
    if [ "$INSTALL_SCRUTINY" = true ]; then
        cat >> "$compose_file" << 'EOF'

  scrutiny:
    image: ghcr.io/analogj/scrutiny:master-omnibus
    container_name: scrutiny
    privileged: true
    ports:
      - "8080:8080"
    volumes:
      - ./scrutiny/config:/opt/scrutiny/config
      - ./scrutiny/influxdb:/opt/scrutiny/influxdb
      - /run/udev:/run/udev:ro
    cap_add:
      - SYS_RAWIO
      - SYS_ADMIN
    environment:
      - TZ=${TZ}
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/scrutiny/config"
        mkdir -p "$INSTALL_DIR/scrutiny/influxdb"
    fi

    if [ "$INSTALL_UPTIME_KUMA" = true ]; then
        cat >> "$compose_file" << 'EOF'

  uptime-kuma:
    image: louislam/uptime-kuma:latest
    container_name: uptime-kuma
    volumes:
      - ./uptime-kuma:/app/data
    ports:
      - "3001:3001"
    environment:
      - TZ=${TZ}
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/uptime-kuma"
    fi

    if [ "$INSTALL_WATCHTOWER" = true ]; then
        cat >> "$compose_file" << 'EOF'

  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - WATCHTOWER_SCHEDULE=0 0 4 * * *
      - WATCHTOWER_CLEANUP=true
      - TZ=${TZ}
    restart: unless-stopped
EOF
    fi

    if [ "$INSTALL_DUPLICATI" = true ]; then
        cat >> "$compose_file" << 'EOF'

  duplicati:
    image: linuxserver/duplicati:latest
    container_name: duplicati
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
    volumes:
      - ./duplicati/config:/config
      - ./data:/source:ro
    ports:
      - "8200:8200"
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/duplicati/config"
    fi

    if [ "$INSTALL_JELLYFIN" = true ]; then
        cat >> "$compose_file" << 'EOF'

  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - ./data:/media:ro
    ports:
      - "8096:8096"
      - "8920:8920"
      - "7359:7359/udp"
      - "1900:1900/udp"
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/jellyfin/config"
        mkdir -p "$INSTALL_DIR/jellyfin/cache"
    fi

    if [ "$INSTALL_DASHDOT" = true ]; then
        cat >> "$compose_file" << 'EOF'

  dashdot:
    image: mauricenino/dashdot:latest
    container_name: dashdot
    privileged: true
    ports:
      - "3002:3001"
    volumes:
      - ./dashdot:/data
      - /:/mnt/host:ro
    environment:
      - TZ=${TZ}
      - DASHDOT_ENABLE_CPU_TEMPS=true
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/dashdot"
    fi

    if [ "$INSTALL_TAUTULLI" = true ]; then
        cat >> "$compose_file" << 'EOF'

  tautulli:
    image: linuxserver/tautulli:latest
    container_name: tautulli
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
    volumes:
      - ./tautulli:/config
    ports:
      - "8181:8181"
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/tautulli"
    fi

    if [ "$INSTALL_PORTAINER" = true ]; then
        cat >> "$compose_file" << 'EOF'

  portainer:
    image: portainer/portainer-ce:latest
    container_name: portainer
    ports:
      - "9000:9000"
      - "8000:8000"
    volumes:
      - ./portainer:/data
      - /var/run/docker.sock:/var/run/docker.sock
    environment:
      - TZ=${TZ}
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/portainer"
    fi

    if [ "$INSTALL_ORGANIZR" = true ]; then
        cat >> "$compose_file" << 'EOF'

  organizr:
    image: organizr/organizr:latest
    container_name: organizr
    environment:
      - PUID=${ADMIN_UID}
      - PGID=${ADMIN_GID}
      - TZ=${TZ}
    volumes:
      - ./organizr:/config
    ports:
      - "9983:80"
    restart: unless-stopped
EOF
        mkdir -p "$INSTALL_DIR/organizr"
    fi

    # Créer le fichier .env
    cat > "$INSTALL_DIR/.env" << EOF
TZ=$TZ
DOMAIN=$DOMAIN
ADMIN_UID=$ADMIN_UID
ADMIN_GID=$ADMIN_GID
EOF

    log "✓ Configuration Docker générée"
}

#######################
# Configuration interactive
#######################

configure_installation() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Installation Seedbox Multi-Utilisateurs  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}\n"

    # Configuration du domaine
    while true; do
        read -p "Nom de domaine (ex: exemple.com): " input_domain
        if [[ "$input_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
            DOMAIN=$input_domain
            break
        else
            warn "Nom de domaine invalide"
        fi
    done

    while true; do
        read -p "Email administrateur: " input_email
        if validate_email "$input_email" 2>/dev/null; then
            EMAIL=$input_email
            break
        else
            warn "Email invalide"
        fi
    done

    # Configuration admin
    echo -e "\n${BLUE}=== Configuration administrateur ===${NC}"
    read -p "Nom d'utilisateur admin [admin]: " ADMIN_USER
    ADMIN_USER=${ADMIN_USER:-"admin"}

    while true; do
        read -s -p "Mot de passe admin (min 8 caractères): " ADMIN_PASSWORD
        echo
        if [ ${#ADMIN_PASSWORD} -ge 8 ]; then
            read -s -p "Confirmez le mot de passe: " ADMIN_PASSWORD_CONFIRM
            echo
            if [ "$ADMIN_PASSWORD" = "$ADMIN_PASSWORD_CONFIRM" ]; then
                break
            else
                warn "Les mots de passe ne correspondent pas"
            fi
        else
            warn "Le mot de passe doit contenir au moins 8 caractères"
        fi
    done

    # Services optionnels
    echo -e "\n${BLUE}=== Services de streaming ===${NC}"
    read -p "Installer Plex (serveur de streaming) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_PLEX=true

    read -p "Installer Jellyfin (alternative open-source à Plex) ? (o/N): " input
    if [[ $input =~ ^[oO]$ ]]; then
        INSTALL_JELLYFIN=true

        # Configurer les identifiants Jellyfin
        echo -e "\n${BLUE}Configuration Jellyfin:${NC}"
        read -p "Nom d'utilisateur admin [admin]: " JELLYFIN_USER
        JELLYFIN_USER=${JELLYFIN_USER:-"admin"}

        while true; do
            read -s -p "Mot de passe admin (min 8 caractères): " JELLYFIN_PASSWORD
            echo
            if [ ${#JELLYFIN_PASSWORD} -ge 8 ]; then
                read -s -p "Confirmez le mot de passe: " JELLYFIN_PASSWORD_CONFIRM
                echo
                if [ "$JELLYFIN_PASSWORD" = "$JELLYFIN_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 8 caractères"
            fi
        done
    fi

    # Vérification conflit Plex/Jellyfin
    if [ "$INSTALL_PLEX" = true ] && [ "$INSTALL_JELLYFIN" = true ]; then
        echo ""
        warn "⚠️  ATTENTION: Conflit potentiel détecté !"
        warn "    Plex et Jellyfin utilisent tous deux le port UDP 1900 (UPnP/DLNA)"
        warn "    Il est fortement recommandé de n'installer qu'un seul service de streaming"
        echo ""
        read -p "Voulez-vous annuler l'installation de Jellyfin ? (O/n): " confirm
        if [[ ! $confirm =~ ^[nN]$ ]]; then
            INSTALL_JELLYFIN=false
            JELLYFIN_USER=""
            JELLYFIN_PASSWORD=""
            info "Installation de Jellyfin annulée"
        else
            warn "Les deux services seront installés - des conflits peuvent survenir"
        fi
    fi

    echo -e "\n${BLUE}=== Dashboards & Monitoring ===${NC}"
    read -p "Installer Dashdot (monitoring système élégant) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_DASHDOT=true

    read -p "Installer Scrutiny (monitoring disques S.M.A.R.T.) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_SCRUTINY=true

    read -p "Installer Uptime Kuma (monitoring uptime) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_UPTIME_KUMA=true

    read -p "Installer Tautulli (statistiques Plex) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_TAUTULLI=true

    echo -e "\n${BLUE}=== Gestion & Organisation ===${NC}"
    read -p "Installer Portainer (gestion Docker web) ? (o/N): " input
    if [[ $input =~ ^[oO]$ ]]; then
        INSTALL_PORTAINER=true

        # Configurer les identifiants Portainer
        echo -e "\n${BLUE}Configuration Portainer:${NC}"
        read -p "Nom d'utilisateur admin [admin]: " PORTAINER_USER
        PORTAINER_USER=${PORTAINER_USER:-"admin"}

        while true; do
            read -s -p "Mot de passe admin (min 12 caractères): " PORTAINER_PASSWORD
            echo
            if [ ${#PORTAINER_PASSWORD} -ge 12 ]; then
                read -s -p "Confirmez le mot de passe: " PORTAINER_PASSWORD_CONFIRM
                echo
                if [ "$PORTAINER_PASSWORD" = "$PORTAINER_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 12 caractères"
            fi
        done
    fi

    read -p "Installer Organizr (dashboard all-in-one) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_ORGANIZR=true

    echo -e "\n${BLUE}=== Maintenance ===${NC}"
    read -p "Installer Watchtower (mises à jour auto) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_WATCHTOWER=true

    read -p "Installer Duplicati (backups) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_DUPLICATI=true

    # Utilisateurs initiaux
    echo -e "\n${BLUE}=== Utilisateurs initiaux ===${NC}"
    INITIAL_USERS=()
    while true; do
        read -p "Ajouter un utilisateur ? (O/n): " add_user
        if [[ $add_user =~ ^[nN]$ ]]; then
            break
        fi

        read -p "Nom d'utilisateur: " username
        validate_username "$username"

        while true; do
            read -s -p "Mot de passe: " password
            echo
            if [ ${#password} -ge 8 ]; then
                read -s -p "Confirmez: " password_confirm
                echo
                if [ "$password" = "$password_confirm" ]; then
                    break
                fi
            fi
            warn "Mot de passe invalide"
        done

        read -p "Email: " email
        validate_email "$email"

        read -p "Quota (GB) [500]: " quota
        quota=${quota:-500}

        INITIAL_USERS+=("$username:$password:$email:$quota")
    done

    # Récapitulatif
    echo -e "\n${BLUE}=== Récapitulatif ===${NC}"
    echo "Domaine: $DOMAIN"
    echo "Email: $EMAIL"
    echo "Admin: $ADMIN_USER"
    echo "Services optionnels:"
    [ "$INSTALL_PLEX" = true ] && echo "  ✓ Plex"
    [ "$INSTALL_JELLYFIN" = true ] && echo "  ✓ Jellyfin"
    [ "$INSTALL_DASHDOT" = true ] && echo "  ✓ Dashdot"
    [ "$INSTALL_SCRUTINY" = true ] && echo "  ✓ Scrutiny"
    [ "$INSTALL_UPTIME_KUMA" = true ] && echo "  ✓ Uptime Kuma"
    [ "$INSTALL_TAUTULLI" = true ] && echo "  ✓ Tautulli"
    [ "$INSTALL_PORTAINER" = true ] && echo "  ✓ Portainer"
    [ "$INSTALL_ORGANIZR" = true ] && echo "  ✓ Organizr"
    [ "$INSTALL_WATCHTOWER" = true ] && echo "  ✓ Watchtower"
    [ "$INSTALL_DUPLICATI" = true ] && echo "  ✓ Duplicati"
    echo "Utilisateurs: ${#INITIAL_USERS[@]}"

    read -p "Continuer l'installation ? (o/N): " confirm
    if [[ ! $confirm =~ ^[oO]$ ]]; then
        error "Installation annulée"
    fi
}

#######################
# Ajout d'utilisateur à Authelia
#######################

add_authelia_user() {
    local username=$1
    local password=$2
    local email=$3
    local is_admin=${4:-false}

    log "Configuration Authelia pour $username..."

    # Génération du hash
    local password_hash
    password_hash=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$password" 2>/dev/null | grep 'Digest:' | awk '{print $2}')

    cat >> "$INSTALL_DIR/authelia/users_database.yml" << EOF
  $username:
    displayname: "$username"
    password: "$password_hash"
    email: "$email"
    groups:
      - users
EOF

    if [ "$is_admin" = "true" ]; then
        sed -i "/^  $username:/,/^  [^ ]/ s/groups:/groups:\n      - admins/" "$INSTALL_DIR/authelia/users_database.yml"
    fi
}

#######################
# Déploiement
#######################

deploy_services() {
    log "Démarrage des services..."

    cd "$INSTALL_DIR"
    docker-compose pull
    docker-compose up -d

    # Attendre le démarrage
    sleep 10

    # Configuration automatique de Portainer si installé
    if [ "$INSTALL_PORTAINER" = true ] && [ -n "$PORTAINER_USER" ] && [ -n "$PORTAINER_PASSWORD" ]; then
        log "Configuration automatique de Portainer..."

        # Attendre que Portainer soit prêt (max 60 secondes)
        RETRY_COUNT=0
        MAX_RETRIES=30
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            if curl -s http://localhost:9000/api/status >/dev/null 2>&1; then
                break
            fi
            sleep 2
            RETRY_COUNT=$((RETRY_COUNT + 1))
        done

        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            warn "Portainer n'est pas encore prêt, la configuration sera à faire manuellement"
        else
            # Créer le compte admin via l'API
            RESPONSE=$(curl -s -X POST http://localhost:9000/api/users/admin/init \
                -H "Content-Type: application/json" \
                -d "{\"Username\":\"$PORTAINER_USER\",\"Password\":\"$PORTAINER_PASSWORD\"}")

            if echo "$RESPONSE" | grep -q "Id"; then
                log "${GREEN}✓${NC} Compte administrateur Portainer créé automatiquement"
            else
                warn "Impossible de créer le compte admin Portainer automatiquement"
                info "Créez-le manuellement sur http://votre-serveur:9000"
            fi
        fi
    fi

    # Configuration automatique de Jellyfin si installé
    if [ "$INSTALL_JELLYFIN" = true ] && [ -n "$JELLYFIN_USER" ] && [ -n "$JELLYFIN_PASSWORD" ]; then
        log "Configuration automatique de Jellyfin..."

        # Attendre que Jellyfin soit prêt (max 60 secondes)
        RETRY_COUNT=0
        MAX_RETRIES=30
        while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
            if curl -s http://localhost:8096/health >/dev/null 2>&1; then
                break
            fi
            sleep 2
            RETRY_COUNT=$((RETRY_COUNT + 1))
        done

        if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
            warn "Jellyfin n'est pas encore prêt, la configuration sera à faire manuellement"
        else
            # Créer le compte admin via l'API
            RESPONSE=$(curl -s -X POST http://localhost:8096/Startup/User \
                -H "Content-Type: application/json" \
                -d "{\"Name\":\"$JELLYFIN_USER\",\"Password\":\"$JELLYFIN_PASSWORD\"}")

            # Compléter le wizard de démarrage
            curl -s -X POST http://localhost:8096/Startup/Complete >/dev/null 2>&1

            if [ $? -eq 0 ]; then
                log "${GREEN}✓${NC} Compte administrateur Jellyfin créé automatiquement"
            else
                warn "Impossible de créer le compte admin Jellyfin automatiquement"
                info "Créez-le manuellement sur http://votre-serveur:8096"
            fi
        fi
    fi

    log "✓ Services démarrés"
}

#######################
# Fonction principale
#######################

main() {
    log "╔════════════════════════════════════════════╗"
    log "║  Installation Seedbox Multi-Utilisateurs  ║"
    log "╚════════════════════════════════════════════╝"

    # Étapes d'installation
    show_progress 0 10 "Installation"

    check_system
    show_progress 1 10 "Installation"

    install_dependencies
    show_progress 2 10 "Installation"

    install_docker
    show_progress 3 10 "Installation"

    setup_system
    show_progress 4 10 "Installation"

    configure_installation
    show_progress 5 10 "Installation"

    prepare_directories
    show_progress 6 10 "Installation"

    configure_authelia
    show_progress 7 10 "Installation"

    # Ajouter l'admin
    add_authelia_user "$ADMIN_USER" "$ADMIN_PASSWORD" "$EMAIL" true

    # Ajouter les utilisateurs initiaux
    for user_info in "${INITIAL_USERS[@]}"; do
        IFS=':' read -r username password email quota <<< "$user_info"
        add_authelia_user "$username" "$password" "$email" false
    done
    show_progress 8 10 "Installation"

    generate_docker_compose
    show_progress 9 10 "Installation"

    deploy_services
    show_progress 10 10 "Installation"

    # Message final
    echo -e "\n${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Installation terminée avec succès !   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}\n"

    info "Services disponibles:"
    echo "  - Authelia (auth): http://votre-serveur:9091"
    [ "$INSTALL_PLEX" = true ] && echo "  - Plex: http://votre-serveur:32400/web"
    [ "$INSTALL_JELLYFIN" = true ] && echo "  - Jellyfin: http://votre-serveur:8096"
    [ "$INSTALL_DASHDOT" = true ] && echo "  - Dashdot: http://votre-serveur:3002"
    [ "$INSTALL_SCRUTINY" = true ] && echo "  - Scrutiny: http://votre-serveur:8080"
    [ "$INSTALL_UPTIME_KUMA" = true ] && echo "  - Uptime Kuma: http://votre-serveur:3001"
    [ "$INSTALL_TAUTULLI" = true ] && echo "  - Tautulli: http://votre-serveur:8181"
    if [ "$INSTALL_PORTAINER" = true ]; then
        echo "  - Portainer: http://votre-serveur:9000"
        [ -n "$PORTAINER_USER" ] && echo "    Utilisateur: $PORTAINER_USER"
    fi
    [ "$INSTALL_ORGANIZR" = true ] && echo "  - Organizr: http://votre-serveur:9983"
    [ "$INSTALL_DUPLICATI" = true ] && echo "  - Duplicati: http://votre-serveur:8200"

    echo -e "\n${YELLOW}Prochaines étapes:${NC}"
    echo ""
    echo -e "${CYAN}🎮 Utiliser le menu interactif (recommandé):${NC}"
    echo "   cd $INSTALL_DIR"
    echo "   sudo ./menu.sh"
    echo ""
    echo -e "${CYAN}Ou utiliser les scripts directement:${NC}"
    echo ""
    echo "1. Ajouter des utilisateurs:"
    echo "   cd $INSTALL_DIR/scripts"
    echo "   sudo ./add_user.sh <username> <password> <email> [quota]"
    echo ""
    echo "2. Installer des services optionnels:"
    echo "   sudo ./add_service.sh <service_name>"
    echo ""
    echo "3. Gérer les quotas:"
    echo "   sudo ./update_quota.sh <username> <quota_gb>"
    echo ""
    echo -e "${BLUE}📚 Documentation complète: $INSTALL_DIR/../docs/${NC}"

    log "Installation terminée !"
}

# Lancement
main "$@"
