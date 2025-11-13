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
INSTALL_SCRUTINY=false
INSTALL_UPTIME_KUMA=false
INSTALL_WATCHTOWER=false
INSTALL_DUPLICATI=false

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
    curl -L "https://github.com/docker/compose/releases/download/v2.24.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
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
    echo -e "\n${BLUE}=== Services optionnels ===${NC}"
    read -p "Installer Scrutiny (monitoring disques) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_SCRUTINY=true

    read -p "Installer Uptime Kuma (monitoring uptime) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_UPTIME_KUMA=true

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
    [ "$INSTALL_SCRUTINY" = true ] && echo "  ✓ Scrutiny"
    [ "$INSTALL_UPTIME_KUMA" = true ] && echo "  ✓ Uptime Kuma"
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
    echo "  - Plex: http://votre-serveur:32400/web"
    [ "$INSTALL_SCRUTINY" = true ] && echo "  - Scrutiny: http://votre-serveur:8080"
    [ "$INSTALL_UPTIME_KUMA" = true ] && echo "  - Uptime Kuma: http://votre-serveur:3001"
    [ "$INSTALL_DUPLICATI" = true ] && echo "  - Duplicati: http://votre-serveur:8200"

    echo -e "\n${YELLOW}Prochaines étapes:${NC}"
    echo "1. Ajouter des utilisateurs:"
    echo "   cd $INSTALL_DIR/scripts"
    echo "   sudo ./add_user.sh <username> <password> <email> [quota]"
    echo ""
    echo "2. Installer des services optionnels:"
    echo "   sudo ./add_service.sh <service_name>"
    echo ""
    echo "3. Gérer les quotas:"
    echo "   sudo ./update_quota.sh <username> <quota_gb>"

    log "Installation terminée !"
}

# Lancement
main "$@"
