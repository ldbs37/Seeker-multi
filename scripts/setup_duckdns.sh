#!/bin/bash

#######################
# Script d'automatisation DNS avec DuckDNS
# Configure automatiquement un sous-domaine DuckDNS avec wildcard
# Usage: ./setup_duckdns.sh
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
DUCKDNS_TOKEN=""
DUCKDNS_SUBDOMAIN=""
DUCKDNS_DOMAIN=""
SERVER_IP=""
INSTALL_DIR="/opt/seedbox"
ENV_FILE="$INSTALL_DIR/.env"

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Obtenir l'IP publique du serveur
get_server_ip() {
    log "Détection de l'IP publique du serveur..."

    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)

    if [ -z "$SERVER_IP" ]; then
        error "Impossible de détecter l'IP publique du serveur"
    fi

    success "IP du serveur: $SERVER_IP"
}

# Demander les informations DuckDNS
prompt_duckdns_info() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}   Configuration DuckDNS${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    info "DuckDNS est un service DNS gratuit avec wildcard automatique"
    echo ""
    info "Pour obtenir votre token DuckDNS:"
    echo "  1. Allez sur https://www.duckdns.org/"
    echo "  2. Connectez-vous avec GitHub, Google, Reddit ou Twitter"
    echo "  3. Copiez votre token en haut de la page"
    echo ""

    read -p "Votre token DuckDNS: " DUCKDNS_TOKEN

    if [ -z "$DUCKDNS_TOKEN" ]; then
        error "Le token DuckDNS est requis"
    fi

    echo ""
    info "Choisissez un nom de sous-domaine (ex: monseedbox)"
    info "Votre domaine complet sera: <subdomain>.duckdns.org"
    echo ""

    read -p "Nom du sous-domaine: " DUCKDNS_SUBDOMAIN

    if [ -z "$DUCKDNS_SUBDOMAIN" ]; then
        error "Le nom de sous-domaine est requis"
    fi

    # Nettoyer le sous-domaine (enlever .duckdns.org si présent)
    DUCKDNS_SUBDOMAIN=$(echo "$DUCKDNS_SUBDOMAIN" | sed 's/\.duckdns\.org$//')

    # Créer le domaine complet
    DUCKDNS_DOMAIN="${DUCKDNS_SUBDOMAIN}.duckdns.org"

    success "Domaine configuré: $DUCKDNS_DOMAIN"
}

# Mettre à jour l'IP sur DuckDNS
update_duckdns_ip() {
    local show_output=${1:-true}

    if [ "$show_output" = "true" ]; then
        log "Mise à jour de l'IP sur DuckDNS..."
    fi

    local response=$(curl -s "https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=$SERVER_IP")

    if [ "$response" = "OK" ]; then
        if [ "$show_output" = "true" ]; then
            success "✓ IP mise à jour: $DUCKDNS_DOMAIN → $SERVER_IP"
        fi
        return 0
    elif [ "$response" = "KO" ]; then
        if [ "$show_output" = "true" ]; then
            error "Échec de la mise à jour (token ou sous-domaine invalide)"
        fi
        return 1
    else
        if [ "$show_output" = "true" ]; then
            error "Réponse inattendue de DuckDNS: $response"
        fi
        return 1
    fi
}

# Créer un script de mise à jour pour cron
create_update_script() {
    log "Création du script de mise à jour automatique..."

    local update_script="$INSTALL_DIR/scripts/duckdns_update.sh"

    cat > "$update_script" << 'EOF'
#!/bin/bash
# Script de mise à jour automatique DuckDNS
# Généré automatiquement par setup_duckdns.sh

DUCKDNS_TOKEN="DUCKDNS_TOKEN_PLACEHOLDER"
DUCKDNS_SUBDOMAIN="DUCKDNS_SUBDOMAIN_PLACEHOLDER"
SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)

curl -s "https://www.duckdns.org/update?domains=$DUCKDNS_SUBDOMAIN&token=$DUCKDNS_TOKEN&ip=$SERVER_IP" > /dev/null
EOF

    # Remplacer les placeholders
    sed -i "s/DUCKDNS_TOKEN_PLACEHOLDER/$DUCKDNS_TOKEN/" "$update_script"
    sed -i "s/DUCKDNS_SUBDOMAIN_PLACEHOLDER/$DUCKDNS_SUBDOMAIN/" "$update_script"

    chmod +x "$update_script"

    success "Script de mise à jour créé: $update_script"
}

# Installer le cron job
install_cron_job() {
    log "Installation du cron job pour mise à jour automatique..."

    local update_script="$INSTALL_DIR/scripts/duckdns_update.sh"
    local cron_line="*/5 * * * * $update_script >/dev/null 2>&1"

    # Vérifier si le cron existe déjà
    if crontab -l 2>/dev/null | grep -q "$update_script"; then
        info "Cron job déjà installé"
    else
        # Ajouter le cron job
        (crontab -l 2>/dev/null; echo "$cron_line") | crontab -
        success "✓ Cron job installé (mise à jour toutes les 5 minutes)"
    fi

    info "Commandes utiles:"
    echo "  - Voir les crons: crontab -l"
    echo "  - Forcer une mise à jour: $update_script"
    echo "  - Supprimer le cron: crontab -e"
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
            sed -i "s|^DOMAIN=.*|DOMAIN=$DUCKDNS_DOMAIN|" "$ENV_FILE"
        else
            echo "DOMAIN=$DUCKDNS_DOMAIN" >> "$ENV_FILE"
        fi
    else
        # Créer .env
        cat > "$ENV_FILE" << EOF
# Configuration Seedbox Multi-Utilisateurs
DOMAIN=$DUCKDNS_DOMAIN
EOF
    fi

    success "Configuration sauvegardée dans $ENV_FILE"
}

# Programme principal
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}   Configuration DNS DuckDNS${NC}"
echo -e "${BLUE}========================================${NC}\n"

# 1. Obtenir l'IP du serveur
get_server_ip

# 2. Demander les informations DuckDNS
prompt_duckdns_info

echo ""

# 3. Mettre à jour l'IP sur DuckDNS
if ! update_duckdns_ip; then
    error "Impossible de configurer DuckDNS. Vérifiez votre token et sous-domaine."
fi

echo ""

# 4. Créer le script de mise à jour
create_update_script

echo ""

# 5. Installer le cron job
install_cron_job

echo ""

# 6. Sauvegarder dans .env
save_to_env

echo ""

# 7. Vérification DNS
log "Vérification de la configuration DNS..."
info "Attente de la propagation DNS (30 secondes)..."
sleep 30

echo ""

if ./scripts/check_dns.sh "$DUCKDNS_DOMAIN" 2>/dev/null; then
    echo ""
    success "Configuration DuckDNS terminée avec succès !"
    echo ""
    info "Votre domaine: $DUCKDNS_DOMAIN"
    info "Wildcard automatique: *.$DUCKDNS_DOMAIN"
    echo ""
    info "Caractéristiques:"
    echo "  ✓ Mise à jour automatique de l'IP (toutes les 5 minutes)"
    echo "  ✓ Wildcard DNS automatique (tous les sous-domaines)"
    echo "  ✓ SSL Let's Encrypt compatible"
    echo "  ✓ 100% gratuit"
    echo ""
    info "Prochaines étapes:"
    echo "  1. Installez Traefik avec: sudo ./scripts/setup_traefik.sh $DUCKDNS_DOMAIN"
    echo "  2. Créez vos utilisateurs avec: sudo ./scripts/add_user.sh"
    echo ""
else
    warn "La vérification DNS a échoué"
    warn "Cela peut être normal si la propagation DNS n'est pas terminée"
    echo ""
    info "Actions à faire:"
    echo "  1. Attendez 5-10 minutes pour la propagation DNS"
    echo "  2. Testez manuellement: ping $DUCKDNS_DOMAIN"
    echo "  3. Vérifiez avec: ./scripts/check_dns.sh $DUCKDNS_DOMAIN"
    echo "  4. Si OK, installez Traefik: sudo ./scripts/setup_traefik.sh $DUCKDNS_DOMAIN"
fi
