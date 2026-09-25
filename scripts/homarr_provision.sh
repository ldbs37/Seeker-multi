#!/bin/bash

#######################
# homarr_provision.sh — Préconfiguration du Homarr 1.x partagé (mode Traefik)
#
# Pour chaque utilisateur, un tableau de bord PRIVÉ « <user> »
# (https://<domaine>/boards/<user>, où renvoie https://<user>.<domaine>/),
# réservé à son groupe personnel « u-<user> » (groupe Authelia transmis à
# Homarr à la connexion), dont il est aussi la page d'accueil :
#   - date/heure, météo ;
#   - une tuile par service installé (+ Jellyfin), avec voyant d'état ;
#   - téléchargements qBittorrent, calendrier Sonarr/Radarr/Readarr,
#     demandes Seerr : intégrations créées et branchées automatiquement
#     (clés d'API lues dans la configuration des services).
# Pour les administrateurs, un tableau « admin-serveur » : charge CPU/RAM/
# réseau et disques (Dash.), lectures en cours et derniers ajouts Jellyfin,
# tuiles des services système ; lien depuis leur tableau personnel.
#
# Idempotent : ne recrée pas ce qui existe, ne déplace rien après la première
# mise en page et ne remet pas un widget supprimé par l'utilisateur.
# Passe par l'API de Homarr avec la clé créée par homarr_bootstrap.
#
# Usage: homarr_provision.sh --set-key <clé>   # enregistre la clé puis --all
#        homarr_provision.sh <user>            # un utilisateur (+ tableau admin)
#        homarr_provision.sh --all             # tous les utilisateurs
#        homarr_provision.sh --remove <user>   # supprime son tableau, ses applis…
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
USERS_DB="$INSTALL_DIR/authelia/users_database.yml"
STATE_DIR="$INSTALL_DIR/homarr/provision"     # clés des widgets déjà ajoutés, par tableau
ADMIN_BOARD="admin-serveur"                     # « - » : pas de conflit avec un nom d'utilisateur

for lib in lib_ports lib_traefik lib_services lib_qbittorrent lib_homarr lib_password; do
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
DASHDOT_ICON="https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/dashdot.png"
svc_label() {
    case "$1" in
        qbittorrent) echo "qBittorrent" ;; filebrowser) echo "Fichiers" ;;
        sonarr) echo "Sonarr" ;;           radarr) echo "Radarr" ;;
        readarr) echo "Readarr" ;;         bazarr) echo "Bazarr" ;;
        prowlarr) echo "Prowlarr" ;;       seerr) echo "Seerr" ;;
        calibre) echo "Calibre-Web" ;;     *) echo "$1" ;;
    esac
}
svc_icon() { case "$1" in calibre) echo "calibre-web" ;; filebrowser) echo "filebrowser-quantum" ;; *) echo "$1" ;; esac; }
app_name() { echo "$(svc_label "$1") ($2)"; }   # applis globales : suffixe utilisateur

# Services système : libellé|icône|sous-domaine|port interne
sys_app() {
    case "$1" in
        authelia)    echo "Authelia|authelia|auth|9091" ;;
        portainer)   echo "Portainer|portainer|portainer|9000" ;;
        jellyfin)    echo "Jellyfin|jellyfin|jellyfin|8096" ;;
        plex)        echo "Plex|plex|plex|32400" ;;
        tautulli)    echo "Tautulli|tautulli|tautulli|8181" ;;
        dashdot)     echo "Dash.|$DASHDOT_ICON|dashdot|3001" ;;
        scrutiny)    echo "Scrutiny|scrutiny|scrutiny|8080" ;;
        uptime-kuma) echo "Uptime Kuma|uptime-kuma|uptime|3001" ;;
        duplicati)   echo "Duplicati|duplicati|duplicati|8200" ;;
        *) return 1 ;;
    esac
}
has_service() { grep -q "^  $1:" "$DOCKER_COMPOSE_FILE" 2>/dev/null; }

# URL interne (réseau Docker) d'un service utilisateur : voyant d'état des
# tuiles et intégrations (Homarr joint le conteneur sans passer par Authelia)
internal_url() {
    local path=""
    # qBittorrent : préfixe /qbittorrent retiré par Traefik (stripprefix)
    [ "$1" = qbittorrent ] || path=$(service_url "$1" | sed -E 's|^https?://[^/]+||; s|/$||')
    echo "http://$1-$2:$(traefik_service_port "$1")$path"
}

# URL de test du voyant d'état d'une tuile : point de santé sans redirection
# quand le service en a un (FileBrowser Quantum : /files → /files/, que le
# test de Homarr signale en « fetch failed »)
ping_url() {
    case "$1" in
        filebrowser) echo "$(internal_url "$1" "$2")/health" ;;
        *) internal_url "$1" "$2" ;;
    esac
}

# Corps JSON d'une appli. $1=nom $2=icône $3=lien $4=URL de test
app_json() {
    A_N="$1" A_I="$2" A_H="$3" A_P="$4" python3 -c '
import json, os
print(json.dumps({"name": os.environ["A_N"], "description": None, "iconUrl": os.environ["A_I"],
                  "href": os.environ["A_H"], "pingUrl": os.environ["A_P"]}))'
}

# Appli Homarr (globale) : créée si absente ; mise à jour si son URL de test
# a changé (voyant d'état absent des versions précédentes, port modifié…). $1=nom $2=icône (nom ou URL) $3=lien
# $4=URL de test. Affiche son id.
ensure_app() {
    local name="$1" icon="$2" href="$3" ping="$4" found body apps
    [[ "$icon" == http* ]] || icon="$ICON_BASE/$icon.svg"
    # Liste relue à chaque appel (souvent appelée dans un sous-shell $(...))
    apps=$(hapi GET /apps) || { warn "Liste des applis impossible (HTTP $(http_code))" >&2; return 1; }
    found=$(J="$apps" N="$name" P="$ping" python3 -c '
import json, os
for a in json.loads(os.environ["J"] or "[]"):
    if a.get("name") == os.environ["N"]:
        print(a["id"], 1 if (a.get("pingUrl") or "") == os.environ["P"] else 0); break')
    if [ -n "$found" ]; then
        if [ "${found#* }" = 0 ] && [ -n "$ping" ]; then
            hapi PATCH "/apps/${found% *}" "$(app_json "$name" "$icon" "$href" "$ping")" >/dev/null || true
        fi
        echo "${found% *}"; return 0
    fi
    body=$(hapi POST /apps "$(app_json "$name" "$icon" "$href" "$ping")") \
        || { warn "Appli $name non créée (HTTP $(http_code)) : $body" >&2; return 1; }
    json_get "$body" appId
}

# Intégration Homarr (connexion à un service, pour les widgets) : créée si
# absente — Homarr teste d'abord la connexion. $1=nom $2=type $3=URL
# $4=secrets (JSON) [$5=id de l'appli liée : liens des widgets vers l'URL
# publique]. Affiche son id.
ensure_integration() {
    local name="$1" kind="$2" url="$3" secrets="$4" app="${5:-}" all id res
    all=$(htrpc GET integration.all) || { warn "Intégrations illisibles (HTTP $(http_code))" >&2; return 1; }
    id=$(json_find_id "$all" "$name")
    [ -n "$id" ] && { echo "$id"; return 0; }
    res=$(htrpc POST integration.create "$(I_N="$name" I_K="$kind" I_U="$url" I_S="$secrets" I_A="$app" python3 -c '
import json, os
d = {"name": os.environ["I_N"], "kind": os.environ["I_K"], "url": os.environ["I_U"],
     "secrets": json.loads(os.environ["I_S"]), "attemptSearchEngineCreation": False}
if os.environ["I_A"]: d["app"] = {"id": os.environ["I_A"]}
print(json.dumps(d))')") || { warn "Intégration $name non créée (HTTP $(http_code)) : $res" >&2; return 1; }
    # Succès : pas de résultat ; échec du test de connexion : {"error": …}
    if [ -n "$res" ] && [ "$res" != null ] && [ "$res" != "{}" ]; then
        warn "Intégration $name non créée (test de connexion : $res) — relancez plus tard : sudo $0 --all" >&2
        return 1
    fi
    all=$(htrpc GET integration.all) || return 1
    id=$(json_find_id "$all" "$name")
    [ -n "$id" ] && log "Intégration créée : $name" >&2
    echo "$id"
}

# Droit d'utilisation d'une intégration pour un groupe ($1=intégration $2=groupe)
grant_integration() {
    htrpc POST integration.saveGroupIntegrationPermissions \
        "{\"entityId\":$(json_str "$1"),\"permissions\":[{\"principalId\":$(json_str "$2"),\"permission\":\"use\"}]}" >/dev/null \
        || warn "Droits sur l'intégration non appliqués (HTTP $(http_code))"
}

# Groupe Homarr (créé si absent). Affiche son id.
ensure_group() {
    local groups gid
    groups=$(htrpc GET group.getAll) || { warn "Groupes Homarr illisibles (HTTP $(http_code))" >&2; return 1; }
    gid=$(json_find_id "$groups" "$1")
    if [ -z "$gid" ]; then
        gid=$(htrpc POST group.createGroup "{\"name\":$(json_str "$1")}") \
            || { warn "Création du groupe Homarr $1 impossible (HTTP $(http_code))" >&2; return 1; }
        gid=${gid//\"/}
    fi
    echo "$gid"
}

# Tableau de bord privé (créé si absent), modifiable par le groupe $2.
# Affiche son id.
ensure_board() {
    local name="$1" gid="$2" boards id body
    boards=$(hapi GET /boards) || { warn "Liste des tableaux de bord impossible (HTTP $(http_code))" >&2; return 1; }
    id=$(json_find_id "$boards" "$name")
    if [ -z "$id" ]; then
        body=$(hapi POST /boards "{\"name\":$(json_str "$name"),\"columnCount\":10,\"isPublic\":false}") \
            || { warn "Création du tableau de bord $name impossible (HTTP $(http_code)) : $body" >&2; return 1; }
        id=$(json_get "$body" boardId)
        log "Tableau de bord créé : https://$DOMAIN/boards/$name" >&2
    else
        # Tableaux créés publics par une version précédente
        hapi PATCH "/boards/$id/visibility" '{"visibility":"private"}' >/dev/null || true
    fi
    htrpc POST board.saveGroupBoardPermissions \
        "{\"entityId\":$(json_str "$id"),\"permissions\":[{\"principalId\":$(json_str "$gid"),\"permission\":\"modify\"}]}" >/dev/null \
        || warn "Droits du tableau de bord $name non appliqués (HTTP $(http_code))" >&2
    echo "$id"
}

# Éléments voulus d'un tableau, dans l'ordre de mise en page : une ligne JSON
# par élément dans le fichier $SPECS. $1=clé $2=type $3=largeur $4=hauteur
# $5=options (JSON) [$6=intégrations (liste JSON) $7=titre]
SPECS=""
spec() {
    S_K="$1" S_T="$2" S_W="$3" S_H="$4" S_O="$5" S_I="${6:-[]}" S_L="${7:-}" python3 -c '
import json, os
print(json.dumps({"key": os.environ["S_K"], "kind": os.environ["S_T"], "w": int(os.environ["S_W"]),
    "h": int(os.environ["S_H"]), "options": json.loads(os.environ["S_O"]),
    "integrationIds": json.loads(os.environ["S_I"]), "title": os.environ["S_L"] or None}))' >> "$SPECS"
}
app_spec() { spec "app:$1" app 1 1 "{\"appId\":$(json_str "$1"),\"openInNewTab\":true,\"showTitle\":true,\"pingEnabled\":true}"; }
ids_json() { python3 -c 'import json,sys; print(json.dumps([a for a in sys.argv[1:] if a]))' "$@"; }
specs_new() { SPECS=$(mktemp); }
specs_done() { rm -f "${SPECS:?}" "${SPECS:?}.board" "${SPECS:?}.list"; }

# Met en page le tableau $1 (id $2) avec les éléments de $SPECS
# (homarr_layout.py ; état : $STATE_DIR/<tableau>.keys)
apply_layout() {
    local name="$1" board state="$STATE_DIR/$1.keys" out save added n
    mkdir -p "$STATE_DIR"
    board=$(htrpc GET board.getBoardByName "{\"name\":$(json_str "$name")}") \
        || { warn "Tableau de bord $name illisible (HTTP $(http_code))"; return 1; }
    # Première mise en page : disposition « Mobile » (4 colonnes) en plus du
    # bureau (10 colonnes, à partir de 800 px) ; Homarr la déduit du bureau
    if [ ! -f "$state" ] && [ "$(J="$board" python3 -c 'import json,os; print(len(json.loads(os.environ["J"])["layouts"]))')" = 1 ]; then
        htrpc POST board.saveLayouts "$(J="$board" python3 -c '
import json, os
b = json.loads(os.environ["J"]); base = b["layouts"][0]
print(json.dumps({"id": b["id"], "layouts": [
    {"id": base["id"], "name": "Bureau", "columnCount": base["columnCount"], "breakpoint": 800},
    {"id": "mobile", "name": "Mobile", "columnCount": 4, "breakpoint": 0}]}))')" >/dev/null \
            && board=$(htrpc GET board.getBoardByName "{\"name\":$(json_str "$name")}")
    fi
    printf '%s' "$board" > "$SPECS.board"
    python3 -c 'import json,sys; print(json.dumps([json.loads(l) for l in open(sys.argv[1]) if l.strip()]))' "$SPECS" > "$SPECS.list"
    out=$(python3 "$SCRIPT_DIR/homarr_layout.py" "$SPECS.board" "$SPECS.list" "$state") \
        || { warn "Mise en page de $name impossible"; return 1; }
    save=$(J="$out" python3 -c 'import json,os; print(json.dumps(json.loads(os.environ["J"])["save"]))')
    if [ "$save" = null ]; then
        log "Homarr ($name) : à jour"; return 0
    fi
    htrpc POST board.saveBoard "$save" >/dev/null \
        || { warn "Enregistrement du tableau $name impossible (HTTP $(http_code))"; return 1; }
    added=$(J="$out" python3 -c 'import json,os; print("\n".join(json.loads(os.environ["J"])["added"]))')
    [ -n "$added" ] && printf '%s\n' "$added" >> "$state"
    : >> "$state"
    n=$(printf '%s' "$added" | grep -c . || true)
    log "Homarr ($name) : $n élément(s) ajouté(s) — https://$DOMAIN/boards/$name"
}

# Moteur de recherche web par défaut (barre de recherche de Homarr) s'il n'y
# en a aucun
ensure_search_engine() {
    local list id
    list=$(htrpc GET searchEngine.getPaginated '{"page":1,"pageSize":50}') || return 0
    [ "$(J="$list" python3 -c 'import json,os; print(json.loads(os.environ["J"]).get("totalCount",0))' 2>/dev/null)" = 0 ] || return 0
    htrpc POST searchEngine.create "{\"type\":\"generic\",\"name\":\"DuckDuckGo\",\"short\":\"d\",\"iconUrl\":\"$ICON_BASE/duckduckgo.svg\",\"urlTemplate\":\"https://duckduckgo.com/?q=%s\",\"description\":null}" >/dev/null || return 0
    list=$(htrpc GET searchEngine.getPaginated '{"page":1,"pageSize":50}') || return 0
    id=$(J="$list" python3 -c 'import json,os; print(json.loads(os.environ["J"])["items"][0]["id"])' 2>/dev/null)
    [ -n "$id" ] && htrpc POST serverSettings.saveSettings "{\"settingsKey\":\"search\",\"value\":{\"defaultSearchEngineId\":$(json_str "$id")}}" >/dev/null
    log "Barre de recherche : DuckDuckGo par défaut"
    return 0
}

# Options des widgets
CLOCK_OPTS='{"is24HourFormat":true,"showDate":true,"dateFormat":"dddd, D MMMM"}'
WEATHER_OPTS='{"location":{"name":"Paris","latitude":48.85341,"longitude":2.3488},"showCity":true,"hasForecast":true,"forecastDayCount":5,"dateFormat":"dddd, D MMMM","disableTemperatureDecimals":true}'
DOWNLOADS_OPTS='{"columns":["name","progress","size","downSpeed","upSpeed","time","state"],"defaultSort":"progress"}'

# Intégrations d'un utilisateur ($1), utilisables par son groupe ($2) :
# INT_QBIT, INT_CAL (Sonarr/Radarr/Readarr), INT_SEERR
user_integrations() {
    local user="$1" gid="$2" key id s app
    INT_QBIT=""; INT_CAL=(); INT_SEERR=""
    if has_service "qbittorrent-$user" && key=$(qbit_ensure_api_key "$user") && [ -n "$key" ]; then
        app=$(ensure_app "$(app_name qbittorrent "$user")" qbittorrent "$(service_url qbittorrent)" "$(internal_url qbittorrent "$user")")
        id=$(ensure_integration "qBittorrent ($user)" qBittorrent "$(internal_url qbittorrent "$user")" \
            "[{\"kind\":\"apiKey\",\"value\":\"$key\"}]" "$app")
        [ -n "$id" ] && { grant_integration "$id" "$gid"; INT_QBIT=$id; }
    fi
    for s in sonarr radarr readarr; do
        has_service "$s-$user" || continue
        key=$(arr_api_key "$s" "$user"); [ -n "$key" ] || continue
        app=$(ensure_app "$(app_name "$s" "$user")" "$(svc_icon "$s")" "$(service_url "$s")" "$(internal_url "$s" "$user")")
        id=$(ensure_integration "$(svc_label "$s") ($user)" "$s" "$(internal_url "$s" "$user")" \
            "[{\"kind\":\"apiKey\",\"value\":\"$key\"}]" "$app")
        [ -n "$id" ] && { grant_integration "$id" "$gid"; INT_CAL+=("$id"); }
    done
    if has_service "seerr-$user" && key=$(seerr_api_key "$user") && [ -n "$key" ]; then
        app=$(ensure_app "$(app_name seerr "$user")" seerr "$(service_url seerr)" "$(internal_url seerr "$user")")
        id=$(ensure_integration "Seerr ($user)" seerr "$(internal_url seerr "$user")" \
            "[{\"kind\":\"apiKey\",\"value\":\"$key\"}]" "$app")
        [ -n "$id" ] && { grant_integration "$id" "$gid"; INT_SEERR=$id; }
    fi
    return 0
}

# Tableau personnel : horloge, météo, statistiques des demandes, tuiles,
# téléchargements, prochaines sorties, demandes
provision_user() {
    local user="$1" board_id gid s id
    id "$user" &>/dev/null || { warn "Utilisateur $user inconnu"; return 1; }
    # Lues par service_url (lib_services)
    # shellcheck disable=SC2034
    USERNAME=$user
    # shellcheck disable=SC2034
    USER_ID=$(id -u "$user")

    gid=$(ensure_group "u-$user") || return 1
    board_id=$(ensure_board "$user" "$gid") || return 1
    # Page d'accueil du groupe = son tableau de bord
    htrpc POST group.savePartialSettings \
        "{\"id\":$(json_str "$gid"),\"settings\":{\"homeBoardId\":$(json_str "$board_id"),\"mobileHomeBoardId\":$(json_str "$board_id")}}" >/dev/null \
        || warn "Page d'accueil du groupe u-$user non définie (HTTP $(http_code))"

    user_integrations "$user" "$gid"

    specs_new
    spec clock clock 2 2 "$CLOCK_OPTS"
    spec weather weather 3 2 "$WEATHER_OPTS"
    [ -n "$INT_SEERR" ] && spec seerr-stats mediaRequests-requestStats 5 2 '{}' "$(ids_json "$INT_SEERR")"
    for s in $USER_SERVICES; do
        [ "$s" = homarr ] && continue
        has_service "$s-$user" || continue
        id=$(ensure_app "$(app_name "$s" "$user")" "$(svc_icon "$s")" "$(service_url "$s")" "$(ping_url "$s" "$user")") \
            && app_spec "$id"
    done
    if has_service jellyfin; then
        id=$(ensure_app Jellyfin jellyfin "https://jellyfin.$DOMAIN" "http://jellyfin:8096/health") && app_spec "$id"
    fi
    if password_user_is_admin "$user" "$USERS_DB"; then
        id=$(ensure_app "Serveur (admin)" homarr "https://$DOMAIN/boards/$ADMIN_BOARD" "") && app_spec "$id"
    fi
    [ -n "$INT_QBIT" ] && spec downloads downloads 6 4 "$DOWNLOADS_OPTS" "$(ids_json "$INT_QBIT")" "Téléchargements"
    [ ${#INT_CAL[@]} -gt 0 ] && spec calendar calendar 4 4 '{"releaseType":["inCinemas","digitalRelease","physicalRelease"]}' \
        "$(ids_json "${INT_CAL[@]}")" "Prochaines sorties"
    [ -n "$INT_SEERR" ] && spec seerr-list mediaRequests-requestList 6 4 '{"linksTargetNewTab":true}' \
        "$(ids_json "$INT_SEERR")" "Demandes"
    apply_layout "$user"
    specs_done
}

# Tableau « admin-serveur » (groupe admins) : état du serveur, Jellyfin,
# services système
provision_admin_board() {
    local gid s def label icon sub port id key app int_dash="" int_jf=""
    gid=$(ensure_group admins) || return 1
    ensure_board "$ADMIN_BOARD" "$gid" >/dev/null || return 1

    if has_service jellyfin && key=$(jellyfin_ensure_api_key) && [ -n "$key" ]; then
        app=$(ensure_app Jellyfin jellyfin "https://jellyfin.$DOMAIN" "http://jellyfin:8096/health")
        int_jf=$(ensure_integration Jellyfin jellyfin "http://jellyfin:8096" "[{\"kind\":\"apiKey\",\"value\":\"$key\"}]" "$app")
    fi
    if has_service dashdot; then
        app=$(ensure_app "Dash." "$DASHDOT_ICON" "https://dashdot.$DOMAIN" "http://dashdot:3001")
        int_dash=$(ensure_integration "Dash." dashDot "http://dashdot:3001" "[]" "$app")
    else
        info "Charge CPU/RAM/disques du tableau admin : sudo $INSTALL_DIR/scripts/add_service.sh dashdot"
    fi

    specs_new
    if [ -n "$int_dash" ]; then
        spec sys-resources systemResources 6 3 '{"visibleCharts":["cpu","memory","network"]}' "$(ids_json "$int_dash")" "Serveur"
        spec sys-health healthMonitoring 4 3 '{"cpu":true,"memory":true,"fileSystem":true}' "$(ids_json "$int_dash")" "Santé"
    fi
    for s in authelia portainer jellyfin plex tautulli dashdot scrutiny uptime-kuma duplicati; do
        has_service "$s" || continue
        def=$(sys_app "$s")
        IFS='|' read -r label icon sub port <<< "$def"
        [ "$s" = jellyfin ] && port="8096/health"
        id=$(ensure_app "$label" "$icon" "https://$sub.$DOMAIN" "http://$s:$port") && app_spec "$id"
    done
    if [ -n "$int_jf" ]; then
        spec jf-sessions mediaServer 6 4 '{"showOnlyPlaying":true}' "$(ids_json "$int_jf")" "En cours de lecture"
        spec jf-releases mediaReleases 4 4 '{"layout":"poster"}' "$(ids_json "$int_jf")" "Derniers ajouts"
    fi
    [ -n "$int_dash" ] && spec sys-disks systemDisks 6 3 '{}' "$(ids_json "$int_dash")" "Disques"
    apply_layout "$ADMIN_BOARD"
    specs_done
}

remove_user_board() {
    local user="$1" boards apps all board_id s id groups gid
    boards=$(hapi GET /boards) || return 1
    board_id=$(json_find_id "$boards" "$user")
    [ -n "$board_id" ] && hapi DELETE "/boards/$board_id" >/dev/null && log "Tableau de bord $user supprimé"
    rm -f "${STATE_DIR:?}/${user:?}.keys"
    apps=$(hapi GET /apps) || return 1
    all=$(htrpc GET integration.all) || all="[]"
    for s in $USER_SERVICES; do
        id=$(json_find_id "$apps" "$(app_name "$s" "$user")")
        [ -n "$id" ] && hapi DELETE "/apps/$id" >/dev/null
        id=$(json_find_id "$all" "$(svc_label "$s") ($user)")
        [ -n "$id" ] && htrpc POST integration.delete "{\"id\":$(json_str "$id")}" >/dev/null
    done
    groups=$(htrpc GET group.getAll) || return 0
    gid=$(json_find_id "$groups" "u-$user")
    [ -n "$gid" ] && htrpc POST group.deleteGroup "{\"id\":$(json_str "$gid")}" >/dev/null
    return 0
}

case "$1" in
    --all)
        ensure_search_engine
        provision_admin_board
        while IFS=: read -r u _ uid _; do
            [ "$uid" -ge "$SEEDBOX_UID_MIN" ] && [ "$uid" -le "$SEEDBOX_UID_MAX" ] || continue
            [ -d "$INSTALL_DIR/data/users/$u" ] && provision_user "$u"
        done < /etc/passwd ;;
    --remove) remove_user_board "${2:?utilisateur manquant}" ;;
    *)
        ensure_search_engine
        provision_admin_board
        provision_user "$1" ;;
esac
exit 0
