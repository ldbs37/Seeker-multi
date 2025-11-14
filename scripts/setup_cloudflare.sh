#!/bin/bash

#######################
# Script d'automatisation DNS avec Cloudflare
# Configure automatiquement les enregistrements wildcard via l'API Cloudflare
# Usage: ./setup_cloudflare.sh
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
CLOUDFLARE_API_TOKEN=""
DOMAIN=""
ZONE_ID=""
SERVER_IP=""

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

# Demander les informations Cloudflare
prompt_cloudflare_info() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Configuration Cloudflare${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    info "Pour obtenir votre API Token Cloudflare:"
    echo "  1. Allez sur https://dash.cloudflare.com/profile/api-tokens"
    echo "  2. Cliquez sur 'Create Token'"
    echo "  3. Utilisez le template 'Edit zone DNS'"
    echo "  4. Sélectionnez votre zone (domaine)"
    echo "  5. Copiez le token généré"
    echo ""

    read -p "Votre API Token Cloudflare: " CLOUDFLARE_API_TOKEN

    if [ -z "$CLOUDFLARE_API_TOKEN" ]; then
        error "Le token API est requis"
    fi

    echo ""
    read -p "Votre nom de domaine (ex: monseedbox.com): " DOMAIN

    if [ -z "$DOMAIN" ]; then
        error "Le nom de domaine est requis"
    fi
}

# Tester la connexion à l'API Cloudflare
test_cloudflare_api() {
    log "Test de connexion à l'API Cloudflare..."

    local response=$(curl -s -X GET "https://api.cloudflare.com/v4/user/tokens/verify" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")

    local success_status=$(echo "$response" | jq -r '.success')

    if [ "$success_status" != "true" ]; then
        error "Token API invalide ou expiré"
    fi

    success "Token API valide"
}

# Récupérer le Zone ID
get_zone_id() {
    log "Récupération du Zone ID pour $DOMAIN..."

    local response=$(curl -s -X GET "https://api.cloudflare.com/v4/zones?name=$DOMAIN" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")

    ZONE_ID=$(echo "$response" | jq -r '.result[0].id')

    if [ -z "$ZONE_ID" ] || [ "$ZONE_ID" = "null" ]; then
        error "Zone non trouvée. Vérifiez que le domaine $DOMAIN est bien configuré sur Cloudflare"
    fi

    success "Zone ID trouvé: $ZONE_ID"
}

# Vérifier si un enregistrement existe
check_record_exists() {
    local record_name=$1
    local record_type=$2

    local response=$(curl -s -X GET \
        "https://api.cloudflare.com/v4/zones/$ZONE_ID/dns_records?type=$record_type&name=$record_name" \
        -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
        -H "Content-Type: application/json")

    local record_id=$(echo "$response" | jq -r '.result[0].id')

    if [ -z "$record_id" ] || [ "$record_id" = "null" ]; then
        echo ""
    else
        echo "$record_id"
    fi
}

# Créer ou mettre à jour un enregistrement DNS
create_or_update_record() {
    local record_name=$1
    local record_type=$2
    local record_content=$3

    log "Configuration de l'enregistrement $record_type pour $record_name..."

    # Vérifier si l'enregistrement existe
    local existing_id=$(check_record_exists "$record_name" "$record_type")

    if [ -n "$existing_id" ]; then
        # Mise à jour
        info "Enregistrement existant trouvé, mise à jour..."

        local response=$(curl -s -X PUT \
            "https://api.cloudflare.com/v4/zones/$ZONE_ID/dns_records/$existing_id" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"$record_type\",
                \"name\": \"$record_name\",
                \"content\": \"$record_content\",
                \"ttl\": 1,
                \"proxied\": false
            }")

        local success_status=$(echo "$response" | jq -r '.success')

        if [ "$success_status" = "true" ]; then
            success "✓ Enregistrement mis à jour: $record_name → $record_content"
        else
            local error_msg=$(echo "$response" | jq -r '.errors[0].message')
            error "Échec de la mise à jour: $error_msg"
        fi
    else
        # Création
        info "Création du nouvel enregistrement..."

        local response=$(curl -s -X POST \
            "https://api.cloudflare.com/v4/zones/$ZONE_ID/dns_records" \
            -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
            -H "Content-Type: application/json" \
            --data "{
                \"type\": \"$record_type\",
                \"name\": \"$record_name\",
                \"content\": \"$record_content\",
                \"ttl\": 1,
                \"proxied\": false
            }")

        local success_status=$(echo "$response" | jq -r '.success')

        if [ "$success_status" = "true" ]; then
            success "✓ Enregistrement créé: $record_name → $record_content"
        else
            local error_msg=$(echo "$response" | jq -r '.errors[0].message')
            error "Échec de la création: $error_msg"
        fi
    fi
}

# Programme principal
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}   Configuration DNS Cloudflare${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 1. Vérifier les dépendances
check_dependencies

echo ""

# 2. Obtenir l'IP du serveur
get_server_ip

# 3. Demander les informations Cloudflare
prompt_cloudflare_info

echo ""

# 4. Tester l'API
test_cloudflare_api

echo ""

# 5. Récupérer le Zone ID
get_zone_id

echo ""

# 6. Créer les enregistrements DNS
log "Création des enregistrements DNS..."

echo ""

# Enregistrement A pour le domaine principal
create_or_update_record "$DOMAIN" "A" "$SERVER_IP"

# Enregistrement A pour le wildcard
create_or_update_record "*.$DOMAIN" "A" "$SERVER_IP"

echo ""

# 7. Vérification
log "Vérification de la configuration DNS..."
sleep 3

if ./scripts/check_dns.sh "$DOMAIN"; then
    echo ""
    success "Configuration DNS Cloudflare terminée avec succès !"
    echo ""
    info "Les enregistrements DNS ont été créés:"
    echo "  - $DOMAIN → $SERVER_IP"
    echo "  - *.$DOMAIN → $SERVER_IP"
    echo ""
    info "Propagation DNS: 1-5 minutes (TTL automatique Cloudflare)"
    echo ""
    info "Prochaines étapes:"
    echo "  1. Attendez quelques minutes pour la propagation DNS"
    echo "  2. Installez Traefik avec: sudo ./scripts/setup_traefik.sh $DOMAIN"
    echo ""
else
    warn "La vérification DNS a échoué, mais les enregistrements ont été créés"
    warn "Attendez quelques minutes et relancez: ./scripts/check_dns.sh $DOMAIN"
fi
