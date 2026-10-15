#!/bin/bash
#######################
# test_update.sh — Essayer une nouvelle version d'une appli, avec retour en
# arrière rapide.
#
#   sudo ./test_update.sh <service> <version>   # essai
#   sudo ./test_update.sh <service> --rollback  # retour à l'ancienne version
#   sudo ./test_update.sh <service> --keep      # nouvelle version gardée
#   sudo ./test_update.sh --status              # essais en cours
#
# <service> : nom du service dans le docker-compose.yml : « homarr »,
# « jellyfin »… ou celui d'un utilisateur, « seerr-louis » (un seul
# utilisateur testé, les autres ne sont pas touchés).
#
# Essai : service arrêté, ses données de configuration sauvegardées (dossiers
# montés en écriture, hors fichiers des utilisateurs : /data, /srv, /books,
# /media), nouvelle version démarrée. Une nouvelle version convertit souvent
# ses données au premier démarrage : le retour en arrière remet donc les
# données sauvegardées ET l'ancienne version (données de l'essai gardées à
# côté, « .essai-<date> », pour diagnostic).
# La version essayée est retenue dans $INSTALL_DIR/image_overrides : les
# régénérations du compose (generate_traefik_labels.sh…) la conservent.
# « --keep » la garde jusqu'à ce que la seedbox fixe cette version.
#######################

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
TESTS_DIR="$INSTALL_DIR/update_tests"
OVERRIDES="$INSTALL_DIR/image_overrides"

for lib in lib_ports lib_traefik lib_services lib_compose_base; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || error "$lib.sh introuvable"
done

usage() {
    sed -n '/^#   sudo/p' "$0" | sed 's/^#   //'
    exit 1
}

[[ $EUID -eq 0 ]] || error "Ce script doit être exécuté en tant que root"
[ -f "$DOCKER_COMPOSE_FILE" ] || error "docker-compose.yml introuvable"

# Image actuelle du service $1 dans le compose
compose_image() {
    awk -v name="$1:" '/^  [^ #]/ { inb = ($1 == name) } /^[^ ]/ { inb = 0 }
        inb && /^    image: / { print $2; exit }' "$DOCKER_COMPOSE_FILE"
}

override_set() {   # $1=service [$2=image ; vide = retirer]
    local tmp="$OVERRIDES.tmp"
    { grep -v "^$1=" "$OVERRIDES" 2>/dev/null; [ -n "${2:-}" ] && echo "$1=$2"; } > "$tmp"
    mv "$tmp" "$OVERRIDES"
}

# Dossiers de configuration montés en écriture (sources hôte), un par ligne
config_mounts() {
    docker inspect -f '{{range .Mounts}}{{.Type}}|{{.Source}}|{{.Destination}}|{{.RW}}{{"\n"}}{{end}}' "$1" 2>/dev/null \
        | awk -F'|' '$1 == "bind" && $4 == "true" && $3 !~ /^\/(data|srv|books|media|downloads)(\/|$)/ && $2 !~ /docker\.sock$/ { print $2 }'
}

# Vérifications et automatismes après démarrage de la nouvelle version
after_start() {
    local svc="$1" user=""
    [[ "$svc" == *-* ]] && user=${svc##*-}
    case "$svc" in
        homarr)
            log "Création des tableaux de bord (homarr_provision.sh --all)…"
            if "$SCRIPT_DIR/homarr_provision.sh" --all; then
                log "✓ Tableaux de bord créés sans erreur"
            else
                warn "Création des tableaux de bord en échec : à corriger avant de garder cette version"
            fi
            info "À vérifier : https://$DOMAIN (connexion via Authelia, tuiles, widgets Téléchargements / Calendrier / Demandes)" ;;
        seerr-*)
            log "Configuration de Seerr de $user (arr_setup.sh)…"
            "$SCRIPT_DIR/arr_setup.sh" "$user" || warn "Configuration de Seerr en échec"
            info "À vérifier : $(USERNAME=$user service_url seerr) — connexion automatique (pas de page de connexion), demandes, liens vers Jellyfin" ;;
        filebrowser-*)
            info "À vérifier : https://$user.$DOMAIN/drive — connexion automatique, fichiers, liens de partage (…/drive/public/…)" ;;
        *)
            info "À vérifier : l'appli s'ouvre, la connexion (Authelia) passe, ses fonctions habituelles marchent" ;;
    esac
}

status() {
    local d
    shopt -s nullglob
    for d in "$TESTS_DIR"/*/; do
        [ -f "$d/state" ] || continue
        # shellcheck source=/dev/null
        ( . "$d/state"; echo "$(basename "$d") : $STATE — $OLD_IMAGE → $NEW_IMAGE ($DATE)" )
    done
    [ -s "$OVERRIDES" ] && { echo "Versions imposées (image_overrides) :"; sed 's/^/  /' "$OVERRIDES"; }
    return 0
}

[ $# -ge 1 ] || usage
[ "$1" = --status ] && { status; exit 0; }
[ $# -eq 2 ] || usage
SVC="$1"; ARG="$2"
[[ "$SVC" =~ ^[a-z0-9_-]+$ ]] || error "Nom de service invalide : $SVC"
grep -q "^  ${SVC}:" "$DOCKER_COMPOSE_FILE" || error "Service $SVC absent du docker-compose.yml"
DOMAIN=$(grep '^DOMAIN=' "$INSTALL_DIR/.env" | cut -d= -f2)
DIR="$TESTS_DIR/$SVC"
STATE_FILE="$DIR/state"
cd "$INSTALL_DIR" || exit 1

case "$ARG" in
    --rollback)
        [ -f "$STATE_FILE" ] || error "Aucun essai en cours pour $SVC"
        # shellcheck source=/dev/null
        . "$STATE_FILE"
        log "Retour de $SVC à $OLD_IMAGE…"
        docker stop "$SVC" >/dev/null 2>&1 || true
        stamp=$(date +%Y%m%d-%H%M%S)
        i=0
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            if [ -e "$src" ]; then mv "$src" "$src.essai-$stamp"; fi
            tar -xzpf "$DIR/backup-$i.tgz" -C / --numeric-owner || error "Restauration de $src impossible (sauvegarde : $DIR/backup-$i.tgz)"
            info "Données de l'essai gardées : $src.essai-$stamp (à supprimer quand tout va bien)"
            i=$((i + 1))
        done < "$DIR/mounts"
        compose_set_image "$DOCKER_COMPOSE_FILE" "$SVC" "$OLD_IMAGE" || error "Image de $SVC non remise dans le compose"
        override_set "$SVC"
        compose_cmd up -d "$SVC" || error "Redémarrage de $SVC impossible"
        sed -i 's/^STATE=.*/STATE="annulé"/' "$STATE_FILE"
        log "${GREEN}✓${NC} $SVC revenu à $OLD_IMAGE avec ses données d'avant l'essai"
        docker rmi "$NEW_IMAGE" >/dev/null 2>&1 && info "Version essayée $NEW_IMAGE supprimée" ;;
    --keep)
        [ -f "$STATE_FILE" ] || error "Aucun essai en cours pour $SVC"
        # shellcheck source=/dev/null
        . "$STATE_FILE"
        sed -i 's/^STATE=.*/STATE="gardé"/' "$STATE_FILE"
        log "${GREEN}✓${NC} $SVC garde $NEW_IMAGE"
        # Ancienne version : supprimée si plus aucun conteneur ne l'utilise
        docker rmi "$OLD_IMAGE" >/dev/null 2>&1 && info "Ancienne version $OLD_IMAGE supprimée"
        info "Version retenue dans $OVERRIDES jusqu'à ce que la seedbox fixe $NEW_IMAGE."
        info "Sauvegarde d'avant l'essai conservée : $DIR (à supprimer dans quelques jours)" ;;
    -*)
        usage ;;
    *)
        NEW_TAG="$ARG"
        [[ "$NEW_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || error "Version invalide : $NEW_TAG"
        if [ -f "$STATE_FILE" ] && grep -q '^STATE="en cours"' "$STATE_FILE"; then
            error "Essai déjà en cours pour $SVC : --rollback ou --keep d'abord"
        fi
        OLD_IMAGE=$(compose_image "$SVC")
        [ -n "$OLD_IMAGE" ] || error "Image de $SVC introuvable dans le compose"
        NEW_IMAGE="${OLD_IMAGE%:*}:$NEW_TAG"
        [ "$NEW_IMAGE" != "$OLD_IMAGE" ] || error "$SVC est déjà en $NEW_IMAGE"
        log "Téléchargement de $NEW_IMAGE…"
        docker pull -q "$NEW_IMAGE" >/dev/null || error "Version introuvable : $NEW_IMAGE"
        mkdir -p "$DIR"; chmod 700 "$TESTS_DIR" "$DIR"
        rm -f "$DIR"/backup-*.tgz
        config_mounts "$SVC" > "$DIR/mounts"
        [ -s "$DIR/mounts" ] || warn "Aucune donnée de configuration montée trouvée pour $SVC (retour en arrière : version seulement)"
        log "Arrêt de $SVC et sauvegarde de ses données…"
        docker stop "$SVC" >/dev/null 2>&1 || true
        i=0
        while IFS= read -r src; do
            [ -n "$src" ] || continue
            tar -czpf "$DIR/backup-$i.tgz" -C / --numeric-owner "${src#/}" \
                || { docker start "$SVC" >/dev/null 2>&1; error "Sauvegarde de $src impossible : essai annulé"; }
            info "Sauvegardé : $src ($(du -h "$DIR/backup-$i.tgz" | cut -f1))"
            i=$((i + 1))
        done < "$DIR/mounts"
        printf 'STATE="en cours"\nOLD_IMAGE=%s\nNEW_IMAGE=%s\nDATE="%s"\n' "$OLD_IMAGE" "$NEW_IMAGE" "$(date '+%Y-%m-%d %H:%M')" > "$STATE_FILE"
        compose_set_image "$DOCKER_COMPOSE_FILE" "$SVC" "$NEW_IMAGE" || error "Image de $SVC non changée dans le compose"
        override_set "$SVC" "$NEW_IMAGE"
        log "Démarrage de $SVC en $NEW_IMAGE…"
        if ! compose_cmd up -d "$SVC"; then
            warn "Démarrage impossible : sudo $0 $SVC --rollback"; exit 1
        fi
        sleep 15
        docker ps --format '{{.Names}} {{.Status}}' | grep -E "^$SVC " || warn "$SVC ne tourne pas : docker logs $SVC"
        after_start "$SVC"
        echo ""
        info "Ça marche : sudo $0 $SVC --keep"
        info "Problème  : sudo $0 $SVC --rollback   (ancienne version et données d'avant l'essai, ~1 min)" ;;
esac
