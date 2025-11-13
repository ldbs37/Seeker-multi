#!/bin/bash

#######################
# Script d'ajout d'utilisateur
# Usage: ./add_user.sh <username> <password> <email> [quota_gb] [--with-services]
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
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AUTHELIA_CONFIG_DIR="$INSTALL_DIR/authelia"
TZ="Europe/Paris"
DEFAULT_QUOTA="500"
INTERACTIVE_SERVICES=false

# Vérification des arguments
if [ $# -lt 3 ]; then
    error "Usage: $0 <username> <password> <email> [quota_gb] [--with-services]"
fi

USERNAME=$1
PASSWORD=$2
EMAIL=$3
QUOTA=${4:-$DEFAULT_QUOTA}

# Vérifier si le flag --with-services est présent
if [[ "$*" == *"--with-services"* ]]; then
    INTERACTIVE_SERVICES=true
fi

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Validation du nom d'utilisateur
validate_username() {
    local username=$1
    if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        error "Nom d'utilisateur invalide: $username (utilisez uniquement des lettres minuscules, chiffres, - et _)"
    fi
}

# Validation de l'email
validate_email() {
    local email=$1
    if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
        error "Format d'email invalide: $email"
    fi
}

# Validation du mot de passe
validate_password() {
    local password=$1
    if [ ${#password} -lt 8 ]; then
        error "Le mot de passe doit contenir au moins 8 caractères"
    fi
}

# Obtenir le prochain ID utilisateur
get_next_user_id() {
    local last_id=1000

    while IFS=: read -r _ _ uid _; do
        if [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] && [ "$uid" -gt "$last_id" ]; then
            last_id=$uid
        fi
    done < /etc/passwd

    echo $((last_id + 1))
}

# Validation
log "Validation des données..."
validate_username "$USERNAME"
validate_password "$PASSWORD"
validate_email "$EMAIL"

# Vérifier si l'utilisateur existe déjà
if id "$USERNAME" &>/dev/null; then
    error "L'utilisateur $USERNAME existe déjà"
fi

# Obtenir l'ID utilisateur
USER_ID=$(get_next_user_id)
log "Création de l'utilisateur $USERNAME avec l'UID $USER_ID"

# Créer l'utilisateur système
useradd -m -u "$USER_ID" -s /bin/bash "$USERNAME" || error "Impossible de créer l'utilisateur système"
usermod -aG docker "$USERNAME"

# Créer la structure de dossiers
log "Création de la structure de dossiers..."
BASE_DIR="$INSTALL_DIR/data/users/$USERNAME"

declare -a MEDIA_DIRS=(
    "downloads"
    "downloads/temp"
    "downloads/complete"
    "tv"
    "movies"
    "books"
    "books/library"
    "books/uploads"
    "music"
)

for dir in "${MEDIA_DIRS[@]}"; do
    mkdir -p "$BASE_DIR/$dir"
    chown -R "$USER_ID:$USER_ID" "$BASE_DIR/$dir"
    chmod 755 "$BASE_DIR/$dir"
done

# Dossiers de configuration des services de base
declare -a BASE_SERVICE_DIRS=(
    "qbittorrent"
    "homarr"
    "filebrowser"
)

for service in "${BASE_SERVICE_DIRS[@]}"; do
    mkdir -p "$INSTALL_DIR/$service/$USERNAME"
    chown -R "$USER_ID:$USER_ID" "$INSTALL_DIR/$service/$USERNAME"
    chmod 755 "$INSTALL_DIR/$service/$USERNAME"
done

# Ajouter l'utilisateur à Authelia
log "Configuration de l'authentification..."
PASSWORD_HASH=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$PASSWORD" 2>/dev/null | grep 'Digest:' | awk '{print $2}')

# Créer le fichier users_database.yml s'il n'existe pas
if [ ! -f "$AUTHELIA_CONFIG_DIR/users_database.yml" ]; then
    cat > "$AUTHELIA_CONFIG_DIR/users_database.yml" << EOF
users:
EOF
fi

cat >> "$AUTHELIA_CONFIG_DIR/users_database.yml" << EOF
  $USERNAME:
    displayname: "$USERNAME"
    password: "$PASSWORD_HASH"
    email: "$EMAIL"
    groups:
      - users
EOF

# Configurer les quotas
if command -v setquota &>/dev/null; then
    log "Configuration des quotas ($QUOTA GB)..."
    QUOTA_KB=$((QUOTA * 1024 * 1024))
    setquota -u "$USERNAME" 0 "$QUOTA_KB" 0 0 / 2>/dev/null || warn "Impossible de configurer les quotas"
fi

# Ajouter les services de base au docker-compose.yml
log "Ajout des services de base..."

# Sauvegarder le docker-compose.yml
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"

# Port de base pour cet utilisateur (calculé à partir de l'UID)
BASE_PORT=$((USER_ID - 1000))
QBIT_PORT=$((8080 + BASE_PORT * 10))
HOMARR_PORT=$((7575 + BASE_PORT))
FILEBROWSER_PORT=$((8081 + BASE_PORT))

# Générer la configuration des services de base
cat >> "$DOCKER_COMPOSE_FILE" << EOF

  # Services pour l'utilisateur: $USERNAME
  qbittorrent-$USERNAME:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent-$USERNAME
    environment:
      - PUID=$USER_ID
      - PGID=$USER_ID
      - TZ=$TZ
      - WEBUI_PORT=$QBIT_PORT
    volumes:
      - $INSTALL_DIR/qbittorrent/$USERNAME:/config
      - $BASE_DIR/downloads:/downloads
    ports:
      - "$QBIT_PORT:$QBIT_PORT"
      - "$((6881 + BASE_PORT)):6881"
      - "$((6881 + BASE_PORT)):6881/udp"
    restart: unless-stopped

  homarr-$USERNAME:
    image: ghcr.io/ajnart/homarr:latest
    container_name: homarr-$USERNAME
    environment:
      - PUID=$USER_ID
      - PGID=$USER_ID
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/homarr/$USERNAME:/app/data/configs
      - /var/run/docker.sock:/var/run/docker.sock:ro
    ports:
      - "$HOMARR_PORT:7575"
    restart: unless-stopped

  filebrowser-$USERNAME:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser-$USERNAME
    user: "$USER_ID:$USER_ID"
    environment:
      - TZ=$TZ
    volumes:
      - $INSTALL_DIR/filebrowser/$USERNAME:/config
      - $BASE_DIR:/srv
    ports:
      - "$FILEBROWSER_PORT:80"
    restart: unless-stopped
EOF

# Redémarrer les services
log "Démarrage des services pour $USERNAME..."
cd "$INSTALL_DIR"
docker-compose up -d

log "${GREEN}✓${NC} Utilisateur $USERNAME créé avec succès !"
echo ""
info "Informations de connexion :"
echo "  - Username: $USERNAME"
echo "  - Password: (celui que vous avez défini)"
echo "  - Email: $EMAIL"
echo "  - Quota: ${QUOTA}GB"
echo ""
info "Services de base installés :"
echo "  - qBittorrent: http://votre-serveur:$QBIT_PORT"
echo "  - Homarr (Dashboard): http://votre-serveur:$HOMARR_PORT"
echo "  - Filebrowser: http://votre-serveur:$FILEBROWSER_PORT"
echo ""

# Si mode interactif, proposer d'ajouter des services
if [ "$INTERACTIVE_SERVICES" = true ]; then
    echo -e "${BLUE}Services optionnels disponibles:${NC}"
    echo "  - sonarr      : Gestion de séries TV"
    echo "  - radarr      : Gestion de films"
    echo "  - readarr     : Gestion de livres"
    echo "  - bazarr      : Gestion de sous-titres"
    echo "  - prowlarr    : Gestion d'indexeurs"
    echo "  - overseerr   : Système de requêtes"
    echo "  - calibre     : Bibliothèque ebooks"
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    for service in sonarr radarr readarr bazarr prowlarr overseerr calibre; do
        read -p "Installer $service ? (o/N): " install_service
        if [[ $install_service =~ ^[oO]$ ]]; then
            log "Installation de $service..."
            "$SCRIPT_DIR/add_user_service.sh" "$USERNAME" "$service"
        fi
    done
else
    info "Pour ajouter des services supplémentaires:"
    echo "  cd $INSTALL_DIR/scripts"
    echo "  sudo ./add_user_service.sh $USERNAME <service>"
    echo ""
    echo "Services disponibles: sonarr, radarr, readarr, bazarr, prowlarr, overseerr, calibre"
    echo ""
    echo "Ou lancez avec --with-services pour une installation interactive:"
    echo "  sudo ./add_user.sh $USERNAME <password> <email> $QUOTA --with-services"
fi
