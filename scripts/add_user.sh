#!/bin/bash

#######################
# Script d'ajout d'utilisateur
# Usage: ./add_user.sh <username> <password> <email> [quota_gb] [--admin]
#######################

set -e

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
IS_ADMIN=false

# Vérification des arguments
if [ $# -lt 3 ]; then
    error "Usage: $0 <username> <password> <email> [quota_gb] [--admin]"
fi

USERNAME=$1
PASSWORD=$2
EMAIL=$3
QUOTA=${4:-$DEFAULT_QUOTA}

# Vérifier si le flag --admin est présent
if [[ "$*" == *"--admin"* ]]; then
    IS_ADMIN=true
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

# Menu de sélection des services
select_services() {
    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       Sélection des services supplémentaires          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}Services disponibles:${NC}"
    echo ""
    echo "  [1] 🖥️  Homarr        - Dashboard personnel"
    echo "  [2] 📂 Filebrowser   - Gestionnaire de fichiers web"
    echo "  [3] 📺 Sonarr        - Gestion séries TV"
    echo "  [4] 🎬 Radarr        - Gestion films"
    echo "  [5] 📚 Readarr       - Gestion livres"
    echo "  [6] 💬 Bazarr        - Sous-titres automatiques"
    echo "  [7] 🔍 Prowlarr      - Gestion indexeurs"
    echo "  [8] 📝 Overseerr     - Système de requêtes"
    echo "  [9] 📖 Calibre-web   - Bibliothèque ebooks"
    echo ""
    echo -e "${YELLOW}Note: qBittorrent est installé automatiquement${NC}"
    if [ "$IS_ADMIN" = true ]; then
        echo -e "${YELLOW}Note: Homarr et Filebrowser sont installés automatiquement pour l'admin${NC}"
    fi
    echo ""
    echo -e "${BLUE}Instructions:${NC}"
    echo "  - Entrez les numéros des services à installer séparés par des espaces"
    echo "  - Exemple: 1 3 4 7 (pour Homarr, Sonarr, Radarr, Prowlarr)"
    echo "  - Appuyez sur Entrée sans rien saisir pour passer"
    echo ""

    read -p "Votre sélection: " selection

    # Convertir la sélection en tableau
    declare -a SELECTED_SERVICES=()

    for num in $selection; do
        case $num in
            1) SELECTED_SERVICES+=("homarr") ;;
            2) SELECTED_SERVICES+=("filebrowser") ;;
            3) SELECTED_SERVICES+=("sonarr") ;;
            4) SELECTED_SERVICES+=("radarr") ;;
            5) SELECTED_SERVICES+=("readarr") ;;
            6) SELECTED_SERVICES+=("bazarr") ;;
            7) SELECTED_SERVICES+=("prowlarr") ;;
            8) SELECTED_SERVICES+=("overseerr") ;;
            9) SELECTED_SERVICES+=("calibre") ;;
            *) warn "Numéro invalide ignoré: $num" ;;
        esac
    done

    # Retourner le tableau
    echo "${SELECTED_SERVICES[@]}"
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
log "ID utilisateur attribué: $USER_ID"

# Afficher le type d'utilisateur
if [ "$IS_ADMIN" = true ]; then
    echo ""
    info "🔐 Création d'un utilisateur ADMINISTRATEUR"
    info "   Services inclus: qBittorrent + Homarr + Filebrowser"
else
    echo ""
    info "👤 Création d'un utilisateur STANDARD"
    info "   Service inclus: qBittorrent (obligatoire)"
fi

# Calculer les ports
BASE_PORT=$((USER_ID - 1000))
QBIT_PORT=$((8080 + BASE_PORT * 10))
HOMARR_PORT=$((7575 + BASE_PORT))
FILEBROWSER_PORT=$((8081 + BASE_PORT))

# Créer l'utilisateur système
log "Création de l'utilisateur système..."
useradd -u "$USER_ID" -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

# Créer les répertoires
log "Création des répertoires utilisateur..."
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"
mkdir -p "$USER_DIR"/{downloads,config,data}
chown -R "$USER_ID:$USER_ID" "$USER_DIR"

# Configurer les quotas
log "Configuration des quotas..."
if command -v setquota &>/dev/null; then
    setquota -u "$USERNAME" "$((QUOTA * 1024 * 1024))" "$((QUOTA * 1024 * 1024))" 0 0 /
    info "Quota défini: ${QUOTA}GB"
else
    warn "Quotas non disponibles sur ce système"
fi

# Ajouter l'utilisateur à Authelia
log "Ajout de l'utilisateur à Authelia..."
HASHED_PASSWORD=$(docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "$PASSWORD" | grep 'Digest:' | awk '{print $2}')

if [ "$IS_ADMIN" = true ]; then
    cat >> "$AUTHELIA_CONFIG_DIR/users_database.yml" << EOF

  $USERNAME:
    displayname: "$USERNAME"
    password: "$HASHED_PASSWORD"
    email: "$EMAIL"
    groups:
      - users
      - admins
EOF
else
    cat >> "$AUTHELIA_CONFIG_DIR/users_database.yml" << EOF

  $USERNAME:
    displayname: "$USERNAME"
    password: "$HASHED_PASSWORD"
    email: "$EMAIL"
    groups:
      - users
EOF
fi

# Sélection des services supplémentaires
SERVICES_TO_INSTALL=()

# Demander la sélection
SELECTED=$(select_services)
if [ -n "$SELECTED" ]; then
    read -ra SERVICES_TO_INSTALL <<< "$SELECTED"
fi

# Ajouter automatiquement Homarr et Filebrowser pour TOUS les utilisateurs
if [[ ! " ${SERVICES_TO_INSTALL[@]} " =~ " homarr " ]]; then
    SERVICES_TO_INSTALL+=("homarr")
fi
if [[ ! " ${SERVICES_TO_INSTALL[@]} " =~ " filebrowser " ]]; then
    SERVICES_TO_INSTALL+=("filebrowser")
fi

# Afficher le récapitulatif
echo ""
log "Services qui seront installés:"
echo "  ✓ qBittorrent (obligatoire)"
if [ ${#SERVICES_TO_INSTALL[@]} -gt 0 ]; then
    for service in "${SERVICES_TO_INSTALL[@]}"; do
        echo "  ✓ $service"
    done
else
    echo "  (aucun service supplémentaire)"
fi

# Ajouter qBittorrent (obligatoire)
log "Ajout de qBittorrent au docker-compose..."

cat >> "$DOCKER_COMPOSE_FILE" << EOF

  qbittorrent-$USERNAME:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent-$USERNAME
    environment:
      - PUID=$USER_ID
      - PGID=$USER_ID
      - TZ=$TZ
      - WEBUI_PORT=$QBIT_PORT
    volumes:
      - $USER_DIR/config/qbittorrent:/config
      - $USER_DIR/downloads:/downloads
    ports:
      - "$QBIT_PORT:$QBIT_PORT"
    restart: unless-stopped
EOF

info "✓ qBittorrent configuré (port $QBIT_PORT)"

# Ajouter les services sélectionnés
for service in "${SERVICES_TO_INSTALL[@]}"; do
    log "Ajout de $service..."

    case $service in
        homarr)
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  homarr-$USERNAME:
    image: ghcr.io/ajnart/homarr:latest
    container_name: homarr-$USERNAME
    environment:
      - PUID=$USER_ID
      - PGID=$USER_ID
      - TZ=$TZ
    volumes:
      - $USER_DIR/config/homarr:/app/data/configs
      - $USER_DIR/config/homarr-icons:/app/public/icons
    ports:
      - "$HOMARR_PORT:7575"
    restart: unless-stopped
EOF
            info "✓ Homarr configuré (port $HOMARR_PORT)"
            ;;

        filebrowser)
            cat >> "$DOCKER_COMPOSE_FILE" << EOF

  filebrowser-$USERNAME:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser-$USERNAME
    environment:
      - PUID=$USER_ID
      - PGID=$USER_ID
      - TZ=$TZ
    volumes:
      - $USER_DIR:/srv
      - $USER_DIR/config/filebrowser/filebrowser.db:/database.db
    ports:
      - "$FILEBROWSER_PORT:80"
    restart: unless-stopped
EOF
            info "✓ Filebrowser configuré (port $FILEBROWSER_PORT)"
            ;;

        sonarr|radarr|readarr|bazarr|prowlarr|overseerr|calibre)
            # Appeler add_user_service.sh pour ces services
            "$INSTALL_DIR/scripts/add_user_service.sh" "$USERNAME" "$service" || warn "Erreur lors de l'ajout de $service"
            ;;
    esac
done

# Redémarrer Docker Compose
log "Démarrage des conteneurs..."
cd "$INSTALL_DIR"
docker-compose up -d

echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            Utilisateur créé avec succès !              ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

if [ "$IS_ADMIN" = true ]; then
    info "👤 Utilisateur ADMINISTRATEUR: $USERNAME"
else
    info "👤 Utilisateur: $USERNAME"
fi
info "📧 Email: $EMAIL"
info "🆔 UID: $USER_ID"
info "💾 Quota: ${QUOTA}GB"
echo ""
info "🌐 Services accessibles:"
echo "   • qBittorrent: http://votre-serveur:$QBIT_PORT"

if [[ " ${SERVICES_TO_INSTALL[@]} " =~ " homarr " ]]; then
    echo "   • Homarr: http://votre-serveur:$HOMARR_PORT"
fi

if [[ " ${SERVICES_TO_INSTALL[@]} " =~ " filebrowser " ]]; then
    echo "   • Filebrowser: http://votre-serveur:$FILEBROWSER_PORT"
fi

echo ""
info "Pour ajouter d'autres services plus tard:"
echo "   sudo $INSTALL_DIR/scripts/add_user_service.sh $USERNAME <service>"
