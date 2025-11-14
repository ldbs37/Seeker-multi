#!/bin/bash

#######################
# Menu de Gestion Seedbox Multi-Utilisateurs
# Interface centralisée pour tous les scripts de gestion
#######################

set -e
set -u

#######################
# Variables
#######################

INSTALL_DIR="/opt/seedbox"
SCRIPTS_DIR="$INSTALL_DIR/scripts"

# Couleurs
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

#######################
# Fonctions utilitaires
#######################

log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }

# Fonction pour attendre l'appui sur une touche
pause() {
    echo ""
    read -p "Appuyez sur Entrée pour continuer..."
}

# Fonction pour afficher l'en-tête
show_header() {
    clear
    echo -e "${CYAN}${BOLD}"
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║                                                            ║"
    echo "║        🎬 SEEDBOX MULTI-UTILISATEURS - MENU GESTION       ║"
    echo "║                                                            ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# Vérifier si le script est exécuté en root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Ce script doit être exécuté en tant que root (sudo)"
        exit 1
    fi
}

# Vérifier si l'installation existe
check_installation() {
    if [ ! -d "$INSTALL_DIR" ]; then
        error "Installation non trouvée dans $INSTALL_DIR"
        error "Veuillez d'abord exécuter le script d'installation (install.sh)"
        exit 1
    fi

    if [ ! -d "$SCRIPTS_DIR" ]; then
        error "Répertoire des scripts non trouvé: $SCRIPTS_DIR"
        exit 1
    fi
}

#######################
# Fonctions de monitoring
#######################

show_system_status() {
    show_header
    echo -e "${BOLD}${BLUE}📊 État du Système${NC}\n"

    # Statistiques Docker
    echo -e "${CYAN}Docker:${NC}"
    RUNNING=$(docker ps --filter "status=running" --format "{{.Names}}" | wc -l)
    STOPPED=$(docker ps -a --filter "status=exited" --format "{{.Names}}" | wc -l)
    echo "  Conteneurs actifs: $RUNNING"
    echo "  Conteneurs arrêtés: $STOPPED"
    echo ""

    # Espace disque
    echo -e "${CYAN}Espace Disque:${NC}"
    df -h "$INSTALL_DIR" | tail -1 | awk '{print "  Utilisé: "$3" / "$2" ("$5")"}'
    echo ""

    # RAM
    echo -e "${CYAN}Mémoire RAM:${NC}"
    free -h | grep "Mem:" | awk '{print "  Utilisée: "$3" / "$2}'
    echo ""

    # CPU
    echo -e "${CYAN}Charge CPU:${NC}"
    uptime | awk -F'load average:' '{print "  Load average:"$2}'
    echo ""

    pause
}

show_services_status() {
    show_header
    echo -e "${BOLD}${BLUE}🔧 État des Services${NC}\n"

    cd "$INSTALL_DIR"

    echo -e "${CYAN}Services Système:${NC}"
    for service in authelia flaresolverr plex jellyfin scrutiny uptime-kuma dashdot portainer tautulli watchtower duplicati; do
        if docker ps --format "{{.Names}}" | grep -q "^${service}$"; then
            echo -e "  ${GREEN}●${NC} $service"
        elif docker ps -a --format "{{.Names}}" | grep -q "^${service}$"; then
            echo -e "  ${RED}●${NC} $service (arrêté)"
        fi
    done
    echo ""

    echo -e "${CYAN}Services Utilisateurs:${NC}"
    docker ps --format "{{.Names}}" | grep -E "(qbittorrent|homarr|sonarr|radarr|readarr|bazarr|prowlarr|overseerr|calibre|filebrowser)-" | sort
    echo ""

    pause
}

show_users_list() {
    show_header
    echo -e "${BOLD}${BLUE}👥 Liste des Utilisateurs${NC}\n"

    cd "$INSTALL_DIR"

    # Lister les utilisateurs à partir des conteneurs qBittorrent
    echo -e "${CYAN}Utilisateurs configurés:${NC}"
    docker ps -a --format "{{.Names}}" | grep "^qbittorrent-" | sed 's/qbittorrent-//' | while read username; do
        # Vérifier le quota
        if id "$username" &>/dev/null; then
            QUOTA=$(sudo quota -v -u "$username" 2>/dev/null | grep "$INSTALL_DIR" | awk '{print $3}' || echo "N/A")
            RUNNING=$(docker ps --format "{{.Names}}" | grep -c ".*-${username}$" || echo "0")
            TOTAL=$(docker ps -a --format "{{.Names}}" | grep -c ".*-${username}$" || echo "0")
            echo "  • $username - Services: $RUNNING/$TOTAL actifs - Quota: $QUOTA"
        else
            echo "  • $username (utilisateur système non trouvé)"
        fi
    done
    echo ""

    pause
}

show_user_services() {
    show_header
    echo -e "${BOLD}${BLUE}📋 Services d'un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur: " username

    if [ -z "$username" ]; then
        warn "Nom d'utilisateur requis"
        pause
        return
    fi

    echo ""
    if [ -x "$SCRIPTS_DIR/list_user_services.sh" ]; then
        "$SCRIPTS_DIR/list_user_services.sh" "$username"
    else
        error "Script list_user_services.sh non trouvé"
    fi

    pause
}

show_logs() {
    show_header
    echo -e "${BOLD}${BLUE}📝 Logs d'un Service${NC}\n"

    read -p "Nom du conteneur: " container

    if [ -z "$container" ]; then
        warn "Nom de conteneur requis"
        pause
        return
    fi

    echo ""
    if docker ps -a --format "{{.Names}}" | grep -q "^${container}$"; then
        echo -e "${CYAN}Dernières lignes du log de $container:${NC}\n"
        docker logs --tail 50 "$container"
    else
        error "Conteneur '$container' non trouvé"
    fi

    pause
}

show_quotas() {
    show_header
    echo -e "${BOLD}${BLUE}💾 Quotas Utilisateurs${NC}\n"

    cd "$INSTALL_DIR"

    echo -e "${CYAN}Utilisation des quotas:${NC}\n"
    docker ps -a --format "{{.Names}}" | grep "^qbittorrent-" | sed 's/qbittorrent-//' | while read username; do
        if id "$username" &>/dev/null; then
            echo -e "${BOLD}Utilisateur: $username${NC}"
            sudo quota -v -u "$username" 2>/dev/null || echo "  Quota non configuré"
            echo ""
        fi
    done

    pause
}

#######################
# Fonctions de gestion utilisateurs
#######################

add_user_menu() {
    show_header
    echo -e "${BOLD}${BLUE}➕ Ajouter un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur: " username
    read -s -p "Mot de passe: " password
    echo ""
    read -p "Email: " email
    read -p "Quota (GB) [500]: " quota
    quota=${quota:-500}

    echo ""
    read -p "Cet utilisateur est-il un administrateur ? (o/N): " is_admin

    echo ""
    if [[ $is_admin =~ ^[oO]$ ]]; then
        info "Création de l'utilisateur ADMINISTRATEUR: $username..."
        info "(Services inclus: qBittorrent + Homarr + Filebrowser + sélection interactive)"
        "$SCRIPTS_DIR/add_user.sh" "$username" "$password" "$email" "$quota" --admin
    else
        info "Création de l'utilisateur STANDARD: $username..."
        info "(Service obligatoire: qBittorrent + sélection interactive des autres)"
        "$SCRIPTS_DIR/add_user.sh" "$username" "$password" "$email" "$quota"
    fi

    echo ""
    success "Utilisateur créé !"
    pause
}

remove_user_menu() {
    show_header
    echo -e "${BOLD}${BLUE}➖ Supprimer un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur à supprimer: " username

    if [ -z "$username" ]; then
        warn "Nom d'utilisateur requis"
        pause
        return
    fi

    echo ""
    warn "Cette action va supprimer l'utilisateur et tous ses conteneurs"
    read -p "Conserver les données de l'utilisateur ? (o/N): " keep_data

    echo ""
    if [[ $keep_data =~ ^[oO]$ ]]; then
        "$SCRIPTS_DIR/remove_user.sh" "$username" --keep-data
    else
        read -p "Êtes-vous sûr ? Tapez 'supprimer' pour confirmer: " confirm
        if [ "$confirm" = "supprimer" ]; then
            "$SCRIPTS_DIR/remove_user.sh" "$username"
        else
            warn "Suppression annulée"
        fi
    fi

    pause
}

update_quota_menu() {
    show_header
    echo -e "${BOLD}${BLUE}💾 Modifier le Quota d'un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur: " username
    read -p "Nouveau quota (GB): " quota

    if [ -z "$username" ] || [ -z "$quota" ]; then
        warn "Nom d'utilisateur et quota requis"
        pause
        return
    fi

    echo ""
    "$SCRIPTS_DIR/update_quota.sh" "$username" "$quota"

    pause
}

update_password_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔑 Modifier le Mot de Passe d'un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur: " username

    if [ -z "$username" ]; then
        warn "Nom d'utilisateur requis"
        pause
        return
    fi

    # Vérifier que l'utilisateur existe
    if ! id "$username" &>/dev/null; then
        error "L'utilisateur $username n'existe pas"
        pause
        return
    fi

    echo ""
    info "Le mot de passe sera demandé de manière sécurisée par le script"
    echo ""
    read -p "Continuer ? (O/n): " confirm

    if [[ ! $confirm =~ ^[Nn]$ ]]; then
        "$SCRIPTS_DIR/update_password.sh" "$username"
    else
        warn "Modification annulée"
    fi

    pause
}

add_user_service_menu() {
    show_header
    echo -e "${BOLD}${BLUE}➕ Ajouter un Service à un Utilisateur${NC}\n"

    read -p "Nom d'utilisateur: " username

    if [ -z "$username" ]; then
        warn "Nom d'utilisateur requis"
        pause
        return
    fi

    echo ""
    echo -e "${CYAN}Services disponibles:${NC}"
    echo "  1. sonarr    - Séries TV"
    echo "  2. radarr    - Films"
    echo "  3. readarr   - Livres"
    echo "  4. bazarr    - Sous-titres"
    echo "  5. prowlarr  - Indexeurs"
    echo "  6. overseerr - Requêtes"
    echo "  7. calibre   - Bibliothèque ebooks"
    echo ""

    read -p "Service à ajouter: " service

    if [ -z "$service" ]; then
        warn "Service requis"
        pause
        return
    fi

    echo ""
    "$SCRIPTS_DIR/add_user_service.sh" "$username" "$service"

    pause
}

#######################
# Fonctions de gestion services système
#######################

add_service_menu() {
    show_header
    echo -e "${BOLD}${BLUE}➕ Ajouter un Service Système${NC}\n"

    echo -e "${CYAN}Services disponibles:${NC}"
    echo ""
    echo -e "${BOLD}Streaming:${NC}"
    echo "  1. plex      - Serveur de streaming"
    echo "  2. jellyfin  - Alternative open-source à Plex"
    echo ""
    echo -e "${BOLD}Monitoring & Dashboards:${NC}"
    echo "  3. scrutiny      - Monitoring disques S.M.A.R.T."
    echo "  4. uptime-kuma   - Monitoring uptime"
    echo "  5. dashdot       - Monitoring système élégant"
    echo "  6. tautulli      - Statistiques Plex"
    echo ""
    echo -e "${BOLD}Gestion & Organisation:${NC}"
    echo "  7. portainer - Gestion Docker web"
    echo ""
    echo -e "${BOLD}Maintenance:${NC}"
    echo "  8. watchtower - Mises à jour automatiques"
    echo "  9. duplicati - Système de backup"
    echo ""

    read -p "Service à installer: " service

    if [ -z "$service" ]; then
        warn "Service requis"
        pause
        return
    fi

    echo ""
    "$SCRIPTS_DIR/add_service.sh" "$service"

    pause
}

remove_service_menu() {
    show_header
    echo -e "${BOLD}${BLUE}➖ Supprimer un Service Système${NC}\n"

    read -p "Nom du service à supprimer: " service

    if [ -z "$service" ]; then
        warn "Nom de service requis"
        pause
        return
    fi

    echo ""
    warn "Cette action va arrêter et supprimer le service $service"
    read -p "Êtes-vous sûr ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        cd "$INSTALL_DIR"
        docker-compose stop "$service" 2>/dev/null || true
        docker-compose rm -f "$service" 2>/dev/null || true
        success "Service $service supprimé"
    else
        warn "Suppression annulée"
    fi

    pause
}

#######################
# Fonctions de maintenance
#######################

restart_services_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔄 Redémarrer les Services${NC}\n"

    echo "1. Redémarrer tous les services"
    echo "2. Redémarrer un service spécifique"
    echo "3. Redémarrer les services d'un utilisateur"
    echo ""

    read -p "Choix: " choice

    echo ""
    cd "$INSTALL_DIR"

    case $choice in
        1)
            warn "Redémarrage de tous les services..."
            docker-compose restart
            success "Tous les services ont été redémarrés"
            ;;
        2)
            read -p "Nom du service: " service
            if [ -n "$service" ]; then
                docker restart "$service"
                success "Service $service redémarré"
            fi
            ;;
        3)
            read -p "Nom d'utilisateur: " username
            if [ -n "$username" ]; then
                docker ps -a --format "{{.Names}}" | grep ".*-${username}$" | while read container; do
                    docker restart "$container"
                    echo "  ✓ $container redémarré"
                done
                success "Services de $username redémarrés"
            fi
            ;;
        *)
            warn "Choix invalide"
            ;;
    esac

    pause
}

update_containers_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔄 Mettre à Jour les Conteneurs${NC}\n"

    warn "Cette opération va télécharger les dernières images et redémarrer les conteneurs"
    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        cd "$INSTALL_DIR"

        info "Téléchargement des nouvelles images..."
        docker-compose pull

        echo ""
        info "Redémarrage des conteneurs..."
        docker-compose up -d

        echo ""
        success "Mise à jour terminée !"
    else
        warn "Mise à jour annulée"
    fi

    pause
}

cleanup_docker_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🧹 Nettoyage Docker${NC}\n"

    echo "Cette opération va supprimer:"
    echo "  • Les conteneurs arrêtés"
    echo "  • Les images non utilisées"
    echo "  • Les volumes non utilisés"
    echo "  • Les réseaux non utilisés"
    echo ""

    warn "Assurez-vous de ne pas avoir de conteneurs temporairement arrêtés"
    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        info "Nettoyage en cours..."
        docker system prune -af --volumes
        echo ""
        success "Nettoyage terminé !"
    else
        warn "Nettoyage annulé"
    fi

    pause
}

backup_menu() {
    show_header
    echo -e "${BOLD}${BLUE}💾 Sauvegarde${NC}\n"

    BACKUP_DIR="/var/backups/seedbox"
    BACKUP_FILE="seedbox-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

    echo "Répertoire de sauvegarde: $BACKUP_DIR"
    echo "Fichier: $BACKUP_FILE"
    echo ""

    warn "Cette opération peut prendre du temps selon la taille des données"
    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        mkdir -p "$BACKUP_DIR"

        info "Sauvegarde de la configuration..."
        cd "$INSTALL_DIR"
        tar -czf "$BACKUP_DIR/$BACKUP_FILE" \
            --exclude='*/cache/*' \
            --exclude='*/data/*' \
            --exclude='*/downloads/*' \
            authelia/ docker-compose.yml scripts/ 2>/dev/null

        echo ""
        success "Sauvegarde créée: $BACKUP_DIR/$BACKUP_FILE"
        ls -lh "$BACKUP_DIR/$BACKUP_FILE"
    else
        warn "Sauvegarde annulée"
    fi

    pause
}

#######################
# Menus principaux
#######################

menu_users() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}👥 GESTION DES UTILISATEURS${NC}\n"

        echo "1. Ajouter un utilisateur"
        echo "2. Supprimer un utilisateur"
        echo "3. Modifier le quota d'un utilisateur"
        echo "4. Modifier le mot de passe d'un utilisateur"
        echo "5. Ajouter un service à un utilisateur"
        echo "6. Lister les services d'un utilisateur"
        echo "7. Afficher les quotas"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) add_user_menu ;;
            2) remove_user_menu ;;
            3) update_quota_menu ;;
            4) update_password_menu ;;
            5) add_user_service_menu ;;
            6) show_user_services ;;
            7) show_quotas ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

menu_services() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}🔧 GESTION DES SERVICES SYSTÈME${NC}\n"

        echo "1. Ajouter un service système"
        echo "2. Supprimer un service système"
        echo "3. Voir l'état des services"
        echo "4. Voir les logs d'un service"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) add_service_menu ;;
            2) remove_service_menu ;;
            3) show_services_status ;;
            4) show_logs ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

menu_monitoring() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}📊 MONITORING${NC}\n"

        echo "1. État du système"
        echo "2. État des services"
        echo "3. Liste des utilisateurs"
        echo "4. Quotas utilisateurs"
        echo "5. Logs d'un service"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) show_system_status ;;
            2) show_services_status ;;
            3) show_users_list ;;
            4) show_quotas ;;
            5) show_logs ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

menu_maintenance() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}🛠️  MAINTENANCE${NC}\n"

        echo "1. Redémarrer les services"
        echo "2. Mettre à jour les conteneurs"
        echo "3. Nettoyage Docker"
        echo "4. Créer une sauvegarde"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) restart_services_menu ;;
            2) update_containers_menu ;;
            3) cleanup_docker_menu ;;
            4) backup_menu ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

menu_traefik() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}🌐 TRAEFIK & SSO${NC}\n"

        # Vérifier si Traefik est installé
        if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
            echo -e "${GREEN}● Traefik est installé${NC}"
            if [ -f "$INSTALL_DIR/.env" ] && grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
                DOMAIN=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
                echo -e "${CYAN}   Domaine configuré : $DOMAIN${NC}"
            fi
            echo ""
        else
            echo -e "${YELLOW}○ Traefik n'est pas installé${NC}"
            echo ""
        fi

        echo "1. Installer Traefik"
        echo "2. Générer les labels Docker pour services existants"
        echo "3. Voir l'état de Traefik"
        echo "4. Voir les certificats SSL"
        echo "5. Redémarrer Traefik"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) setup_traefik_menu ;;
            2) generate_labels_menu ;;
            3) traefik_status_menu ;;
            4) traefik_certs_menu ;;
            5) restart_traefik_menu ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

setup_traefik_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🌐 Installation Traefik${NC}\n"

    read -p "Nom de domaine (ex: example.com): " domain
    read -p "Email pour Let's Encrypt: " email

    if [ -z "$domain" ] || [ -z "$email" ]; then
        warn "Domaine et email requis"
        pause
        return
    fi

    echo ""
    warn "⚠️  Prérequis :"
    warn "   - DNS wildcard *.${domain} doit pointer vers ce serveur"
    warn "   - Ports 80/443 doivent être ouverts"
    echo ""

    read -p "Les prérequis sont-ils remplis ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        "$SCRIPTS_DIR/setup_traefik.sh" "$domain" "$email"
    else
        info "Installation annulée"
    fi

    pause
}

generate_labels_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🏷️  Génération Labels Docker${NC}\n"

    if ! docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
        warn "Traefik n'est pas installé. Installez-le d'abord."
        pause
        return
    fi

    echo ""
    "$SCRIPTS_DIR/generate_traefik_labels.sh"

    pause
}

traefik_status_menu() {
    show_header
    echo -e "${BOLD}${BLUE}📊 État de Traefik${NC}\n"

    if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
        echo -e "${GREEN}● Traefik est en cours d'exécution${NC}\n"

        echo -e "${CYAN}Conteneur :${NC}"
        docker ps --filter "name=traefik" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

        echo ""
        echo -e "${CYAN}Logs récents :${NC}"
        docker logs traefik --tail 20

        if [ -f "$INSTALL_DIR/.env" ] && grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
            DOMAIN=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
            echo ""
            echo -e "${CYAN}Accès :${NC}"
            echo "  Dashboard : https://traefik.$DOMAIN"
            echo "  Authelia  : https://auth.$DOMAIN"
        fi
    else
        echo -e "${RED}○ Traefik n'est pas en cours d'exécution${NC}"
    fi

    echo ""
    pause
}

traefik_certs_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔒 Certificats SSL${NC}\n"

    ACME_FILE="$INSTALL_DIR/traefik/letsencrypt/acme.json"

    if [ -f "$ACME_FILE" ]; then
        echo -e "${CYAN}Certificats dans : $ACME_FILE${NC}\n"

        # Afficher les domaines avec certificats
        if command -v jq &>/dev/null; then
            echo -e "${CYAN}Domaines avec certificats :${NC}"
            jq -r '.letsencrypt.Certificates[].domain.main' "$ACME_FILE" 2>/dev/null || echo "Aucun certificat trouvé"
        else
            echo "Installer jq pour voir les détails : apt install jq"
        fi
    else
        warn "Fichier de certificats non trouvé"
    fi

    echo ""
    pause
}

restart_traefik_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔄 Redémarrage Traefik${NC}\n"

    if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
        log "Redémarrage de Traefik..."
        docker restart traefik
        sleep 3

        if docker ps --format '{{.Names}}' | grep -q "^traefik$"; then
            log "✓ Traefik redémarré avec succès"
        else
            error "Échec du redémarrage"
        fi
    else
        warn "Traefik n'est pas en cours d'exécution"
    fi

    echo ""
    pause
}

#######################
# Fonctions DNS
#######################

menu_dns() {
    while true; do
        show_header
        echo -e "${BOLD}${MAGENTA}🌍 GESTION DNS${NC}\n"

        # Vérifier si un domaine est configuré
        if [ -f "$INSTALL_DIR/.env" ] && grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
            DOMAIN=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
            echo -e "${GREEN}● Domaine configuré : $DOMAIN${NC}"
            echo ""
        else
            echo -e "${YELLOW}○ Aucun domaine configuré${NC}"
            echo ""
        fi

        echo "1. Vérifier la configuration DNS actuelle"
        echo "2. Configurer Cloudflare (automatique via API)"
        echo "3. Configurer DuckDNS (gratuit, automatique)"
        echo "4. Configurer OVH (automatique via API)"
        echo "5. Afficher le guide DNS complet"
        echo ""
        echo "0. Retour au menu principal"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) check_dns_menu ;;
            2) setup_cloudflare_menu ;;
            3) setup_duckdns_menu ;;
            4) setup_ovh_menu ;;
            5) show_dns_guide_menu ;;
            0) break ;;
            *) warn "Choix invalide" ; pause ;;
        esac
    done
}

check_dns_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🔍 Vérification DNS${NC}\n"

    read -p "Nom de domaine à vérifier: " domain

    if [ -z "$domain" ]; then
        # Utiliser le domaine du .env si disponible
        if [ -f "$INSTALL_DIR/.env" ] && grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
            domain=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
            info "Utilisation du domaine configuré: $domain"
        else
            warn "Nom de domaine requis"
            pause
            return
        fi
    fi

    echo ""
    if [ -x "$SCRIPTS_DIR/check_dns.sh" ]; then
        "$SCRIPTS_DIR/check_dns.sh" "$domain"
    else
        error "Script check_dns.sh non trouvé"
    fi

    pause
}

setup_cloudflare_menu() {
    show_header
    echo -e "${BOLD}${BLUE}☁️  Configuration Cloudflare${NC}\n"

    info "Ce script va configurer automatiquement vos enregistrements DNS via l'API Cloudflare"
    echo ""
    info "Prérequis:"
    echo "  • Un compte Cloudflare (gratuit)"
    echo "  • Votre domaine géré par Cloudflare"
    echo "  • Un token API avec permissions 'Edit zone DNS'"
    echo ""
    info "Le script va créer:"
    echo "  • domain.com → IP de ce serveur"
    echo "  • *.domain.com → IP de ce serveur (wildcard)"
    echo ""

    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        if [ -x "$SCRIPTS_DIR/setup_cloudflare.sh" ]; then
            "$SCRIPTS_DIR/setup_cloudflare.sh"
        else
            error "Script setup_cloudflare.sh non trouvé"
        fi
    else
        info "Configuration annulée"
    fi

    pause
}

setup_duckdns_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🦆 Configuration DuckDNS${NC}\n"

    info "DuckDNS est un service DNS 100% GRATUIT avec:"
    echo "  ✓ Wildcard DNS automatique"
    echo "  ✓ Pas besoin d'acheter un domaine"
    echo "  ✓ Mise à jour automatique de l'IP (IP dynamique)"
    echo "  ✓ Compatible Let's Encrypt SSL"
    echo ""
    info "Vous aurez un domaine comme: monseedbox.duckdns.org"
    echo ""

    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        if [ -x "$SCRIPTS_DIR/setup_duckdns.sh" ]; then
            "$SCRIPTS_DIR/setup_duckdns.sh"
        else
            error "Script setup_duckdns.sh non trouvé"
        fi
    else
        info "Configuration annulée"
    fi

    pause
}

setup_ovh_menu() {
    show_header
    echo -e "${BOLD}${BLUE}🇫🇷 Configuration OVH${NC}\n"

    info "Ce script va configurer automatiquement vos enregistrements DNS via l'API OVH"
    echo ""
    info "Prérequis:"
    echo "  • Un compte OVH avec un domaine"
    echo "  • Des clés API OVH (Application Key, Application Secret, Consumer Key)"
    echo "  • Guide pour créer les clés: https://api.ovh.com/createToken/"
    echo ""
    info "Le script va créer:"
    echo "  • domain.com → IP de ce serveur"
    echo "  • *.domain.com → IP de ce serveur (wildcard)"
    echo ""

    read -p "Continuer ? (o/N): " confirm

    if [[ $confirm =~ ^[oO]$ ]]; then
        echo ""
        if [ -x "$SCRIPTS_DIR/setup_ovh.sh" ]; then
            "$SCRIPTS_DIR/setup_ovh.sh"
        else
            error "Script setup_ovh.sh non trouvé"
        fi
    else
        info "Configuration annulée"
    fi

    pause
}

show_dns_guide_menu() {
    show_header
    echo -e "${BOLD}${BLUE}📚 Guide DNS Complet${NC}\n"

    DNS_GUIDE="$INSTALL_DIR/../docs/DNS_SETUP.md"

    if [ -f "$DNS_GUIDE" ]; then
        info "Guide disponible dans: $DNS_GUIDE"
        echo ""
        echo -e "${CYAN}Table des matières:${NC}"
        echo "  • Configuration automatique (Cloudflare, DuckDNS, OVH)"
        echo "  • Configuration manuelle (tous providers)"
        echo "  • Vérification DNS"
        echo "  • Dépannage complet"
        echo "  • FAQ"
        echo ""
        read -p "Afficher le guide ? (o/N): " show

        if [[ $show =~ ^[oO]$ ]]; then
            echo ""
            if command -v less &>/dev/null; then
                less "$DNS_GUIDE"
            elif command -v more &>/dev/null; then
                more "$DNS_GUIDE"
            else
                cat "$DNS_GUIDE"
            fi
        fi
    else
        error "Guide DNS non trouvé: $DNS_GUIDE"
    fi

    pause
}

menu_main() {
    while true; do
        show_header

        echo -e "${BOLD}MENU PRINCIPAL${NC}\n"

        echo -e "${CYAN}1.${NC} 👥  Gestion des utilisateurs"
        echo -e "${CYAN}2.${NC} 🔧  Gestion des services système"
        echo -e "${CYAN}3.${NC} 📊  Monitoring"
        echo -e "${CYAN}4.${NC} 🛠️   Maintenance"
        echo -e "${CYAN}5.${NC} 🌐  Traefik & SSO"
        echo -e "${CYAN}6.${NC} 🌍  Gestion DNS"
        echo ""
        echo -e "${CYAN}0.${NC} ❌  Quitter"
        echo ""

        read -p "Choix: " choice

        case $choice in
            1) menu_users ;;
            2) menu_services ;;
            3) menu_monitoring ;;
            4) menu_maintenance ;;
            5) menu_traefik ;;
            6) menu_dns ;;
            0)
                echo ""
                info "Au revoir !"
                exit 0
                ;;
            *)
                warn "Choix invalide"
                pause
                ;;
        esac
    done
}

#######################
# Point d'entrée
#######################

main() {
    check_root
    check_installation
    menu_main
}

main
