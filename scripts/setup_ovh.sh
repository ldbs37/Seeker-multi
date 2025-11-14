#!/bin/bash

#######################
# Script d'automatisation DNS avec OVH
# Configure automatiquement les enregistrements wildcard via l'API OVH
# Usage: ./setup_ovh.sh
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
success() { echo -e "${GREEN}[✓]${NC} $1"; }

# Variables
OVH_APP_KEY=""
OVH_APP_SECRET=""
OVH_CONSUMER_KEY=""
DOMAIN=""
OVH_ENDPOINT="ovh-eu"  # ovh-eu, ovh-ca, ovh-us, etc.
SERVER_IP=""
INSTALL_DIR="/opt/seedbox"
ENV_FILE="$INSTALL_DIR/.env"

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Vérification des dépendances
check_dependencies() {
    log "Vérification des dépendances..."

    if ! command -v curl &> /dev/null; then
        error "curl est requis mais non installé. Installez-le avec: apt install curl"
    fi

    if ! command -v jq &> /dev/null; then
        warn "jq n'est pas installé. Installation automatique..."
        apt-get update -qq && apt-get install -y jq -qq
    fi

    if ! command -v openssl &> /dev/null; then
        error "openssl est requis mais non installé"
    fi

    success "Toutes les dépendances sont installées"
}

# Obtenir l'IP publique du serveur
get_server_ip() {
    log "Détection de l'IP publique du serveur..."

    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)

    if [ -z "$SERVER_IP" ]; then
        error "Impossible de détecter l'IP publique du serveur"
    fi

    success "IP du serveur: $SERVER_IP"
}

# Demander les informations OVH
prompt_ovh_info() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Configuration OVH${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    info "Pour obtenir vos clés API OVH:"
    echo "  1. Allez sur https://api.ovh.com/createToken/"
    echo "  2. Connectez-vous avec votre compte OVH"
    echo "  3. Remplissez le formulaire:"
    echo "     - Application name: Seedbox DNS"
    echo "     - Application description: Gestion DNS automatique"
    echo "     - Validity: Unlimited"
    echo "  4. Droits requis:"
    echo "     - GET /domain/zone/*"
    echo "     - POST /domain/zone/*"
    echo "     - PUT /domain/zone/*"
    echo "     - DELETE /domain/zone/*"
    echo "  5. Copiez les 3 clés générées"
    echo ""

    read -p "Application Key: " OVH_APP_KEY
    if [ -z "$OVH_APP_KEY" ]; then
        error "Application Key est requise"
    fi

    read -p "Application Secret: " OVH_APP_SECRET
    if [ -z "$OVH_APP_SECRET" ]; then
        error "Application Secret est requise"
    fi

    read -p "Consumer Key: " OVH_CONSUMER_KEY
    if [ -z "$OVH_CONSUMER_KEY" ]; then
        error "Consumer Key est requise"
    fi

    echo ""
    read -p "Votre nom de domaine (ex: monseedbox.com): " DOMAIN

    if [ -z "$DOMAIN" ]; then
        error "Le nom de domaine est requis"
    fi

    echo ""
    read -p "Endpoint OVH [ovh-eu]: " input_endpoint
    OVH_ENDPOINT=${input_endpoint:-ovh-eu}

    # Définir l'URL de l'API selon l'endpoint
    case $OVH_ENDPOINT in
        ovh-eu)
            OVH_API_URL="https://eu.api.ovh.com/1.0"
            ;;
        ovh-ca)
            OVH_API_URL="https://ca.api.ovh.com/1.0"
            ;;
        ovh-us)
            OVH_API_URL="https://api.us.ovhcloud.com/1.0"
            ;;
        *)
            error "Endpoint OVH invalide. Choisissez: ovh-eu, ovh-ca, ovh-us"
            ;;
    esac

    success "Configuration OVH enregistrée"
}

# Fonction pour signer les requêtes OVH
ovh_sign_request() {
    local method=$1
    local query=$2
    local body=$3
    local timestamp=$4

    # Signature OVH: "$1+$2+$3+$4+$5+$6"
    # $1 = AS
    # $2 = CK
    # $3 = METHOD
    # $4 = QUERY
    # $5 = BODY
    # $6 = TIMESTAMP

    local to_sign="${OVH_APP_SECRET}+${OVH_CONSUMER_KEY}+${method}+${query}+${body}+${timestamp}"
    local signature=$(echo -n "$to_sign" | sha1sum | awk '{print $1}')
    echo "\$1\$${signature}"
}

# Fonction pour effectuer une requête OVH API
ovh_api_call() {
    local method=$1
    local endpoint=$2
    local data=${3:-""}

    local timestamp=$(date +%s)
    local query="${OVH_API_URL}${endpoint}"

    local signature=$(ovh_sign_request "$method" "$query" "$data" "$timestamp")

    local response

    if [ "$method" = "GET" ]; then
        response=$(curl -s -X GET "$query" \
            -H "X-Ovh-Application: $OVH_APP_KEY" \
            -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
            -H "X-Ovh-Signature: $signature" \
            -H "X-Ovh-Timestamp: $timestamp" \
            -H "Content-Type: application/json")
    else
        response=$(curl -s -X "$method" "$query" \
            -H "X-Ovh-Application: $OVH_APP_KEY" \
            -H "X-Ovh-Consumer: $OVH_CONSUMER_KEY" \
            -H "X-Ovh-Signature: $signature" \
            -H "X-Ovh-Timestamp: $timestamp" \
            -H "Content-Type: application/json" \
            -d "$data")
    fi

    echo "$response"
}

# Tester la connexion à l'API OVH
test_ovh_api() {
    log "Test de connexion à l'API OVH..."

    local response=$(ovh_api_call "GET" "/me")

    if echo "$response" | jq -e '.nichandle' &>/dev/null; then
        local nichandle=$(echo "$response" | jq -r '.nichandle')
        success "Connexion API réussie (compte: $nichandle)"
    else
        error "Échec de la connexion à l'API OVH. Vérifiez vos clés."
    fi
}

# Vérifier que la zone DNS existe
check_dns_zone() {
    log "Vérification de la zone DNS pour $DOMAIN..."

    local response=$(ovh_api_call "GET" "/domain/zone/$DOMAIN")

    if echo "$response" | jq -e '.name' &>/dev/null; then
        success "Zone DNS trouvée pour $DOMAIN"
    else
        error "Zone DNS non trouvée pour $DOMAIN. Vérifiez que le domaine est géré par OVH."
    fi
}

# Récupérer les enregistrements existants
get_existing_records() {
    local subdomain=$1
    local record_type=$2

    local response=$(ovh_api_call "GET" "/domain/zone/$DOMAIN/record?fieldType=$record_type&subDomain=$subdomain")

    echo "$response"
}

# Créer ou mettre à jour un enregistrement DNS
create_or_update_record() {
    local subdomain=$1
    local record_type=$2
    local target=$3

    log "Configuration de l'enregistrement $record_type pour $subdomain..."

    # Vérifier si l'enregistrement existe
    local existing_ids=$(get_existing_records "$subdomain" "$record_type")

    if [ "$existing_ids" != "[]" ]; then
        # Supprimer les enregistrements existants
        info "Suppression des enregistrements existants..."

        echo "$existing_ids" | jq -r '.[]' | while read record_id; do
            ovh_api_call "DELETE" "/domain/zone/$DOMAIN/record/$record_id" > /dev/null
        done

        success "Enregistrements existants supprimés"
    fi

    # Créer le nouvel enregistrement
    info "Création du nouvel enregistrement..."

    local data="{\"fieldType\":\"$record_type\",\"subDomain\":\"$subdomain\",\"target\":\"$target\",\"ttl\":300}"

    local response=$(ovh_api_call "POST" "/domain/zone/$DOMAIN/record" "$data")

    if echo "$response" | jq -e '.id' &>/dev/null; then
        success "✓ Enregistrement créé: $subdomain.$DOMAIN → $target"
    else
        error "Échec de la création de l'enregistrement"
    fi
}

# Appliquer les changements de zone
refresh_zone() {
    log "Application des changements DNS..."

    local response=$(ovh_api_call "POST" "/domain/zone/$DOMAIN/refresh" "")

    if [ -n "$response" ]; then
        success "✓ Changements DNS appliqués"
    else
        warn "Impossible de vérifier l'application des changements"
    fi
}

# Sauvegarder la configuration dans .env
save_to_env() {
    log "Sauvegarde de la configuration..."

    # Créer le dossier si nécessaire
    mkdir -p "$(dirname "$ENV_FILE")"

    # Vérifier si .env existe
    if [ -f "$ENV_FILE" ]; then
        # Mettre à jour ou ajouter DOMAIN
        if grep -q "^DOMAIN=" "$ENV_FILE"; then
            sed -i "s|^DOMAIN=.*|DOMAIN=$DOMAIN|" "$ENV_FILE"
        else
            echo "DOMAIN=$DOMAIN" >> "$ENV_FILE"
        fi
    else
        # Créer .env
        cat > "$ENV_FILE" << EOF
# Configuration Seedbox Multi-Utilisateurs
DOMAIN=$DOMAIN
EOF
    fi

    success "Configuration sauvegardée dans $ENV_FILE"
}

# Programme principal
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}   Configuration DNS OVH${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 1. Vérifier les dépendances
check_dependencies

echo ""

# 2. Obtenir l'IP du serveur
get_server_ip

# 3. Demander les informations OVH
prompt_ovh_info

echo ""

# 4. Tester l'API
test_ovh_api

echo ""

# 5. Vérifier la zone DNS
check_dns_zone

echo ""

# 6. Créer les enregistrements DNS
log "Création des enregistrements DNS..."

echo ""

# Enregistrement A pour le domaine principal
create_or_update_record "" "A" "$SERVER_IP"

# Enregistrement A pour le wildcard
create_or_update_record "*" "A" "$SERVER_IP"

echo ""

# 7. Appliquer les changements
refresh_zone

echo ""

# 8. Sauvegarder dans .env
save_to_env

echo ""

# 9. Vérification
log "Vérification de la configuration DNS..."
info "Attente de la propagation DNS (30 secondes)..."
sleep 30

echo ""

if [ -x "$INSTALL_DIR/scripts/check_dns.sh" ]; then
    if "$INSTALL_DIR/scripts/check_dns.sh" "$DOMAIN"; then
        echo ""
        success "Configuration DNS OVH terminée avec succès !"
        echo ""
        info "Enregistrements créés:"
        echo "  - $DOMAIN → $SERVER_IP"
        echo "  - *.$DOMAIN → $SERVER_IP"
        echo ""
        info "Propagation DNS: 5-30 minutes (selon le TTL)"
        echo ""
        info "Prochaines étapes:"
        echo "  1. Attendez quelques minutes pour la propagation DNS"
        echo "  2. Installez Traefik avec: sudo ./scripts/setup_traefik.sh $DOMAIN"
        echo ""
    else
        warn "La vérification DNS a échoué, mais les enregistrements ont été créés"
        warn "Attendez quelques minutes et relancez: ./scripts/check_dns.sh $DOMAIN"
    fi
else
    info "Vérification DNS non disponible"
    info "Les enregistrements ont été créés sur OVH"
    info "Vérifiez manuellement avec: dig $DOMAIN +short"
fi
