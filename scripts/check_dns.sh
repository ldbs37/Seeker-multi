#!/bin/bash

#######################
# Script de vérification DNS pour Traefik
# Usage: ./check_dns.sh <domain>
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
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }

# Vérification des arguments
if [ $# -ne 1 ]; then
    echo "Usage: $0 <domain>"
    echo ""
    echo "Exemple: $0 monseedbox.com"
    echo ""
    echo "Ce script vérifie:"
    echo "  - La résolution DNS du domaine principal"
    echo "  - La résolution DNS du wildcard (*.domain)"
    echo "  - L'accessibilité des ports 80 et 443"
    echo "  - La propagation DNS"
    exit 1
fi

DOMAIN=$1
SERVER_IP=""

# Fonction pour obtenir l'IP publique du serveur
get_server_ip() {
    info "Détection de l'IP publique du serveur..."

    # Essayer plusieurs services
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || curl -s ipecho.net/plain)

    if [ -z "$SERVER_IP" ]; then
        error "Impossible de détecter l'IP publique du serveur"
        return 1
    fi

    success "IP du serveur détectée: $SERVER_IP"
}

# Fonction pour vérifier la résolution DNS
check_dns_resolution() {
    local test_domain=$1
    local expected_ip=$2

    info "Vérification de $test_domain..."

    # Tester avec dig
    if command -v dig &> /dev/null; then
        local resolved_ip=$(dig +short "$test_domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)

        if [ -z "$resolved_ip" ]; then
            error "❌ $test_domain ne résout vers aucune IP"
            return 1
        elif [ "$resolved_ip" != "$expected_ip" ]; then
            error "❌ $test_domain résout vers $resolved_ip au lieu de $expected_ip"
            return 1
        else
            success "✓ $test_domain résout correctement vers $expected_ip"
            return 0
        fi
    # Fallback sur nslookup
    elif command -v nslookup &> /dev/null; then
        local resolved_ip=$(nslookup "$test_domain" | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -n1)

        if [ -z "$resolved_ip" ]; then
            error "❌ $test_domain ne résout vers aucune IP"
            return 1
        elif [ "$resolved_ip" != "$expected_ip" ]; then
            error "❌ $test_domain résout vers $resolved_ip au lieu de $expected_ip"
            return 1
        else
            success "✓ $test_domain résout correctement vers $expected_ip"
            return 0
        fi
    else
        error "Aucun outil DNS disponible (dig ou nslookup requis)"
        return 1
    fi
}

# Fonction pour vérifier les ports
check_ports() {
    local ip=$1

    info "Vérification des ports 80 et 443..."

    # Port 80
    if timeout 3 bash -c "echo >/dev/tcp/$ip/80" 2>/dev/null; then
        success "✓ Port 80 accessible"
    else
        warn "⚠️  Port 80 non accessible (peut être normal si Traefik n'est pas encore démarré)"
    fi

    # Port 443
    if timeout 3 bash -c "echo >/dev/tcp/$ip/443" 2>/dev/null; then
        success "✓ Port 443 accessible"
    else
        warn "⚠️  Port 443 non accessible (peut être normal si Traefik n'est pas encore démarré)"
    fi
}

# Fonction pour vérifier la propagation DNS
check_dns_propagation() {
    local domain=$1
    local expected_ip=$2

    info "Vérification de la propagation DNS globale..."

    # Liste de serveurs DNS publics
    local dns_servers=("8.8.8.8" "1.1.1.1" "9.9.9.9")
    local success_count=0

    for dns in "${dns_servers[@]}"; do
        if command -v dig &> /dev/null; then
            local resolved_ip=$(dig +short @"$dns" "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)

            if [ "$resolved_ip" = "$expected_ip" ]; then
                success "✓ DNS $dns : $domain → $resolved_ip"
                ((success_count++))
            else
                warn "⚠️  DNS $dns : $domain → $resolved_ip (attendu: $expected_ip)"
            fi
        fi
    done

    if [ $success_count -eq ${#dns_servers[@]} ]; then
        success "✓ Propagation DNS complète sur tous les serveurs testés"
        return 0
    elif [ $success_count -gt 0 ]; then
        warn "⚠️  Propagation DNS partielle ($success_count/${#dns_servers[@]} serveurs)"
        warn "   La propagation peut prendre jusqu'à 48h"
        return 1
    else
        error "❌ Aucun serveur DNS ne résout correctement"
        return 1
    fi
}

# Programme principal
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}   Vérification DNS pour Traefik${NC}"
echo -e "${BLUE}========================================${NC}\n"

log "Domaine testé: $DOMAIN"

# 1. Obtenir l'IP du serveur
if ! get_server_ip; then
    error "Impossible de continuer sans connaître l'IP du serveur"
    exit 1
fi

echo ""

# 2. Vérifier le domaine principal
log "Test 1: Domaine principal"
if check_dns_resolution "$DOMAIN" "$SERVER_IP"; then
    DOMAIN_OK=true
else
    DOMAIN_OK=false
fi

echo ""

# 3. Vérifier le wildcard
log "Test 2: Wildcard DNS"
if check_dns_resolution "test.$DOMAIN" "$SERVER_IP"; then
    WILDCARD_OK=true
else
    WILDCARD_OK=false
fi

echo ""

# 4. Vérifier les ports
log "Test 3: Accessibilité des ports"
check_ports "$SERVER_IP"

echo ""

# 5. Vérifier la propagation
log "Test 4: Propagation DNS globale"
check_dns_propagation "$DOMAIN" "$SERVER_IP"

echo ""

# Résumé final
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}   Résumé de la vérification${NC}"
echo -e "${BLUE}========================================${NC}\n"

if [ "$DOMAIN_OK" = true ] && [ "$WILDCARD_OK" = true ]; then
    success "Configuration DNS complète et fonctionnelle !"
    echo ""
    info "Vous pouvez maintenant installer Traefik avec:"
    echo -e "  ${GREEN}sudo ./scripts/setup_traefik.sh $DOMAIN${NC}"
    exit 0
else
    error "Configuration DNS incomplète"
    echo ""

    if [ "$DOMAIN_OK" != true ]; then
        warn "⚠️  Le domaine principal $DOMAIN ne pointe pas vers $SERVER_IP"
    fi

    if [ "$WILDCARD_OK" != true ]; then
        warn "⚠️  Le wildcard *.$DOMAIN ne pointe pas vers $SERVER_IP"
    fi

    echo ""
    info "Actions requises:"
    echo "  1. Connectez-vous à votre provider DNS (Cloudflare, OVH, etc.)"
    echo "  2. Créez un enregistrement A pour: $DOMAIN → $SERVER_IP"
    echo "  3. Créez un enregistrement A pour: *.$DOMAIN → $SERVER_IP"
    echo ""
    info "Alternative automatique:"
    echo "  - Avec Cloudflare: sudo ./scripts/setup_cloudflare.sh"
    echo "  - Sans domaine: sudo ./scripts/setup_duckdns.sh"

    exit 1
fi
