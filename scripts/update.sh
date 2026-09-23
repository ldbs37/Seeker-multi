#!/bin/bash
#######################
# update.sh — Module de mise à jour de la seedbox
#
# Les images sont ÉPINGLÉES à l'installation (stabilité/reproductibilité).
# Ce module permet de mettre à jour quand VOUS le décidez :
#   - le système (apt)
#   - les images Docker (re-pull des tags actuels, ou changement de version)
#   - le module seedbox (scripts + menu, depuis le dépôt git)
#
# Usage :
#   update.sh                 # menu interactif
#   update.sh --system        # met à jour le système (apt)
#   update.sh --docker        # re-pull des images épinglées + redéploiement
#   update.sh --seedbox       # met à jour scripts/menu depuis le dépôt
#   update.sh --all           # système + docker (re-pull) + seedbox
#######################

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
COMPOSE="$INSTALL_DIR/docker-compose.yml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}✓${NC} $1"; }

[ "${EUID:-$(id -u)}" -eq 0 ] || error "Ce script doit être exécuté en tant que root"

# Choix du binaire compose (v1 'docker-compose' ou v2 'docker compose')
compose() {
    if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
    else docker compose "$@"; fi
}

# Vérification complète du système (script séparé)
run_healthcheck() {
    local hc="$(dirname "$0")/healthcheck.sh"
    if [ -x "$hc" ]; then
        echo ""
        log "Vérification du système (healthcheck)..."
        INSTALL_DIR="$INSTALL_DIR" "$hc" || warn "Le healthcheck signale des problèmes (voir ci-dessus)."
    else
        warn "healthcheck.sh introuvable — vérification ignorée"
    fi
}

#######################
# 1) Système (apt)
#######################
update_system() {
    log "Mise à jour du système (apt)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update || { warn "apt-get update a échoué"; return 1; }
    apt-get upgrade -y || { warn "apt-get upgrade a échoué"; return 1; }
    apt-get autoremove -y || true
    apt-get clean || true
    success "Système à jour"
}

#######################
# 2) Images Docker
#######################
# Re-pull des tags actuels (récupère d'éventuels rebuilds du même tag)
update_docker_pull() {
    [ -f "$COMPOSE" ] || { warn "docker-compose.yml introuvable ($COMPOSE)"; return 1; }
    log "Re-pull des images épinglées..."
    ( cd "$INSTALL_DIR" && compose pull ) || { warn "pull a échoué"; return 1; }
    log "Redéploiement..."
    ( cd "$INSTALL_DIR" && compose up -d ) || { warn "up -d a échoué"; return 1; }
    docker image prune -f >/dev/null 2>&1 || true
    success "Images à jour (tags inchangés)"
    run_healthcheck
}

# Changer la version épinglée d'une image, puis redéployer
update_docker_bump() {
    [ -f "$COMPOSE" ] || { warn "docker-compose.yml introuvable ($COMPOSE)"; return 1; }

    mapfile -t IMAGES < <(grep -oE 'image:[[:space:]]*[^[:space:]]+' "$COMPOSE" \
                          | sed -E 's/image:[[:space:]]*//' | sort -u)
    if [ "${#IMAGES[@]}" -eq 0 ]; then warn "Aucune image trouvée"; return 1; fi

    echo ""
    info "Images actuellement épinglées :"
    local i=1
    for img in "${IMAGES[@]}"; do echo "  $i) $img"; i=$((i+1)); done
    echo ""
    read -r -p "Numéro de l'image à changer (0 = annuler) : " n
    [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#IMAGES[@]}" ] || { info "Annulé"; return 0; }

    local current="${IMAGES[$((n-1))]}"
    local repo="${current%:*}"
    local oldtag="${current##*:}"
    echo ""
    info "Image : $repo (tag actuel : $oldtag)"
    read -r -p "Nouveau tag : " newtag
    [ -n "$newtag" ] || { warn "Tag vide, annulé"; return 0; }
    [ "$newtag" = "$oldtag" ] && { info "Tag identique, rien à faire"; return 0; }

    # Sauvegarde puis remplacement ciblé (repo identique, on ne change que le tag)
    local backup="$COMPOSE.bak.$(date +%Y%m%d%H%M%S)"
    cp "$COMPOSE" "$backup"
    sed -i "s#\(image:[[:space:]]*${repo}\):[^[:space:]]*#\1:${newtag}#g" "$COMPOSE"
    log "docker-compose.yml : $repo:$oldtag -> $repo:$newtag (sauvegarde : $backup)"

    log "Téléchargement et redéploiement..."
    if ( cd "$INSTALL_DIR" && compose pull && compose up -d ); then
        docker image prune -f >/dev/null 2>&1 || true
        success "Image $repo mise à jour vers $newtag"
        run_healthcheck
    else
        warn "Échec du déploiement — restauration de la configuration précédente"
        cp "$backup" "$COMPOSE"
        ( cd "$INSTALL_DIR" && compose up -d ) || true
        error "Mise à jour annulée (config restaurée depuis $backup)"
    fi
}

#######################
# 3) Module seedbox (scripts + menu)
#######################
update_seedbox() {
    local src="" url="" sync_from="" tmp=""

    if [ -f "$INSTALL_DIR/.source" ]; then
        src=$(grep -E '^path=' "$INSTALL_DIR/.source" | cut -d'=' -f2-)
        url=$(grep -E '^url='  "$INSTALL_DIR/.source" | cut -d'=' -f2-)
    fi

    if [ -n "$src" ] && [ -d "$src/.git" ]; then
        log "Mise à jour du dépôt local : $src"
        git -C "$src" pull --ff-only || warn "git pull a échoué (dépôt local modifié ?)"
        sync_from="$src"
    elif [ -n "$url" ]; then
        tmp=$(mktemp -d)
        log "Clonage depuis $url ..."
        git clone --depth 1 "$url" "$tmp" || { rm -rf "$tmp"; error "Clonage échoué"; }
        sync_from="$tmp"
    else
        read -r -p "Chemin d'un dépôt git local ou URL git : " ans
        [ -n "$ans" ] || { info "Annulé"; return 0; }
        if [ -d "$ans/.git" ]; then
            git -C "$ans" pull --ff-only || warn "git pull a échoué"
            sync_from="$ans"
        else
            tmp=$(mktemp -d)
            git clone --depth 1 "$ans" "$tmp" || { rm -rf "$tmp"; error "Clonage échoué"; }
            sync_from="$tmp"
        fi
    fi

    [ -d "$sync_from/scripts" ] || { [ -n "$tmp" ] && rm -rf "$tmp"; error "Source invalide (pas de dossier scripts/)"; }

    log "Synchronisation des scripts de gestion et du menu..."
    # On ne met à jour QUE le code de gestion : ni docker-compose.yml, ni .env,
    # ni la config Authelia, ni les données utilisateurs ne sont touchés.
    cp "$sync_from"/scripts/*.sh "$INSTALL_DIR/scripts/" && chmod +x "$INSTALL_DIR/scripts/"*.sh
    [ -f "$sync_from/menu.sh" ] && { cp "$sync_from/menu.sh" "$INSTALL_DIR/menu.sh"; chmod +x "$INSTALL_DIR/menu.sh"; }

    [ -n "$tmp" ] && rm -rf "$tmp"
    success "Module seedbox mis à jour (scripts + menu)"
    info "Note : le docker-compose.yml existant n'est pas régénéré (services préservés)."
}

#######################
# Menu interactif
#######################
menu() {
    while true; do
        echo ""
        echo -e "${BLUE}=== Module de mise à jour ===${NC}"
        echo "  1) Système (apt update && upgrade)"
        echo "  2) Images Docker — re-pull des tags actuels"
        echo "  3) Images Docker — changer la version d'une image"
        echo "  4) Module seedbox (scripts + menu depuis git)"
        echo "  5) Tout (système + re-pull Docker + module)"
        echo "  6) Vérifier le système (healthcheck complet)"
        echo "  0) Quitter"
        echo ""
        read -r -p "Choix : " c
        case "$c" in
            1) update_system ;;
            2) update_docker_pull ;;
            3) update_docker_bump ;;
            4) update_seedbox ;;
            5) update_system; update_docker_pull; update_seedbox ;;
            6) run_healthcheck ;;
            0) break ;;
            *) warn "Choix invalide" ;;
        esac
    done
}

case "${1:-}" in
    --system)  update_system ;;
    --docker)  update_docker_pull ;;
    --bump)    update_docker_bump ;;
    --seedbox) update_seedbox ;;
    --all)     update_system; update_docker_pull; update_seedbox ;;
    --check)   run_healthcheck ;;
    ""|--menu) menu ;;
    *) error "Option inconnue : $1 (voir --system|--docker|--bump|--seedbox|--all|--check)" ;;
esac
