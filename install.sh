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

# UID/GID des services système (Plex, Jellyfin, Duplicati…). Les comptes
# utilisateurs de la seedbox ont leur propre plage (voir scripts/lib_ports.sh).
ADMIN_UID="1000"
ADMIN_GID="1000"

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Fonctions de base pour les logs
log() { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }

# Génération du docker-compose.yml (définitions partagées des services système)
SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SOURCE_DIR/scripts/lib_compose_base.sh" ]; then
    error "scripts/lib_compose_base.sh introuvable : lancez install.sh depuis le dépôt cloné"
fi
# shellcheck source=scripts/lib_compose_base.sh
source "$SOURCE_DIR/scripts/lib_compose_base.sh"
# shellcheck source=scripts/lib_autoconfig.sh
source "$SOURCE_DIR/scripts/lib_autoconfig.sh"
# shellcheck source=scripts/lib_password.sh
source "$SOURCE_DIR/scripts/lib_password.sh"
# shellcheck source=scripts/lib_homarr.sh
source "$SOURCE_DIR/scripts/lib_homarr.sh"

# Tableau pour stocker les utilisateurs
declare -a INITIAL_USERS INITIAL_PASSWORDS INITIAL_EMAILS INITIAL_QUOTAS

# Services optionnels
INSTALL_PLEX=false
INSTALL_JELLYFIN=false
INSTALL_SCRUTINY=false
INSTALL_UPTIME_KUMA=false
INSTALL_DASHDOT=false
INSTALL_TAUTULLI=false
INSTALL_PORTAINER=false
INSTALL_WATCHTOWER=false
INSTALL_DUPLICATI=false

# Traefik (reverse proxy avec SSL automatique)
USE_TRAEFIK=false

# Identifiants Portainer
PORTAINER_USER=""
PORTAINER_PASSWORD=""

# Identifiants Jellyfin
JELLYFIN_USER=""
JELLYFIN_PASSWORD=""

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
    if [[ ! "$username" =~ ^[a-z][a-z0-9]{0,31}$ ]]; then
        error "Nom d'utilisateur invalide: $username (lettres minuscules et chiffres uniquement, commence par une lettre, 32 max)"
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
    # HTTPS plutôt que ping (souvent absent des images minimales, ICMP filtré)
    if ! curl -fsS -m 10 -o /dev/null https://get.docker.com 2>/dev/null \
       && ! wget -q -T 10 -O /dev/null https://get.docker.com 2>/dev/null; then
        error "Pas de connexion Internet (https://get.docker.com injoignable)"
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

    local bar
    printf -v bar '%*s' "$completed" ''; bar=${bar// /#}
    printf "\r%s [%s%*s] %d%%" "$prefix" "$bar" "$remaining" '' "$percentage"

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

    # Vérification RAM (4 Go minimum). En Mo : un serveur de 4 Go en affiche
    # ~3800 (le noyau en réserve une partie) — `free -g` arrondissait à 3.
    local total_ram_mb
    total_ram_mb=$(awk '/^MemTotal:/{print int($2/1024)}' /proc/meminfo)
    if [ "${total_ram_mb}" -lt 3500 ]; then
        error "RAM insuffisante : ${total_ram_mb} Mo, 4 Go requis"
    fi

    # Vérification du système de fichiers
    local fs_type
    fs_type=$(df -T / | tail -1 | awk '{print $2}')
    if [[ ! "$fs_type" =~ ^(ext[234]|xfs)$ ]]; then
        warn "Système de fichiers '$fs_type' détecté"
        warn "Les quotas fonctionnent mieux sur ext4 ou xfs"
        warn "Des problèmes peuvent survenir avec btrfs ou zfs"
        echo ""
        read -r -p "Continuer malgré tout ? (o/N): " confirm
        [[ ! $confirm =~ ^[oO]$ ]] && error "Installation annulée"
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
        apache2-utils \
        bc \
        dnsutils \
        python3 \
        openssl

    log "✓ Dépendances installées"
}

# Garantit une commande `docker-compose` (utilisée par les scripts et le menu),
# que Docker ait été installé par ce script ou préinstallé.
ensure_docker_compose() {
    command -v docker-compose &>/dev/null && return 0
    if docker compose version &>/dev/null; then
        # Plugin Compose v2 présent : simple relais
        printf '#!/bin/sh\nexec docker compose "$@"\n' > /usr/local/bin/docker-compose
    else
        local v="v2.29.7"
        curl -fL "https://github.com/docker/compose/releases/download/${v}/docker-compose-linux-$(uname -m)" \
            -o /usr/local/bin/docker-compose || error "Téléchargement de Docker Compose impossible"
    fi
    chmod +x /usr/local/bin/docker-compose
    docker-compose version &>/dev/null || error "docker-compose inutilisable"
    log "✓ Docker Compose disponible"
}

install_docker() {
    log "Installation de Docker..."

    if command -v docker &>/dev/null; then
        log "Docker déjà installé"
    else
        # Installation via le script officiel (inclut le plugin Compose v2)
        curl -fsSL https://get.docker.com -o get-docker.sh
        sh get-docker.sh
        rm -f get-docker.sh
        log "✓ Docker installé"
    fi

    systemctl enable --now docker
    ensure_docker_compose
}

#######################
# Configuration système
#######################

# Ports SSH en service : port de la session courante + configuration sshd
detect_ssh_ports() {
    local ports=""
    [ -n "${SSH_CONNECTION:-}" ] && ports="$(echo "$SSH_CONNECTION" | awk '{print $4}')"
    if command -v sshd &>/dev/null; then
        ports="$ports $(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')"
    fi
    ports="$ports 22"
    echo "$ports" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -un | tr '\n' ' '
}

setup_system() {
    log "Configuration du système..."

    # Fuseau horaire
    timedatectl set-timezone "$TZ" 2>/dev/null || warn "Impossible de configurer le fuseau horaire"

    # Pare-feu. On autorise le(s) port(s) SSH RÉELLEMENT utilisés AVANT
    # d'activer UFW, sinon un SSH sur un port non standard serait coupé.
    SSH_PORTS=$(detect_ssh_ports)
    if command -v ufw &>/dev/null; then
        ufw default deny incoming
        ufw default allow outgoing
        local p
        for p in $SSH_PORTS; do ufw allow "$p/tcp" comment 'SSH'; done
        ufw allow 80/tcp
        ufw allow 443/tcp
        echo "y" | ufw enable 2>/dev/null || true
        log "✓ Pare-feu actif (SSH autorisé sur : $SSH_PORTS)"
    fi

    # Fail2ban
    if [ -f "/etc/fail2ban/jail.local" ]; then
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak
    fi

    cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3

# Protection SSH activée (sinon fail2ban tourne sans bannir personne).
# backend = systemd : les logs SSH passent par journald sur Debian 12 / Ubuntu.
[sshd]
enabled = true
backend = systemd
port = $(echo "$SSH_PORTS" | xargs | tr ' ' ',')
EOF

    systemctl enable fail2ban 2>/dev/null || true
    systemctl restart fail2ban 2>/dev/null || true

    # Vérification : au moins une jail active
    if command -v fail2ban-client &>/dev/null; then
        if fail2ban-client status 2>/dev/null | grep -q "sshd"; then
            log "✓ fail2ban actif (jail sshd)"
        else
            warn "fail2ban installé mais la jail sshd n'est pas active — vérifiez les logs SSH (journald)"
        fi
    fi

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
    if [ -d "$SOURCE_DIR/scripts" ]; then
        cp -r "$SOURCE_DIR/scripts/"* "$INSTALL_DIR/scripts/"
        chmod +x "$INSTALL_DIR/scripts/"*.sh
    fi

    # Copier le menu interactif
    if [ -f "$SOURCE_DIR/menu.sh" ]; then
        cp "$SOURCE_DIR/menu.sh" "$INSTALL_DIR/menu.sh"
        chmod +x "$INSTALL_DIR/menu.sh"
    fi

    # Enregistrer la source (chemin + dépôt git) pour la mise à jour du module
    # seedbox via scripts/update.sh --seedbox.
    local src_dir
    src_dir="$SOURCE_DIR"
    {
        echo "path=$src_dir"
        echo "url=$(git -C "$src_dir" remote get-url origin 2>/dev/null || echo '')"
    } > "$INSTALL_DIR/.source"

    log "✓ Dossiers créés"
}

#######################
# Configuration Authelia
#######################

configure_authelia() {
    log "Configuration d'Authelia..."

    local config_dir="$INSTALL_DIR/authelia"
    local encryption_key session_secret jwt_secret
    encryption_key=$(openssl rand -hex 64)
    session_secret=$(openssl rand -hex 32)
    jwt_secret=$(openssl rand -hex 32)

    # Sous-domaines réservés aux administrateurs (identiques aux routeurs
    # Traefik générés). Listés deux fois ci-dessous : autorisation des admins,
    # puis refus explicite pour les autres (dans Authelia, une règle dont le
    # "subject" ne correspond pas est ignorée : sans ce deny, un utilisateur
    # standard tomberait sur la règle "*.domaine" et accéderait à Portainer…).
    local admin_domains="" d
    for d in traefik portainer scrutiny dashdot tautulli uptime duplicati; do
        admin_domains+="        - \"${d}.${DOMAIN}\""$'\n'
    done
    admin_domains=${admin_domains%$'\n'}

    # Configuration principale (format Authelia 4.38+ : server.address,
    # session.cookies, identity_validation — validé avec authelia validate-config)
    cat > "$config_dir/configuration.yml" << EOF
---
server:
  address: 'tcp://0.0.0.0:9091/'

log:
  level: info

identity_validation:
  reset_password:
    jwt_secret: '${jwt_secret}'

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: deny
  rules:
    # Services système - Accès réservé aux administrateurs
    - domain:
${admin_domains}
      policy: one_factor
      subject:
        - "group:admins"

    # ... et refusé à tous les autres (indispensable, voir commentaire)
    - domain:
${admin_domains}
      policy: deny

    # Racine du domaine : redirection vers le tableau de bord de l'utilisateur
    # connecté (conteneur "home") ; tout utilisateur authentifié
    - domain: '${DOMAIN}'
      policy: one_factor

    # Espaces utilisateurs ISOLÉS : chaque utilisateur n'accède qu'à SES
    # sous-domaines. Le groupe nommé (?P<User>…) doit correspondre au nom de
    # l'utilisateur connecté, sinon la règle ne s'applique pas (→ deny).
    #   <user>.domaine            : Homarr, qBittorrent, Filebrowser, *arr…
    #   <service>-<user>.domaine  : services en sous-domaine (ex. Seerr)
    # (noms d'utilisateur limités à [a-z0-9] : pas d'ambiguïté possible)
    - domain_regex:
        - '^(?P<User>[a-z0-9]+)\.${DOMAIN//./\\.}$'
        - '^seerr-(?P<User>[a-z0-9]+)\.${DOMAIN//./\\.}$'
      policy: one_factor

session:
  name: authelia_session
  secret: '${session_secret}'
  # Reconnexion au plus toutes les 12 h, ou après 2 h d'inactivité
  # (« Se souvenir de moi » : 1 mois)
  expiration: 12h
  inactivity: 2h
  remember_me: 1M
  cookies:
    - domain: '${DOMAIN}'
      authelia_url: 'https://auth.${DOMAIN}'
      # Après une connexion directe sur auth.<domaine> : accueil, qui renvoie
      # chacun vers son tableau de bord
      default_redirection_url: 'https://${DOMAIN}'

storage:
  encryption_key: '${encryption_key}'
  local:
    path: /config/db.sqlite3

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
# Configuration Traefik (si activé)
#######################

setup_traefik_if_enabled() {
    if [ "$USE_TRAEFIK" = "true" ]; then
        log "Configuration de Traefik..."

        # Le .env complet (dont USE_TRAEFIK) est déjà écrit par
        # generate_docker_compose : on ne l'écrase pas ici.

        # Appeler le script setup_traefik.sh (ajoute le service Traefik au
        # docker-compose.yml généré, crée le réseau et la config statique)
        if [ -f "$INSTALL_DIR/scripts/setup_traefik.sh" ]; then
            log "Installation de Traefik..."
            "$INSTALL_DIR/scripts/setup_traefik.sh" "$DOMAIN" "$EMAIL"
        else
            warn "Script setup_traefik.sh non trouvé, Traefik ne sera pas installé automatiquement"
            info "Vous pouvez l'installer manuellement après l'installation avec:"
            info "  sudo $INSTALL_DIR/scripts/setup_traefik.sh $DOMAIN $EMAIL"
        fi
    else
        log "Mode port direct - Traefik non installé"
    fi
}

#######################
# Génération du docker-compose.yml
#######################

# generate_docker_compose et les définitions des services système sont dans
# scripts/lib_compose_base.sh (partagées avec add_service.sh et la migration
# vers Traefik).

#######################
# Configuration interactive
#######################

configure_installation() {
    echo -e "\n${BLUE}╔════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Installation Seedbox Multi-Utilisateurs  ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════╝${NC}\n"

    # Configuration du domaine
    while true; do
        read -r -p "Nom de domaine (ex: exemple.com): " input_domain
        if [[ "$input_domain" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$ ]]; then
            DOMAIN=$input_domain
            break
        else
            warn "Nom de domaine invalide"
        fi
    done

    while true; do
        read -r -p "Email administrateur: " input_email
        if validate_email "$input_email" 2>/dev/null; then
            EMAIL=$input_email
            break
        else
            warn "Email invalide"
        fi
    done

    # Configuration Traefik (reverse proxy + SSL)
    echo -e "\n${BLUE}=== Configuration d'accès ===${NC}"
    echo "Mode d'accès aux services:"
    echo "  - Port direct : Services accessibles via http://IP:PORT (simple, pas de SSL)"
    echo "  - Traefik + SSL : Services accessibles via https://user.${DOMAIN}/service (sécurisé, nécessite DNS)"
    echo ""
    read -r -p "Utiliser Traefik avec SSL automatique ? (o/N): " input
    if [[ $input =~ ^[oO]$ ]]; then
        USE_TRAEFIK=true
        info "Mode Traefik activé"

        echo ""
        echo -e "${BLUE}=== Configuration DNS ===${NC}"
        echo "Traefik nécessite un DNS wildcard pointant vers ce serveur."
        echo ""
        read -r -p "Avez-vous déjà un nom de domaine (ex: monseedbox.com) ? (o/N): " has_domain

        if [[ $has_domain =~ ^[oO]$ ]]; then
            # L'utilisateur a un domaine
            info "Configuration DNS avec votre domaine existant"
            echo ""
            echo "Options de configuration DNS:"
            echo "  1. Cloudflare (automatique via API)"
            echo "  2. Autre provider (configuration manuelle)"
            echo "  3. Je l'ai déjà configuré"
            echo ""
            read -r -p "Votre choix [1/2/3]: " dns_choice

            case $dns_choice in
                1)
                    info "Configuration Cloudflare automatique"
                    if [ -f "$INSTALL_DIR/scripts/setup_cloudflare.sh" ]; then
                        if "$INSTALL_DIR/scripts/setup_cloudflare.sh" "$DOMAIN"; then
                            info "✓ DNS Cloudflare configuré avec succès"
                        else
                            warn "La configuration Cloudflare a échoué"
                            warn "Vous pouvez réessayer plus tard avec:"
                            warn "  sudo $INSTALL_DIR/scripts/setup_cloudflare.sh"
                            USE_TRAEFIK=false
                        fi
                    else
                        warn "Script setup_cloudflare.sh non trouvé"
                        USE_TRAEFIK=false
                    fi
                    ;;
                2)
                    info "Configuration manuelle requise"
                    echo ""
                    warn "Configurez ces enregistrements DNS:"
                    warn "  - Type A : $DOMAIN → IP de ce serveur"
                    warn "  - Type A : *.$DOMAIN → IP de ce serveur"
                    echo ""
                    info "Documentation complète: $INSTALL_DIR/docs/DNS_SETUP.md"
                    echo ""
                    read -r -p "DNS configuré et prêt ? (o/N): " dns_ready
                    if [[ ! $dns_ready =~ ^[oO]$ ]]; then
                        warn "Traefik désactivé. Configurez le DNS puis exécutez:"
                        warn "  sudo $INSTALL_DIR/scripts/check_dns.sh $DOMAIN"
                        warn "  sudo $INSTALL_DIR/scripts/setup_traefik.sh $DOMAIN $EMAIL"
                        USE_TRAEFIK=false
                    fi
                    ;;
                3)
                    info "Vérification DNS..."
                    if [ -f "$INSTALL_DIR/scripts/check_dns.sh" ]; then
                        if "$INSTALL_DIR/scripts/check_dns.sh" "$DOMAIN"; then
                            info "✓ DNS vérifié et opérationnel"
                        else
                            warn "La vérification DNS a échoué"
                            warn "Vérifiez votre configuration DNS puis réessayez"
                            USE_TRAEFIK=false
                        fi
                    else
                        warn "Impossible de vérifier le DNS automatiquement"
                        read -r -p "Continuer quand même ? (o/N): " force_continue
                        if [[ ! $force_continue =~ ^[oO]$ ]]; then
                            USE_TRAEFIK=false
                        fi
                    fi
                    ;;
                *)
                    warn "Choix invalide, Traefik désactivé"
                    USE_TRAEFIK=false
                    ;;
            esac
        else
            # L'utilisateur n'a pas de domaine - proposer DuckDNS
            info "Configuration DNS avec DuckDNS (gratuit)"
            echo ""
            info "DuckDNS est un service DNS 100% gratuit avec:"
            echo "  ✓ Wildcard DNS automatique"
            echo "  ✓ Pas besoin d'acheter un domaine"
            echo "  ✓ Mise à jour automatique de l'IP"
            echo "  ✓ Compatible Let's Encrypt SSL"
            echo ""
            read -r -p "Configurer DuckDNS automatiquement ? (o/N): " setup_duckdns

            if [[ $setup_duckdns =~ ^[oO]$ ]]; then
                if [ -f "$INSTALL_DIR/scripts/setup_duckdns.sh" ]; then
                    if "$INSTALL_DIR/scripts/setup_duckdns.sh"; then
                        # Lire le domaine depuis .env
                        if [ -f "$INSTALL_DIR/.env" ] && grep -q "^DOMAIN=" "$INSTALL_DIR/.env"; then
                            DOMAIN=$(grep "^DOMAIN=" "$INSTALL_DIR/.env" | cut -d'=' -f2)
                            info "✓ DuckDNS configuré: $DOMAIN"
                        else
                            warn "Impossible de lire le domaine DuckDNS depuis .env"
                            USE_TRAEFIK=false
                        fi
                    else
                        warn "La configuration DuckDNS a échoué"
                        warn "Vous pouvez réessayer plus tard avec:"
                        warn "  sudo $INSTALL_DIR/scripts/setup_duckdns.sh"
                        USE_TRAEFIK=false
                    fi
                else
                    warn "Script setup_duckdns.sh non trouvé"
                    USE_TRAEFIK=false
                fi
            else
                info "Installation en mode port direct"
                USE_TRAEFIK=false
            fi
        fi

        # Vérification finale des ports
        if [ "$USE_TRAEFIK" = "true" ]; then
            echo ""
            warn "⚠️  Vérifiez que les ports 80 et 443 sont ouverts dans votre firewall"
            read -r -p "Ports 80/443 ouverts ? (o/N): " ports_open
            if [[ ! $ports_open =~ ^[oO]$ ]]; then
                warn "Ouvrez les ports puis réinstallez Traefik avec:"
                warn "  sudo $INSTALL_DIR/scripts/setup_traefik.sh $DOMAIN $EMAIL"
                USE_TRAEFIK=false
            fi
        fi
    else
        info "Mode port direct sélectionné"
    fi

    # Le premier utilisateur sera créé comme administrateur plus tard

    # Services optionnels
    echo -e "\n${BLUE}=== Services de streaming ===${NC}"
    read -r -p "Installer Plex (serveur de streaming) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_PLEX=true

    read -r -p "Installer Jellyfin (alternative open-source à Plex) ? (o/N): " input
    if [[ $input =~ ^[oO]$ ]]; then
        INSTALL_JELLYFIN=true

        # Configurer les identifiants Jellyfin
        echo -e "\n${BLUE}Configuration Jellyfin:${NC}"
        read -r -p "Nom d'utilisateur admin [admin]: " JELLYFIN_USER
        JELLYFIN_USER=${JELLYFIN_USER:-"admin"}

        while true; do
            read -r -s -p "Mot de passe admin (min 8 caractères): " JELLYFIN_PASSWORD
            echo
            if [ ${#JELLYFIN_PASSWORD} -ge 8 ]; then
                read -r -s -p "Confirmez le mot de passe: " JELLYFIN_PASSWORD_CONFIRM
                echo
                if [ "$JELLYFIN_PASSWORD" = "$JELLYFIN_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 8 caractères"
            fi
        done
    fi

    # Vérification conflit Plex/Jellyfin
    if [ "$INSTALL_PLEX" = true ] && [ "$INSTALL_JELLYFIN" = true ]; then
        echo ""
        warn "⚠️  ATTENTION: Conflit potentiel détecté !"
        warn "    Plex et Jellyfin utilisent tous deux le port UDP 1900 (UPnP/DLNA)"
        warn "    Il est fortement recommandé de n'installer qu'un seul service de streaming"
        echo ""
        read -r -p "Voulez-vous annuler l'installation de Jellyfin ? (O/n): " confirm
        if [[ ! $confirm =~ ^[nN]$ ]]; then
            INSTALL_JELLYFIN=false
            JELLYFIN_USER=""
            JELLYFIN_PASSWORD=""
            info "Installation de Jellyfin annulée"
        else
            warn "Les deux services seront installés - des conflits peuvent survenir"
        fi
    fi

    echo -e "\n${BLUE}=== Dashboards & Monitoring ===${NC}"
    read -r -p "Installer Dashdot (monitoring système élégant) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_DASHDOT=true

    read -r -p "Installer Scrutiny (monitoring disques S.M.A.R.T.) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_SCRUTINY=true

    read -r -p "Installer Uptime Kuma (monitoring uptime) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_UPTIME_KUMA=true

    read -r -p "Installer Tautulli (statistiques Plex) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_TAUTULLI=true

    echo -e "\n${BLUE}=== Gestion & Organisation ===${NC}"
    read -r -p "Installer Portainer (gestion Docker web) ? (o/N): " input
    if [[ $input =~ ^[oO]$ ]]; then
        INSTALL_PORTAINER=true

        # Configurer les identifiants Portainer
        echo -e "\n${BLUE}Configuration Portainer:${NC}"
        read -r -p "Nom d'utilisateur admin [admin]: " PORTAINER_USER
        PORTAINER_USER=${PORTAINER_USER:-"admin"}

        while true; do
            read -r -s -p "Mot de passe admin (min 12 caractères): " PORTAINER_PASSWORD
            echo
            if [ ${#PORTAINER_PASSWORD} -ge 12 ]; then
                read -r -s -p "Confirmez le mot de passe: " PORTAINER_PASSWORD_CONFIRM
                echo
                if [ "$PORTAINER_PASSWORD" = "$PORTAINER_PASSWORD_CONFIRM" ]; then
                    break
                else
                    warn "Les mots de passe ne correspondent pas"
                fi
            else
                warn "Le mot de passe doit contenir au moins 12 caractères"
            fi
        done
    fi

    echo -e "\n${BLUE}=== Maintenance ===${NC}"
    read -r -p "Installer Watchtower (mises à jour auto) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_WATCHTOWER=true

    read -r -p "Installer Duplicati (backups) ? (o/N): " input
    [[ $input =~ ^[oO]$ ]] && INSTALL_DUPLICATI=true

    # Utilisateurs initiaux
    echo -e "\n${BLUE}=== Utilisateurs initiaux ===${NC}"
    info "Le premier utilisateur sera l'ADMINISTRATEUR (obligatoire : Authelia"
    info "ne démarre pas sans au moins un compte)."
    info "Noms : lettres minuscules et chiffres uniquement (ex: alice, bob2)."
    # Tableaux parallèles (et non "nom:mdp:…" : un ':' dans le mot de passe
    # décalerait tous les champs à la relecture).
    INITIAL_USERS=(); INITIAL_PASSWORDS=(); INITIAL_EMAILS=(); INITIAL_QUOTAS=()
    local username password password_confirm email quota add_user u dup
    while true; do
        if [ ${#INITIAL_USERS[@]} -gt 0 ]; then
            read -r -p "Ajouter un autre utilisateur ? (o/N): " add_user
            [[ $add_user =~ ^[oO]$ ]] || break
        fi

        while true; do
            read -r -p "Nom d'utilisateur: " username
            if [[ ! "$username" =~ ^[a-z][a-z0-9]{0,31}$ ]]; then
                warn "Nom invalide (lettres minuscules et chiffres, commence par une lettre)"
                continue
            fi
            dup=false
            for u in "${INITIAL_USERS[@]}"; do [ "$u" = "$username" ] && dup=true; done
            if $dup || id "$username" &>/dev/null; then
                warn "L'utilisateur '$username' existe déjà"
                continue
            fi
            break
        done

        # Le premier utilisateur est administrateur : règle renforcée
        local is_admin=false reason
        [ ${#INITIAL_USERS[@]} -eq 0 ] && is_admin=true
        info "Mot de passe : $(password_policy "$is_admin")"
        while true; do
            read -r -s -p "Mot de passe: " password
            echo
            if reason=$(password_check "$password" "$is_admin"); then
                read -r -s -p "Confirmez: " password_confirm
                echo
                if [ "$password" = "$password_confirm" ]; then
                    break
                fi
                warn "Les mots de passe ne correspondent pas"
            else
                warn "Mot de passe refusé : $reason"
            fi
        done

        while true; do
            read -r -p "Email: " email
            [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] && break
            warn "Format d'email invalide"
        done

        while true; do
            read -r -p "Quota (GB) [${DEFAULT_QUOTA}]: " quota
            quota=${quota:-$DEFAULT_QUOTA}
            [[ "$quota" =~ ^[1-9][0-9]*$ ]] && break
            warn "Le quota doit être un nombre entier positif"
        done

        INITIAL_USERS+=("$username"); INITIAL_PASSWORDS+=("$password")
        INITIAL_EMAILS+=("$email");   INITIAL_QUOTAS+=("$quota")
    done

    # Récapitulatif
    echo -e "\n${BLUE}=== Récapitulatif ===${NC}"
    echo "Domaine: $DOMAIN"
    echo "Email: $EMAIL"
    echo "Premier utilisateur (Admin): ${INITIAL_USERS[0]}"
    echo "Utilisateurs totaux: ${#INITIAL_USERS[@]} (${INITIAL_USERS[*]})"
    echo "Services optionnels:"
    [ "$INSTALL_PLEX" = true ] && echo "  ✓ Plex"
    [ "$INSTALL_JELLYFIN" = true ] && echo "  ✓ Jellyfin"
    [ "$INSTALL_DASHDOT" = true ] && echo "  ✓ Dashdot"
    [ "$INSTALL_SCRUTINY" = true ] && echo "  ✓ Scrutiny"
    [ "$INSTALL_UPTIME_KUMA" = true ] && echo "  ✓ Uptime Kuma"
    [ "$INSTALL_TAUTULLI" = true ] && echo "  ✓ Tautulli"
    [ "$INSTALL_PORTAINER" = true ] && echo "  ✓ Portainer"
    [ "$INSTALL_WATCHTOWER" = true ] && echo "  ✓ Watchtower"
    [ "$INSTALL_DUPLICATI" = true ] && echo "  ✓ Duplicati"
    echo "Utilisateurs: ${#INITIAL_USERS[@]}"

    read -r -p "Continuer l'installation ? (o/N): " confirm
    if [[ ! $confirm =~ ^[oO]$ ]]; then
        error "Installation annulée"
    fi
}

#######################
# Ajout d'utilisateur à Authelia
#######################

# Note: La fonction add_authelia_user n'est plus utilisée
# Les utilisateurs sont créés via scripts/add_user.sh qui gère à la fois
# Authelia et les conteneurs Docker

#######################
# Déploiement
#######################

deploy_services() {
    log "Démarrage des services..."

    cd "$INSTALL_DIR" || error "Répertoire $INSTALL_DIR introuvable"
    docker-compose pull
    docker-compose up -d

    # Comptes administrateur Portainer / Jellyfin (API, avec attente)
    if [ "$INSTALL_PORTAINER" = true ] && [ -n "$PORTAINER_USER" ] && [ -n "$PORTAINER_PASSWORD" ]; then
        autoconfig_portainer "$PORTAINER_USER" "$PORTAINER_PASSWORD" || true
    fi
    if [ "$INSTALL_JELLYFIN" = true ] && [ -n "$JELLYFIN_USER" ] && [ -n "$JELLYFIN_PASSWORD" ]; then
        autoconfig_jellyfin "$JELLYFIN_USER" "$JELLYFIN_PASSWORD" || true
    fi

    # Plex tourne en réseau hôte : le pare-feu s'applique à lui (contrairement
    # aux ports publiés par Docker)
    if [ "$INSTALL_PLEX" = true ] && command -v ufw &>/dev/null; then
        ufw allow 32400/tcp comment 'Plex' >/dev/null 2>&1 || true
    fi

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

    # Créer la structure de dossiers et copier les scripts AVANT la
    # configuration interactive : celle-ci peut appeler les scripts DNS/Traefik
    # (setup_cloudflare.sh, setup_duckdns.sh, check_dns.sh) depuis $INSTALL_DIR/scripts.
    prepare_directories
    show_progress 5 10 "Installation"

    configure_installation
    show_progress 6 10 "Installation"

    configure_authelia
    show_progress 7 10 "Installation"

    # Générer le docker-compose.yml de base (Authelia + services système) et
    # le .env. Doit précéder :
    #  - setup_traefik.sh, qui AJOUTE (>>) le service Traefik au compose ;
    #  - add_user.sh, qui AJOUTE (>>) les services par-utilisateur.
    # (generate_docker_compose fait un `cat >` : l'appeler après écraserait
    #  ces ajouts.)
    generate_docker_compose

    # Configurer Traefik si activé : crée le réseau traefik_proxy (requis par
    # les services utilisateurs) et ajoute le conteneur Traefik au compose.
    setup_traefik_if_enabled
    # Homarr partagé + connexion unique : secrets (.env) et client OIDC dans
    # la configuration Authelia (avant son premier démarrage)
    if [ "$USE_TRAEFIK" = "true" ]; then
        local hrc=0
        homarr_prepare || hrc=$?
        [ "$hrc" -ge 2 ] && warn "Connexion unique Homarr non configurée (relancez generate_traefik_labels.sh)"
    fi
    show_progress 8 10 "Installation"

    # Créer les utilisateurs avec add_user.sh (le premier = administrateur ;
    # configure_installation garantit qu'il y en a au moins un)
    log "Création des utilisateurs..."
    local i admin_flag
    for ((i=0; i<${#INITIAL_USERS[@]}; i++)); do
        admin_flag=""
        [ "$i" -eq 0 ] && admin_flag="--admin"
        log "Création de l'utilisateur ${INITIAL_USERS[$i]}${admin_flag:+ (administrateur)}"
        "$INSTALL_DIR/scripts/add_user.sh" "${INITIAL_USERS[$i]}" "${INITIAL_PASSWORDS[$i]}" \
            "${INITIAL_EMAILS[$i]}" "${INITIAL_QUOTAS[$i]}" $admin_flag
    done
    show_progress 9 10 "Installation"

    deploy_services
    show_progress 10 10 "Installation"

    # Message final
    echo -e "\n${GREEN}╔════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║     Installation terminée avec succès !   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════╝${NC}\n"

    # Services système (administrateurs)
    local adm=() s sub port
    for s in dashdot scrutiny uptime-kuma tautulli portainer duplicati; do
        grep -q "^  ${s}:" "$INSTALL_DIR/docker-compose.yml" && adm+=("$s")
    done
    if [ "$USE_TRAEFIK" = "true" ]; then
        info "🔐 Portail de connexion (SSO) : https://auth.$DOMAIN"
        [ "$INSTALL_JELLYFIN" = true ] && echo "  - Jellyfin : https://jellyfin.$DOMAIN"
        [ "$INSTALL_PLEX" = true ]     && echo "  - Plex     : http://<ip-du-serveur>:32400/web"
        if [ ${#adm[@]} -gt 0 ]; then
            info "🛠️  Administration (groupe admins, via SSO) :"
            echo "  - Traefik : https://traefik.$DOMAIN"
            for s in "${adm[@]}"; do
                sub=$s; [ "$s" = uptime-kuma ] && sub=uptime
                echo "  - $s : https://${sub}.$DOMAIN"
            done
        fi
        info "🏠 Tableau de bord (Homarr, connexion unique) : https://$DOMAIN"
        echo "     1re visite de l'administrateur : terminer l'assistant Homarr et"
        echo "     indiquer le groupe administrateur « admins »"
        info "👥 Chaque utilisateur : https://<utilisateur>.$DOMAIN renvoie au tableau de bord"
        echo "     qBittorrent …/qbittorrent · Filebrowser …/files · Sonarr …/sonarr · Radarr …/radarr"
        echo "     (qBittorrent et Filebrowser redemandent les identifiants de la seedbox)"
        info "⏳ Certificats Let's Encrypt obtenus au premier accès (DNS *.${DOMAIN} requis)"
    else
        [ "$INSTALL_JELLYFIN" = true ] && echo "  - Jellyfin : http://<ip-du-serveur>:8096"
        [ "$INSTALL_PLEX" = true ]     && echo "  - Plex     : http://<ip-du-serveur>:32400/web"
        info "👥 Adresses des services de chaque utilisateur : sudo $INSTALL_DIR/scripts/list_user_services.sh <utilisateur>"
        if [ ${#adm[@]} -gt 0 ]; then
            info "🛠️  Administration : ports LOCAUX uniquement (sécurité, pas d'authentification)."
            echo "     Accès par tunnel SSH, par ex. :"
            for s in "${adm[@]}"; do
                port=$(grep -A12 "^  ${s}:" "$INSTALL_DIR/docker-compose.yml" | grep -oE ':[0-9]+:[0-9]+"' | head -1 | cut -d: -f2)
                echo "  - $s : ssh -L ${port}:localhost:${port} <compte>@<serveur>  puis  http://localhost:${port}"
            done
        fi
    fi
    [ "$INSTALL_PORTAINER" = true ] && [ -n "$PORTAINER_USER" ] && echo "  (Portainer : utilisateur $PORTAINER_USER)"
    echo ""

    echo -e "\n${YELLOW}Prochaines étapes:${NC}"
    echo ""
    echo -e "${CYAN}🎮 Utiliser le menu interactif (recommandé):${NC}"
    echo "   cd $INSTALL_DIR"
    echo "   sudo ./menu.sh"
    echo ""
    echo -e "${CYAN}Ou utiliser les scripts directement:${NC}"
    echo ""
    echo "1. Ajouter des utilisateurs:"
    echo "   cd $INSTALL_DIR/scripts"
    echo "   sudo ./add_user.sh <username> <password> <email> [quota] [--admin]"
    echo ""
    echo "2. Installer des services optionnels:"
    echo "   sudo ./add_service.sh <service_name>"
    echo ""
    echo "3. Gérer les quotas:"
    echo "   sudo ./update_quota.sh <username> <quota_gb>"
    echo ""
    echo "4. Vérifier l'état de la seedbox:"
    echo "   sudo ./healthcheck.sh"
    echo ""
    echo -e "${BLUE}📚 Documentation : dossier docs/ du dépôt ($SOURCE_DIR/docs)${NC}"

    log "Installation terminée !"
}

# Lancement
main "$@"
