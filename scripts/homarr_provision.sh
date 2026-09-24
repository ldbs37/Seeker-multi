#!/bin/bash

#######################
# homarr_provision.sh — Préconfiguration du Homarr 1.x partagé (mode Traefik)
#
# Crée pour chaque utilisateur un tableau de bord PRIVÉ « <user> »
# (https://<domaine>/boards/<user>, où renvoie https://<user>.<domaine>/)
# avec une tuile par service installé, réservé à son groupe personnel
# « u-<user> » (groupe Authelia transmis à Homarr à la connexion), dont il est
# aussi la page d'accueil. Idempotent : ne recrée pas ce qui existe
# (tableau de bord, applis) et n'écrase pas les personnalisations.
#
# Passe par l'API REST de Homarr, avec une clé d'API créée UNE fois par
# l'administrateur dans Homarr (voir --set-key).
#
# Usage: homarr_provision.sh --set-key <clé>   # enregistre la clé puis --all
#        homarr_provision.sh <user>            # un utilisateur
#        homarr_provision.sh --all             # tous les utilisateurs
#        homarr_provision.sh --remove <user>   # supprime son tableau + ses applis
#######################

set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log() { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
info() { echo -e "${BLUE}[INFO]${NC} $1"; }
fail() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

for lib in lib_ports lib_traefik lib_services; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || fail "$lib.sh introuvable"
done

[[ $EUID -eq 0 ]] || fail "Ce script doit être exécuté en tant que root"
[ $# -ge 1 ] || fail "Usage: $0 --set-key <clé> | <user> | --all | --remove <user>"
traefik_detect "$ENV_FILE"
[ "$USE_TRAEFIK" = true ] || { info "Mode port direct : Homarr individuel (configure_homarr.sh), rien à faire"; exit 0; }

if [ "$1" = --set-key ]; then
    key="${2:-}"
    [[ "$key" =~ ^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$ ]] || fail "Clé d'API invalide (format attendu : <id>.<jeton>)"
    if grep -q '^HOMARR_API_KEY=' "$ENV_FILE"; then
        sed -i "s|^HOMARR_API_KEY=.*|HOMARR_API_KEY=$key|" "$ENV_FILE"
    else
        echo "HOMARR_API_KEY=$key" >> "$ENV_FILE"
    fi
    chmod 600 "$ENV_FILE"
    log "Clé d'API Homarr enregistrée"
    set -- --all
fi

API_KEY=$(grep '^HOMARR_API_KEY=' "$ENV_FILE" 2>/dev/null | cut -d= -f2-)
if [ -z "$API_KEY" ]; then
    info "Tableaux de bord Homarr non préconfigurés : clé d'API absente."
    info "   Dans Homarr (admin) : créez une clé d'API, puis : sudo $0 --set-key <clé>"
    exit 0
fi

# Homarr est joint directement sur le réseau Docker (pas via Traefik/Authelia)
HOMARR_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' homarr 2>/dev/null | awk '{print $1}')
[ -n "$HOMARR_IP" ] || fail "Conteneur homarr introuvable ou arrêté"
API="http://${HOMARR_IP}:7575/api"

# Code HTTP du dernier appel : fichier (les appels tournent souvent dans un
# sous-shell $(...), où une variable ne remonterait pas)
HTTP_CODE_FILE=$(mktemp); trap 'rm -f "$HTTP_CODE_FILE"' EXIT
http_code() { cat "$HTTP_CODE_FILE" 2>/dev/null; }

# Appel d'API. $1=méthode $2=chemin [$3=corps JSON]. Corps de la réponse sur
# stdout ; code HTTP : http_code.
HTTP_CODE=""
hapi() {
    local out
    out=$(curl -s -m 30 -X "$1" -H "ApiKey: $API_KEY" -H 'Content-Type: application/json' \
        ${3:+--data "$3"} -w '\n%{http_code}' "$API$2") || { HTTP_CODE=000; echo 000 > "$HTTP_CODE_FILE"; return 1; }
    HTTP_CODE=${out##*$'\n'}
    echo "$HTTP_CODE" > "$HTTP_CODE_FILE"
    printf '%s' "${out%$'\n'*}"
    [[ "$HTTP_CODE" == 2* ]]
}

# Homarr prêt ? (démarrage : jusqu'à 90 s)
for _ in $(seq 1 45); do
    hapi GET /boards >/dev/null && break
    [ "$(http_code)" = 401 ] || [ "$(http_code)" = 403 ] && fail "Clé d'API refusée par Homarr (HTTP $(http_code)) : sudo $0 --set-key <clé>"
    sleep 2
done
[[ "$(http_code)" == 2* ]] || fail "API Homarr injoignable (HTTP $(http_code))"

# Champ JSON : id de l'élément dont "name" vaut $2, dans la liste JSON $1
json_find_id() {
    J="$1" N="$2" python3 -c '
import json, os
data = json.loads(os.environ["J"] or "[]")
if isinstance(data, dict):
    data = data.get("items") or data.get("boards") or data.get("apps") or []
for x in data:
    if isinstance(x, dict) and x.get("name") == os.environ["N"]:
        print(x.get("id", "")); break'
}
# Procédure tRPC interne de Homarr (accepte aussi la clé d'API) : droits et
# groupes, absents de l'API REST. $1=GET|POST $2=procédure [$3=entrée JSON].
# Affiche le résultat (JSON) ; code HTTP : http_code.
htrpc() {
    local out url="$API/trpc/$2"
    if [ "$1" = GET ]; then
        [ -n "${3:-}" ] && url="$url?input=$(printf '%s' "{\"json\":$3}" | python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')"
        out=$(curl -s -m 30 -H "ApiKey: $API_KEY" -w '\n%{http_code}' "$url") || { HTTP_CODE=000; echo 000 > "$HTTP_CODE_FILE"; return 1; }
    else
        out=$(curl -s -m 30 -X POST -H "ApiKey: $API_KEY" -H 'Content-Type: application/json' \
            --data "{\"json\":${3:-null}}" -w '\n%{http_code}' "$url") || { HTTP_CODE=000; echo 000 > "$HTTP_CODE_FILE"; return 1; }
    fi
    HTTP_CODE=${out##*$'\n'}
    echo "$HTTP_CODE" > "$HTTP_CODE_FILE"
    J="${out%$'\n'*}" python3 -c '
import json, os
try: d = json.loads(os.environ["J"])
except ValueError: d = {}
r = d.get("result", {}).get("data", {})
print(json.dumps(r.get("json") if isinstance(r, dict) and "json" in r else r))'
    [[ "$HTTP_CODE" == 2* ]]
}

json_get() { J="$1" K="$2" python3 -c 'import json,os; print(json.loads(os.environ["J"]).get(os.environ["K"],""))'; }
json_str() { S="$1" python3 -c 'import json,os; print(json.dumps(os.environ["S"]))'; }

ICON_BASE="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg"
svc_label() {
    case "$1" in
        qbittorrent) echo "qBittorrent" ;; filebrowser) echo "Fichiers" ;;
        sonarr) echo "Sonarr" ;;           radarr) echo "Radarr" ;;
        readarr) echo "Readarr" ;;         bazarr) echo "Bazarr" ;;
        prowlarr) echo "Prowlarr" ;;       seerr) echo "Seerr" ;;
        calibre) echo "Calibre-Web" ;;     *) echo "$1" ;;
    esac
}
svc_icon() { case "$1" in calibre) echo "calibre-web" ;; *) echo "$1" ;; esac; }
app_name() { echo "$(svc_label "$1") ($2)"; }   # applis globales : suffixe utilisateur

provision_user() {
    local user="$1" boards apps board_id s name app_id body added=0
    id "$user" &>/dev/null || { warn "Utilisateur $user inconnu"; return 1; }
    # Lues par service_url (lib_services)
    # shellcheck disable=SC2034
    USERNAME=$user
    # shellcheck disable=SC2034
    USER_ID=$(id -u "$user")

    boards=$(hapi GET /boards) || { warn "Liste des tableaux de bord impossible (HTTP $(http_code))"; return 1; }
    board_id=$(json_find_id "$boards" "$user")
    if [ -z "$board_id" ]; then
        body=$(hapi POST /boards "{\"name\":$(json_str "$user"),\"columnCount\":10,\"isPublic\":false}") \
            || { warn "Création du tableau de bord $user impossible (HTTP $(http_code)) : $body"; return 1; }
        board_id=$(json_get "$body" boardId)
        log "Tableau de bord créé : https://$DOMAIN/boards/$user"
    else
        # Tableaux créés publics par une version précédente
        hapi PATCH "/boards/$board_id/visibility" '{"visibility":"private"}' >/dev/null || true
    fi

    # Groupe personnel u-<user> : droits (modification = personnalisable par
    # l'utilisateur) et page d'accueil = son tableau de bord
    local gname="u-$user" groups gid
    groups=$(htrpc GET group.getAll) || { warn "Groupes Homarr illisibles (HTTP $(http_code))"; return 1; }
    gid=$(json_find_id "$groups" "$gname")
    if [ -z "$gid" ]; then
        gid=$(htrpc POST group.createGroup "{\"name\":$(json_str "$gname")}") \
            || { warn "Création du groupe Homarr $gname impossible (HTTP $(http_code))"; return 1; }
        gid=${gid//\"/}
    fi
    htrpc POST board.saveGroupBoardPermissions \
        "{\"entityId\":$(json_str "$board_id"),\"permissions\":[{\"principalId\":$(json_str "$gid"),\"permission\":\"modify\"}]}" >/dev/null \
        || warn "Droits du tableau de bord $user non appliqués (HTTP $(http_code))"
    htrpc POST group.savePartialSettings \
        "{\"id\":$(json_str "$gid"),\"settings\":{\"homeBoardId\":$(json_str "$board_id"),\"mobileHomeBoardId\":$(json_str "$board_id")}}" >/dev/null \
        || warn "Page d'accueil du groupe $gname non définie (HTTP $(http_code))"

    apps=$(hapi GET /apps) || { warn "Liste des applis impossible (HTTP $(http_code))"; return 1; }
    for s in $USER_SERVICES; do
        [ "$s" = homarr ] && continue
        grep -q "^  ${s}-${user}:" "$DOCKER_COMPOSE_FILE" 2>/dev/null || continue
        name=$(app_name "$s" "$user")
        [ -n "$(json_find_id "$apps" "$name")" ] && continue    # déjà présente
        body=$(hapi POST /apps "{\"name\":$(json_str "$name"),\"description\":null,\"iconUrl\":$(json_str "$ICON_BASE/$(svc_icon "$s").svg"),\"href\":$(json_str "$(service_url "$s")"),\"pingUrl\":\"\"}") \
            || { warn "Appli $name non créée (HTTP $(http_code)) : $body"; continue; }
        app_id=$(json_get "$body" appId)
        body=$(hapi POST /boards/items "{\"boardId\":$(json_str "$board_id"),\"kind\":\"app\",\"options\":{\"appId\":$(json_str "$app_id"),\"openInNewTab\":true,\"showTitle\":true},\"integrationIds\":[]}") \
            || { warn "Tuile $name non ajoutée (HTTP $(http_code)) : $body"; continue; }
        added=$((added + 1))
    done
    log "Homarr ($user) : $added tuile(s) ajoutée(s)"
}

remove_user_board() {
    local user="$1" boards apps board_id s app_id
    boards=$(hapi GET /boards) || return 1
    board_id=$(json_find_id "$boards" "$user")
    [ -n "$board_id" ] && hapi DELETE "/boards/$board_id" >/dev/null && log "Tableau de bord $user supprimé"
    apps=$(hapi GET /apps) || return 1
    for s in $USER_SERVICES; do
        app_id=$(json_find_id "$apps" "$(app_name "$s" "$user")")
        [ -n "$app_id" ] && hapi DELETE "/apps/$app_id" >/dev/null
    done
    local groups gid
    groups=$(htrpc GET group.getAll) || return 0
    gid=$(json_find_id "$groups" "u-$user")
    [ -n "$gid" ] && htrpc POST group.deleteGroup "{\"id\":$(json_str "$gid")}" >/dev/null
    return 0
}

case "$1" in
    --all)
        while IFS=: read -r u _ uid _; do
            [ "$uid" -ge "$SEEDBOX_UID_MIN" ] && [ "$uid" -le "$SEEDBOX_UID_MAX" ] || continue
            [ -d "$INSTALL_DIR/data/users/$u" ] && provision_user "$u"
        done < /etc/passwd ;;
    --remove) remove_user_board "${2:?utilisateur manquant}" ;;
    *) provision_user "$1" ;;
esac
exit 0
