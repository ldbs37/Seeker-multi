#!/bin/bash

#######################
# Script d'ajout d'utilisateur
# Usage: ./add_user.sh <username> <password> <email> [quota_gb] [--admin]
#
# Crée le compte système, le compte Authelia (SSO), le dossier et le quota de
# l'utilisateur, puis ses services (qBittorrent, Homarr, Filebrowser + choix).
# Les identifiants de connexion à qBittorrent et Filebrowser sont ceux de la
# seedbox (même nom / même mot de passe).
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
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
AUTHELIA_CONFIG_DIR="$INSTALL_DIR/authelia"
ENV_FILE="$INSTALL_DIR/.env"
TZ="Europe/Paris"
DEFAULT_QUOTA="500"
AUTHELIA_IMAGE="authelia/authelia:4.39.28"
IS_ADMIN=false

# Bibliothèques partagées
for lib in lib_ports lib_traefik lib_qbittorrent lib_services lib_quota; do
    [ -f "$SCRIPT_DIR/$lib.sh" ] || error "$lib.sh introuvable dans $SCRIPT_DIR"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh"
done

# Vérification des arguments
if [ $# -lt 3 ]; then
    error "Usage: $0 <username> <password> <email> [quota_gb] [--admin]"
fi

USERNAME=$1
PASSWORD=$2
EMAIL=$3
QUOTA=$DEFAULT_QUOTA

# Arguments optionnels (ordre libre) : [quota_gb] [--admin]
# (comparaison exacte : un mot de passe contenant "--admin" ne doit PAS
#  rendre l'utilisateur administrateur)
shift 3
for arg in "$@"; do
    case "$arg" in
        --admin) IS_ADMIN=true ;;
        *)
            [[ "$arg" =~ ^[1-9][0-9]*$ ]] || error "Argument invalide : '$arg' (quota en Go ou --admin attendu)"
            QUOTA=$arg
            ;;
    esac
done

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

[ -f "$DOCKER_COMPOSE_FILE" ] || error "docker-compose.yml introuvable : lancez d'abord install.sh"

# Fuseau horaire de l'installation
if [ -f "$ENV_FILE" ] && grep -q '^TZ=' "$ENV_FILE"; then
    TZ=$(grep '^TZ=' "$ENV_FILE" | cut -d'=' -f2)
fi

#######################
# Validation
#######################

log "Validation des données..."
[[ "$USERNAME" =~ ^[a-z][a-z0-9]{0,31}$ ]] \
    || error "Nom d'utilisateur invalide: $USERNAME (lettres minuscules et chiffres uniquement, commence par une lettre, 32 max)"
[ ${#PASSWORD} -ge 12 ] || error "Le mot de passe doit contenir au moins 12 caractères"
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || error "Format d'email invalide: $EMAIL"

if id "$USERNAME" &>/dev/null || getent group "$USERNAME" >/dev/null; then
    error "L'utilisateur (ou le groupe) $USERNAME existe déjà"
fi
if grep -q "^  ${USERNAME}:" "$AUTHELIA_CONFIG_DIR/users_database.yml" 2>/dev/null; then
    error "L'utilisateur $USERNAME existe déjà dans Authelia"
fi

traefik_detect "$ENV_FILE"
if [ "$USE_TRAEFIK" = true ]; then
    info "Mode Traefik détecté (domaine: $DOMAIN)"
else
    info "Mode port direct détecté"
fi

USER_ID=$(next_seedbox_uid) || error "Plus d'UID disponible dans la plage ${SEEDBOX_UID_MIN}-${SEEDBOX_UID_MAX}"
USER_DIR="$INSTALL_DIR/data/users/$USERNAME"

#######################
# Hashs des mots de passe — AVANT toute création, pour ne rien laisser à
# moitié fait (et ne jamais écrire un compte Authelia sans mot de passe, ce
# qui empêcherait Authelia de démarrer pour TOUS les utilisateurs).
#######################

log "Préparation des identifiants..."
AUTHELIA_HASH=$(docker run --rm "$AUTHELIA_IMAGE" authelia crypto hash generate argon2 --password "$PASSWORD" 2>/dev/null \
                | grep 'Digest:' | awk '{print $2}') || true
[[ "$AUTHELIA_HASH" == \$argon2* ]] || error "Impossible de générer le hash Authelia (image $AUTHELIA_IMAGE accessible ?)"

FB_PASSWORD_HASH=$(htpasswd -nbBC 10 "" "$PASSWORD" 2>/dev/null | cut -d: -f2 | tr -d '\n') || true
[[ "$FB_PASSWORD_HASH" == \$2* ]] || error "Impossible de générer le hash Filebrowser (paquet apache2-utils requis)"

#######################
# Sélection des services (menu affiché sur stderr : la sélection seule est lue)
#######################

select_services() {
    {
        echo ""
        echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║       Sélection des services supplémentaires          ║${NC}"
        echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "${YELLOW}Inclus d'office : qBittorrent, Homarr (tableau de bord), Filebrowser${NC}"
        echo ""
        echo "  [1] 📺 Sonarr        - Gestion séries TV"
        echo "  [2] 🎬 Radarr        - Gestion films"
        echo "  [3] 📚 Readarr       - Gestion livres"
        echo "  [4] 💬 Bazarr        - Sous-titres automatiques"
        echo "  [5] 🔍 Prowlarr      - Gestion indexeurs"
        echo "  [6] 📝 Overseerr     - Système de requêtes"
        echo "  [7] 📖 Calibre-web   - Bibliothèque ebooks"
        echo ""
        echo "  Numéros séparés par des espaces (ex: 1 2 5), Entrée pour aucun"
    } >&2
    local selection num
    read -r -p "Votre sélection: " selection
    for num in $selection; do
        case $num in
            1) EXTRA_SERVICES+=("sonarr") ;;
            2) EXTRA_SERVICES+=("radarr") ;;
            3) EXTRA_SERVICES+=("readarr") ;;
            4) EXTRA_SERVICES+=("bazarr") ;;
            5) EXTRA_SERVICES+=("prowlarr") ;;
            6) EXTRA_SERVICES+=("overseerr") ;;
            7) EXTRA_SERVICES+=("calibre") ;;
            *) warn "Numéro invalide ignoré: $num" ;;
        esac
    done
}

EXTRA_SERVICES=()
if [ -t 0 ]; then
    select_services
else
    info "Mode non interactif : services de base uniquement"
fi
# Dédoublonnage en conservant l'ordre
SERVICES_TO_INSTALL=(qbittorrent homarr filebrowser)
for s in "${EXTRA_SERVICES[@]}"; do
    [[ " ${SERVICES_TO_INSTALL[*]} " == *" $s "* ]] || SERVICES_TO_INSTALL+=("$s")
done

echo ""
if [ "$IS_ADMIN" = true ]; then
    info "🔐 Création de l'utilisateur ADMINISTRATEUR $USERNAME (UID $USER_ID)"
else
    info "👤 Création de l'utilisateur $USERNAME (UID $USER_ID)"
fi
info "Services : ${SERVICES_TO_INSTALL[*]}"

#######################
# Compte système + dossiers + quota
#######################

log "Création de l'utilisateur système..."
groupadd -g "$USER_ID" "$USERNAME"
useradd -u "$USER_ID" -g "$USER_ID" -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd

log "Création des répertoires utilisateur..."
mkdir -p "$USER_DIR"/{downloads,tv,movies,books,config}
chown -R "$USER_ID:$USER_ID" "$USER_DIR"

# Quota PROJET sur le dossier de l'utilisateur (id projet = UID).
# Non-bloquant : si les quotas ne sont pas activés, la création continue.
log "Configuration du quota disque (projet)..."
if quota_project_active "$USER_DIR"; then
    quota_register_project "$USERNAME" "$USER_ID" "$USER_DIR"
    if quota_apply_project "$USER_DIR" "$USER_ID" "$QUOTA"; then
        info "Quota projet appliqué : ${QUOTA}GB sur $USER_DIR"
    else
        warn "Échec de l'application du quota projet (quota non appliqué)"
    fi
else
    warn "Quotas disque NON actifs : quota de ${QUOTA}GB non appliqué."
    info "Activez-les : sudo $INSTALL_DIR/scripts/enable_quotas.sh"
    info "Puis :        sudo $INSTALL_DIR/scripts/update_quota.sh $USERNAME $QUOTA"
fi

#######################
# Compte Authelia (SSO)
#######################

log "Ajout de l'utilisateur à Authelia..."
{
    echo ""
    echo "  ${USERNAME}:"
    echo "    displayname: \"${USERNAME}\""
    echo "    password: \"${AUTHELIA_HASH}\""
    echo "    email: \"${EMAIL}\""
    echo "    groups:"
    echo "      - users"
    [ "$IS_ADMIN" = true ] && echo "      - admins"
} >> "$AUTHELIA_CONFIG_DIR/users_database.yml"

#######################
# Services
#######################

log "Préparation des services..."
for s in "${SERVICES_TO_INSTALL[@]}"; do
    service_prepare "$s" "$PASSWORD"
done

log "Ajout des services au docker-compose.yml..."
cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.bak"
compose_append_services "$DOCKER_COMPOSE_FILE" "${SERVICES_TO_INSTALL[@]}" \
    || error "docker-compose.yml invalide après ajout des services — fichier inchangé (voir l'erreur ci-dessus)"

# Pare-feu : port torrent entrant de l'utilisateur (TCP + UDP)
TORRENT_PORT=$(user_port "$USER_ID" torrent)
if command -v ufw &>/dev/null; then
    ufw allow "$TORRENT_PORT/tcp" comment "torrent $USERNAME" >/dev/null 2>&1 || true
    ufw allow "$TORRENT_PORT/udp" comment "torrent $USERNAME" >/dev/null 2>&1 || true
fi

# Tableau de bord Homarr pré-rempli avec les liens de l'utilisateur (généré
# avant le premier démarrage de Homarr)
"$SCRIPT_DIR/configure_homarr.sh" "$USERNAME" >/dev/null 2>&1 \
    || warn "Configuration Homarr non appliquée (relancez : $SCRIPT_DIR/configure_homarr.sh $USERNAME)"

log "Démarrage des conteneurs..."
cd "$INSTALL_DIR"
compose_cmd up -d

# Authelia relit sa base utilisateurs au redémarrage
docker restart authelia >/dev/null 2>&1 || warn "Redémarrez Authelia pour activer le compte : docker restart authelia"

#######################
# Résumé
#######################

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
info "🔌 Port torrent entrant: $TORRENT_PORT (TCP/UDP)"
echo ""
info "🌐 Services :"
for s in "${SERVICES_TO_INSTALL[@]}"; do
    printf "   • %-12s %s\n" "$s" "$(service_url "$s")"
done
echo ""
if [ "$USE_TRAEFIK" = true ]; then
    info "💡 Connexion : identifiez-vous sur https://auth.$DOMAIN (SSO)."
    info "   qBittorrent et Filebrowser demandent ensuite les mêmes identifiants."
else
    info "💡 qBittorrent et Filebrowser : mêmes identifiants que la seedbox."
fi
echo ""
info "Pour ajouter d'autres services plus tard:"
echo "   sudo $INSTALL_DIR/scripts/add_user_service.sh $USERNAME <service>"
