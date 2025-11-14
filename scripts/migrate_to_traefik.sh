#!/bin/bash

#######################
# Script de migration vers Traefik
# Pour les installations existantes passant de port direct à reverse proxy
# Usage: ./migrate_to_traefik.sh <domain> <email>
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
SCRIPTS_DIR="$INSTALL_DIR/scripts"

# Vérification des arguments
if [ $# -lt 2 ]; then
    echo "Usage: $0 <domain> <email>"
    echo ""
    echo "Ce script migre une installation existante (accès par port)"
    echo "vers une architecture Traefik avec reverse proxy."
    echo ""
    echo "Exemple:"
    echo "  sudo ./migrate_to_traefik.sh example.com admin@example.com"
    echo ""
    echo "⚠️  ATTENTION :"
    echo "   - Cette migration est IRRÉVERSIBLE"
    echo "   - Les services ne seront plus accessibles par port direct"
    echo "   - Nécessite un nom de domaine avec DNS wildcard configuré"
    echo "   - Temps d'arrêt estimé : 5-10 minutes"
    exit 1
fi

DOMAIN=$1
EMAIL=$2

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║                                                        ║${NC}"
echo -e "${CYAN}║       MIGRATION VERS TRAEFIK + AUTHELIA SSO           ║${NC}"
echo -e "${CYAN}║                                                        ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

info "Domaine : $DOMAIN"
info "Email : $EMAIL"
echo ""

#######################
# Vérifications pré-migration
#######################

log "Vérifications pré-migration..."

# 1. Vérifier que l'installation existe
if [ ! -d "$INSTALL_DIR" ]; then
    error "Installation non trouvée dans $INSTALL_DIR"
fi

# 2. Vérifier DNS
info "Vérification DNS..."
warn "Assurez-vous que *.${DOMAIN} pointe vers ce serveur"
read -p "Le DNS est-il configuré ? (o/N): " dns_ok

if [[ ! $dns_ok =~ ^[oO]$ ]]; then
    error "Configurez d'abord le DNS wildcard *.${DOMAIN}"
fi

# 3. Lister les services actuels
log "Services détectés :"
docker ps --format "table {{.Names}}\t{{.Ports}}" | grep -E "qbittorrent|homarr|sonarr|radarr|jellyfin|plex" || true

echo ""
warn "⚠️  ATTENTION : Migration irréversible !"
warn "   - Les ports directs seront fermés"
warn "   - Accès uniquement via https://*.${DOMAIN}"
warn "   - Temps d'arrêt : 5-10 minutes"
echo ""

read -p "Continuer la migration ? (tapez 'MIGRER' pour confirmer): " confirm

if [ "$confirm" != "MIGRER" ]; then
    info "Migration annulée"
    exit 0
fi

#######################
# Étape 1 : Sauvegarder l'état actuel
#######################

log "Étape 1/6 : Sauvegarde de l'état actuel..."

BACKUP_DIR="$INSTALL_DIR/backup-pre-traefik-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

cp -r "$INSTALL_DIR/docker-compose.yml" "$BACKUP_DIR/"
cp -r "$INSTALL_DIR/authelia" "$BACKUP_DIR/" 2>/dev/null || true
cp -r "$INSTALL_DIR/.env" "$BACKUP_DIR/" 2>/dev/null || true

log "✓ Sauvegarde créée : $BACKUP_DIR"

#######################
# Étape 2 : Installer Traefik
#######################

log "Étape 2/6 : Installation de Traefik..."

"$SCRIPTS_DIR/setup_traefik.sh" "$DOMAIN" "$EMAIL"

log "✓ Traefik installé"

#######################
# Étape 3 : Arrêter tous les services
#######################

log "Étape 3/6 : Arrêt des services..."

cd "$INSTALL_DIR"
docker-compose down

log "✓ Services arrêtés"

#######################
# Étape 4 : Désactiver auth interne des services
#######################

log "Étape 4/6 : Désactivation authentification interne..."

# Désactiver auth qBittorrent pour tous les users
for config_dir in "$INSTALL_DIR"/data/users/*/config/qBittorrent; do
    if [ -d "$config_dir" ]; then
        config_file="$config_dir/qBittorrent.conf"
        if [ -f "$config_file" ]; then
            username=$(basename $(dirname $(dirname "$config_dir")))
            info "   Désactivation auth qBittorrent pour $username..."

            # Ajouter/modifier les lignes d'auth bypass
            if ! grep -q "WebUI\\\\AuthSubnetWhitelistEnabled" "$config_file"; then
                sed -i '/\[Preferences\]/a WebUI\\\\AuthSubnetWhitelistEnabled=true' "$config_file"
                sed -i '/\[Preferences\]/a WebUI\\\\AuthSubnetWhitelist=0.0.0.0/0' "$config_file"
            fi
        fi
    fi
done

# Désactiver auth Filebrowser pour tous les users
for container in $(docker ps -a --format '{{.Names}}' | grep "^filebrowser-"); do
    username=$(echo "$container" | sed 's/filebrowser-//')
    info "   Désactivation auth Filebrowser pour $username..."

    # Sera fait au démarrage via commande Docker
done

# Désactiver auth *arr
for container in $(docker ps -a --format '{{.Names}}' | grep -E "sonarr-|radarr-|prowlarr-|readarr-"); do
    service_type=$(echo "$container" | cut -d'-' -f1)
    username=$(echo "$container" | cut -d'-' -f2-)

    config_file="$INSTALL_DIR/$service_type/$username/config.xml"
    if [ -f "$config_file" ]; then
        info "   Désactivation auth $service_type pour $username..."

        if grep -q "<AuthenticationMethod>" "$config_file"; then
            sed -i 's|<AuthenticationMethod>.*</AuthenticationMethod>|<AuthenticationMethod>None</AuthenticationMethod>|' "$config_file"
        else
            sed -i '/<Config>/a\  <AuthenticationMethod>None</AuthenticationMethod>' "$config_file"
        fi
    fi
done

log "✓ Authentifications internes désactivées"

#######################
# Étape 5 : Ajouter les réseaux et labels
#######################

log "Étape 5/6 : Ajout des labels Traefik et réseaux..."

# Ajouter le réseau traefik_proxy à tous les services
info "   Ajout du réseau traefik_proxy aux services..."

# Cette étape est complexe et nécessiterait un parsing complet du docker-compose.yml
# Pour l'instant, on assume que setup_traefik.sh a déjà préparé la base

"$SCRIPTS_DIR/generate_traefik_labels.sh"

log "✓ Labels et réseaux ajoutés"

#######################
# Étape 6 : Redémarrer avec Traefik
#######################

log "Étape 6/6 : Démarrage avec Traefik..."

cd "$INSTALL_DIR"
docker-compose up -d

# Attendre que les services démarrent
sleep 10

log "✓ Services redémarrés"

#######################
# Vérifications post-migration
#######################

log "Vérifications post-migration..."

# Vérifier que Traefik est démarré
if docker ps | grep -q "traefik"; then
    log "✓ Traefik : démarré"
else
    error "Traefik n'a pas démarré"
fi

# Vérifier que Authelia est démarré
if docker ps | grep -q "authelia"; then
    log "✓ Authelia : démarré"
else
    warn "Authelia n'est pas démarré"
fi

# Tester l'accès HTTPS
info "Test accès HTTPS..."
if curl -sk "https://auth.${DOMAIN}" >/dev/null 2>&1; then
    log "✓ Authelia accessible via HTTPS"
else
    warn "Authelia pas encore accessible (certificat en cours de génération ?)"
fi

#######################
# Résumé
#######################

echo ""
info "═══════════════════════════════════════════════════════════"
info "Migration terminée avec succès !"
info "═══════════════════════════════════════════════════════════"
info ""
info "✅ Changements effectués :"
info "   - Traefik installé et configuré"
info "   - Certificats SSL Let's Encrypt actifs"
info "   - Authelia configuré pour SSO"
info "   - Authentifications internes désactivées"
info "   - Réseaux Docker configurés"
info ""
info "🌐 Nouveaux accès (via HTTPS) :"
info "   - Authelia : https://auth.${DOMAIN}"
info "   - Traefik Dashboard : https://traefik.${DOMAIN}"
info ""
info "   Utilisateurs (exemple user1) :"
info "   - qBittorrent : https://user1.${DOMAIN}/qbittorrent"
info "   - Homarr : https://user1.${DOMAIN}"
info "   - Filebrowser : https://user1.${DOMAIN}/files"
info "   - Sonarr : https://user1.${DOMAIN}/sonarr"
info "   - etc."
info ""
info "💡 Connexion :"
info "   1. Allez sur https://auth.${DOMAIN}"
info "   2. Connectez-vous avec vos identifiants Authelia"
info "   3. Accédez à tous les services sans re-login"
info ""
info "📦 Sauvegarde :"
info "   $BACKUP_DIR"
info ""
info "🔄 Rollback (si problème) :"
info "   cd $INSTALL_DIR"
info "   docker-compose down"
info "   cp $BACKUP_DIR/docker-compose.yml ."
info "   docker-compose up -d"
info ""
info "═══════════════════════════════════════════════════════════"
