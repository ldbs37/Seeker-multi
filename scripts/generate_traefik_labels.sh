#!/bin/bash

#######################
# Script de génération automatique des labels Traefik
# Parcourt tous les conteneurs et ajoute les labels appropriés
# Usage: ./generate_traefik_labels.sh
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
ENV_FILE="$INSTALL_DIR/.env"

# Vérification root
if [[ $EUID -ne 0 ]]; then
    error "Ce script doit être exécuté en tant que root"
fi

# Charger le domaine depuis .env
if [ ! -f "$ENV_FILE" ] || ! grep -q "^DOMAIN=" "$ENV_FILE"; then
    error "Domaine non configuré. Exécutez d'abord setup_traefik.sh"
fi

DOMAIN=$(grep "^DOMAIN=" "$ENV_FILE" | cut -d'=' -f2)

log "Génération des labels Traefik pour le domaine $DOMAIN..."

#######################
# Fonction pour générer les labels
#######################

generate_labels() {
    local service_name=$1
    local username=$2
    local port=$3
    local path=$4
    local protect_with_authelia=${5:-true}

    local labels=""

    # Déterminer le sous-domaine
    local subdomain
    if [ -n "$username" ]; then
        subdomain="${username}.${DOMAIN}"
    else
        subdomain="${service_name}.${DOMAIN}"
    fi

    # Labels de base
    labels+="      - \"traefik.enable=true\"\n"
    labels+="      - \"traefik.http.routers.${service_name}.rule=Host(\\\`${subdomain}\\\`)\""

    # Ajouter le path si spécifié
    if [ -n "$path" ]; then
        labels+=" && PathPrefix(\\\`${path}\\\`)"
    fi
    labels+="\n"

    labels+="      - \"traefik.http.routers.${service_name}.entrypoints=websecure\"\n"
    labels+="      - \"traefik.http.routers.${service_name}.tls.certresolver=letsencrypt\"\n"
    labels+="      - \"traefik.http.services.${service_name}.loadbalancer.server.port=${port}\"\n"

    # Protection Authelia
    if [ "$protect_with_authelia" = "true" ]; then
        labels+="      - \"traefik.http.routers.${service_name}.middlewares=authelia@docker\"\n"
    fi

    echo -e "$labels"
}

#######################
# Sauvegarder docker-compose.yml
#######################

cp "$DOCKER_COMPOSE_FILE" "${DOCKER_COMPOSE_FILE}.pre-labels-backup"
log "✓ Sauvegarde créée : ${DOCKER_COMPOSE_FILE}.pre-labels-backup"

#######################
# Générer labels pour chaque type de service
#######################

log "Analyse des services dans docker-compose.yml..."

# Créer un fichier temporaire pour le nouveau docker-compose
TMP_FILE=$(mktemp)

# Fonction pour ajouter les labels à un service
add_labels_to_service() {
    local service_pattern=$1
    local port=$2
    local path=$3
    local protect=$4

    while IFS= read -r line; do
        echo "$line" >> "$TMP_FILE"

        # Si on trouve un service correspondant
        if echo "$line" | grep -q "^  ${service_pattern}:"; then
            local service_name=$(echo "$line" | sed 's/://g' | xargs)
            local username=""

            # Extraire le username du nom du service (format: service-username)
            if [[ $service_name == *"-"* ]]; then
                username=$(echo "$service_name" | cut -d'-' -f2-)
            fi

            # Vérifier si le service a déjà des labels
            if ! grep -A 20 "^  ${service_pattern}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."

                # Attendre la section labels ou l'ajouter
                local in_service=true
                local labels_added=false

                while $in_service && IFS= read -r next_line; do
                    # Si on arrive à un nouveau service, ajouter les labels avant
                    if echo "$next_line" | grep -q "^  [a-z]"; then
                        if [ "$labels_added" = "false" ]; then
                            echo "    labels:" >> "$TMP_FILE"
                            generate_labels "$service_name" "$username" "$port" "$path" "$protect" >> "$TMP_FILE"
                        fi
                        echo "$next_line" >> "$TMP_FILE"
                        in_service=false
                    else
                        echo "$next_line" >> "$TMP_FILE"
                    fi
                done
            fi
        fi
    done < "$DOCKER_COMPOSE_FILE"
}

# Lire le fichier ligne par ligne et traiter les services
while IFS= read -r line; do
    echo "$line" >> "$TMP_FILE"

    # Détecter et ajouter les labels pour chaque type de service
    case "$line" in
        *"  qbittorrent-"*)
            service_name=$(echo "$line" | sed 's/://g' | xargs)
            username=$(echo "$service_name" | sed 's/qbittorrent-//')

            if ! grep -A 30 "^  ${service_name}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."

                # Lire jusqu'à trouver où insérer les labels
                local add_labels=true
                while $add_labels && IFS= read -r next_line; do
                    if echo "$next_line" | grep -q "^  [a-z]"; then
                        # Nouveau service, ajouter les labels avant
                        echo "    labels:" >> "$TMP_FILE"
                        generate_labels "$service_name" "$username" "8080" "/qbittorrent" "true" >> "$TMP_FILE"
                        echo "$next_line" >> "$TMP_FILE"
                        add_labels=false
                    else
                        echo "$next_line" >> "$TMP_FILE"
                    fi
                done
            fi
            ;;

        *"  homarr-"*)
            service_name=$(echo "$line" | sed 's/://g' | xargs)
            username=$(echo "$service_name" | sed 's/homarr-//')

            if ! grep -A 30 "^  ${service_name}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "$service_name" "$username" "7575" "" "true" >> "$TMP_FILE"
            fi
            ;;

        *"  filebrowser-"*)
            service_name=$(echo "$line" | sed 's/://g' | xargs)
            username=$(echo "$service_name" | sed 's/filebrowser-//')

            if ! grep -A 30 "^  ${service_name}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "$service_name" "$username" "80" "/files" "true" >> "$TMP_FILE"
            fi
            ;;

        *"  sonarr-"*)
            service_name=$(echo "$line" | sed 's/://g' | xargs)
            username=$(echo "$service_name" | sed 's/sonarr-//')

            if ! grep -A 30 "^  ${service_name}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "$service_name" "$username" "8989" "/sonarr" "true" >> "$TMP_FILE"
            fi
            ;;

        *"  radarr-"*)
            service_name=$(echo "$line" | sed 's/://g' | xargs)
            username=$(echo "$service_name" | sed 's/radarr-//')

            if ! grep -A 30 "^  ${service_name}:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour $service_name..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "$service_name" "$username" "7878" "/radarr" "true" >> "$TMP_FILE"
            fi
            ;;

        *"  jellyfin:"*)
            if ! grep -A 30 "^  jellyfin:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour jellyfin..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "jellyfin" "" "8096" "" "false" >> "$TMP_FILE"
            fi
            ;;

        *"  plex:"*)
            if ! grep -A 30 "^  plex:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour plex..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "plex" "" "32400" "" "false" >> "$TMP_FILE"
            fi
            ;;

        *"  portainer:"*)
            if ! grep -A 30 "^  portainer:" "$DOCKER_COMPOSE_FILE" | grep -q "traefik.enable"; then
                log "   Ajout labels pour portainer..."
                echo "    labels:" >> "$TMP_FILE"
                generate_labels "portainer" "" "9000" "" "true" >> "$TMP_FILE"
            fi
            ;;
    esac

done < "$DOCKER_COMPOSE_FILE"

# Remplacer le fichier original par le nouveau (temporairement commenté pour debug)
# mv "$TMP_FILE" "$DOCKER_COMPOSE_FILE"
# log "✓ Labels Traefik ajoutés au docker-compose.yml"

# Pour l'instant, afficher le diff
log "Aperçu des changements (fichier temporaire: $TMP_FILE)"

echo ""
info "═══════════════════════════════════════════════════════════"
info "Génération des labels terminée"
info "═══════════════════════════════════════════════════════════"
info ""
info "Fichier généré : $TMP_FILE"
info "Sauvegarde : ${DOCKER_COMPOSE_FILE}.pre-labels-backup"
info ""
info "Pour appliquer les changements :"
info "  mv $TMP_FILE $DOCKER_COMPOSE_FILE"
info "  cd $INSTALL_DIR && docker-compose up -d"
info ""
info "═══════════════════════════════════════════════════════════"
