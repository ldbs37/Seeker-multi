#!/bin/bash
#######################
# lib_arr.sh — Chaîne *arr automatique d'un utilisateur (mode Traefik)
#
# - Connexion unique : Sonarr, Radarr, Readarr et Prowlarr en mode
#   « External » (Authelia fait la connexion), sur le réseau privé de
#   l'utilisateur (seedbox_u_<user>) : les autres utilisateurs ne les
#   joignent pas. (L'authentification « Basic », qu'aurait pu ajouter
#   Traefik, est refusée par Radarr 6 et Prowlarr 2.)
# - Sonarr / Radarr / Readarr : dossier racine (/data/tv, /data/movies,
#   /data/books) et qBittorrent comme client de téléchargement (par sa clé
#   d'API : pas de mot de passe).
# - Prowlarr : pousse ses indexeurs vers Sonarr / Radarr / Readarr (clés
#   d'API) ; SON FlareSolverr (flaresolverr-<user>, sur son réseau) comme
#   proxy des indexeurs portant l'étiquette « flaresolverr ».
# - Interface en français (dates au format français, semaine commençant le
#   lundi ; Radarr : titres et résumés des films en français), appliquée
#   seulement tant que l'interface est en anglais (réglage d'origine).
# - Téléchargements en français : formats personnalisés « VF » (FRENCH,
#   TRUEFRENCH, VFF…) et « MULTi » (VF + VO) exigés par tous les profils de
#   qualité (score minimal 1 ; MULTi préféré) ; Radarr : langue des profils
#   « Original » remplacée par « Toutes » (sinon un film étranger en VF serait
#   refusé). Appliqué une fois, à la création des formats : les réglages
#   modifiés ensuite sont conservés.
# Idempotent. Vérifié sur Sonarr 4.0.20, Radarr 6.4.4, Prowlarr 2.6.5 et
# qBittorrent 5.2.3 (binaires officiels).
#
# Variables : INSTALL_DIR. Fonctions de lib_traefik.sh
# (traefik_service_port) et lib_homarr.sh
# (arr_api_key, qbit_ensure_api_key).
#######################

ARR_SERVICES="sonarr radarr readarr prowlarr"

# Version d'API : v3 (Sonarr, Radarr), v1 (Readarr, Prowlarr)
_arr_api_version() { case "$1" in sonarr|radarr) echo v3 ;; *) echo v1 ;; esac; }

# URL de l'API d'un service utilisateur, jointe depuis l'hôte (adresse du
# conteneur sur le réseau Docker). $1=service $2=utilisateur
arr_api_url() {
    local ip
    ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1-$2" 2>/dev/null | awk '{print $1}')
    [ -n "$ip" ] || return 1
    echo "http://$ip:$(traefik_service_port "$1")/$1/api/$(_arr_api_version "$1")"
}

# Appel d'API d'un *arr. $1=service $2=utilisateur $3=méthode $4=chemin
# [$5=corps JSON]. Corps sur stdout ; retour 0 si HTTP 2xx.
arr_api() {
    local base key out code
    base=$(arr_api_url "$1" "$2") || return 1
    key=$(arr_api_key "$1" "$2"); [ -n "$key" ] || return 1
    out=$(curl -s -m 60 -X "$3" -H "X-Api-Key: $key" -H 'Content-Type: application/json' \
        ${5:+--data "$5"} -w '\n%{http_code}' "$base$4") || return 1
    code=${out##*$'\n'}
    printf '%s' "${out%$'\n'*}"
    [[ "$code" == 2* ]]
}

# Service prêt (API joignable avec sa clé) ? ARR_WAIT secondes max (120).
# $1=service $2=user
arr_wait() {
    local i n=$(( ${ARR_WAIT:-120} / 2 ))
    for i in $(seq 1 "$n"); do
        arr_api "$1" "$2" GET /system/status >/dev/null 2>&1 && return 0
        [ "$i" = "$n" ] || sleep 2
    done
    return 1
}

# Service sur le seul réseau privé de l'utilisateur (compose) ? Sinon
# (installation pas encore migrée : generate_traefik_labels.sh), pas de
# connexion « External ». $1=service $2=utilisateur
arr_isolated() {
    awk -v name="  $1-$2:" -v net="      - seedbox_u_$2" '
        $0 == name { inb = 1; next }
        inb && /^  [^ ]/ { inb = 0 }
        inb && $0 == net { mine = 1 }
        inb && /^      - traefik_proxy$/ { shared = 1 }
        END { exit !(mine && !shared) }
    ' "$INSTALL_DIR/docker-compose.yml"
}

# Connexion « External » : aucune page de connexion, Authelia (devant
# Traefik) s'en charge. Sûr parce que le service n'est joignable que par
# Traefik, Homarr et les services de l'utilisateur (réseau seedbox_u_<user>,
# lib_traefik.sh). L'API exige toujours la clé. $1=service $2=utilisateur
arr_external() {
    local svc="$1" user="$2" host
    host=$(arr_api "$svc" "$user" GET /config/host) || return 1
    host=$(H="$host" python3 -c '
import json, os, sys
d = json.loads(os.environ["H"])
if d.get("authenticationMethod") == "external":
    sys.exit(3)
d.update(authenticationMethod="external", authenticationRequired="enabled")
print(json.dumps(d))')
    case $? in 0) ;; 3) return 0 ;; *) return 1 ;; esac
    arr_api "$svc" "$user" PUT /config/host "$host" >/dev/null
}

# Interface en français, tant qu'elle est en anglais (réglage d'origine :
# un autre choix de l'utilisateur est conservé). Langues : identifiant
# (Sonarr, Radarr, Readarr : 2 = français) ou code (Prowlarr : « fr »).
# $1=service $2=utilisateur
arr_french() {
    local svc="$1" user="$2" ui
    ui=$(arr_api "$svc" "$user" GET /config/ui) || return 1
    ui=$(U="$ui" python3 -c '
import json, os, sys
d = json.loads(os.environ["U"])
if d.get("uiLanguage") not in (1, "en"):
    sys.exit(3)
d["uiLanguage"] = "fr" if isinstance(d["uiLanguage"], str) else 2
d.update(firstDayOfWeek=1, calendarWeekColumnHeader="ddd D/M", shortDateFormat="DD/MM/YYYY",
         longDateFormat="dddd, D MMMM YYYY", timeFormat="HH:mm")
if d.get("movieInfoLanguage") == 1:
    d["movieInfoLanguage"] = 2
print(json.dumps(d))')
    case $? in 0) ;; 3) return 0 ;; *) return 1 ;; esac
    arr_api "$svc" "$user" PUT /config/ui "$ui" >/dev/null
}

# Téléchargements en français (voir l'en-tête). $1=sonarr|radarr $2=utilisateur
ARR_FR_FORMATS="VF MULTi"
arr_french_profiles() {
    local svc="$1" user="$2" cfs schema body profiles
    cfs=$(arr_api "$svc" "$user" GET /customformat) || return 1
    # Déjà fait (formats présents) : rien à changer
    C="$cfs" F="$ARR_FR_FORMATS" python3 -c 'import json, os, sys
names = {c["name"] for c in json.loads(os.environ["C"])}
sys.exit(0 if set(os.environ["F"].split()) <= names else 1)' && return 0
    schema=$(arr_api "$svc" "$user" GET /customformat/schema) || return 1
    for name in $ARR_FR_FORMATS; do
        C="$cfs" N="$name" python3 -c 'import json, os, sys
sys.exit(0 if any(c["name"] == os.environ["N"] for c in json.loads(os.environ["C"])) else 1)' && continue
        body=$(SCHEMA="$schema" N="$name" python3 -c '
import json, os
e = os.environ
impl, value, label = (("LanguageSpecification", 2, "Français") if e["N"] == "VF"
                      else ("ReleaseTitleSpecification", r"\bMULTI\b", "MULTi"))
spec = next(s for s in json.loads(e["SCHEMA"]) if s["implementation"] == impl)
for f in spec["fields"]:
    if f["name"] == "value":
        f["value"] = value
spec.update(name=label, negate=False, required=True)
print(json.dumps({"name": e["N"], "includeCustomFormatWhenRenaming": False, "specifications": [spec]}))') || return 1
        arr_api "$svc" "$user" POST /customformat "$body" >/dev/null || return 1
    done
    cfs=$(arr_api "$svc" "$user" GET /customformat) || return 1
    profiles=$(arr_api "$svc" "$user" GET /qualityprofile) || return 1
    C="$cfs" P="$profiles" python3 -c '
import json, os
e = os.environ
ids = {c["name"]: c["id"] for c in json.loads(e["C"])}
scores = {ids["VF"]: 100, ids["MULTi"]: 150}
for p in json.loads(e["P"]):
    items = {f["format"]: f for f in p.get("formatItems", [])}
    for fid, sc in scores.items():
        items.setdefault(fid, {"format": fid, "name": "", "score": 0})["score"] = sc
    p["formatItems"] = list(items.values())
    p["minFormatScore"] = max(p.get("minFormatScore") or 0, 1)
    if (p.get("language") or {}).get("id") == -2:
        p["language"] = {"id": -1, "name": "Any"}
    print(json.dumps(p))' | while IFS= read -r body; do
        arr_api "$svc" "$user" PUT "/qualityprofile/$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" "$body" >/dev/null || exit 1
    done
}

# Dossier racine. $1=service $2=utilisateur
arr_root_folder() {
    local svc="$1" user="$2" path body qp mp
    case "$svc" in
        sonarr) path=/data/tv ;; radarr) path=/data/movies ;; readarr) path=/data/books ;; *) return 0 ;;
    esac
    arr_api "$svc" "$user" GET /rootfolder | P="$path" python3 -c 'import json,os,sys; sys.exit(0 if any(r["path"].rstrip("/")==os.environ["P"] for r in json.load(sys.stdin)) else 1)' && return 0
    if [ "$svc" = readarr ]; then
        # Readarr : profils qualité et métadonnées par défaut obligatoires
        qp=$(arr_api readarr "$user" GET /qualityprofile | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])') || return 1
        mp=$(arr_api readarr "$user" GET /metadataprofile | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])') || return 1
        body="{\"name\":\"Livres\",\"path\":\"$path\",\"defaultQualityProfileId\":$qp,\"defaultMetadataProfileId\":$mp,\"isCalibreLibrary\":false}"
    else
        body="{\"path\":\"$path\"}"
    fi
    arr_api "$svc" "$user" POST /rootfolder "$body" >/dev/null
}

# qBittorrent comme client de téléchargement, par sa clé d'API.
# $1=service $2=utilisateur $3=clé qBittorrent
arr_download_client() {
    local svc="$1" user="$2" qkey="$3" body
    arr_api "$svc" "$user" GET /downloadclient | python3 -c 'import json,sys; sys.exit(0 if any(c["implementation"]=="QBittorrent" for c in json.load(sys.stdin)) else 1)' && return 0
    body=$(arr_api "$svc" "$user" GET /downloadclient/schema | H="qbittorrent-$user" K="$qkey" python3 -c '
import json, os, sys
s = next(x for x in json.load(sys.stdin) if x["implementation"] == "QBittorrent")
names = {f["name"] for f in s["fields"]}
if "apiKey" not in names:
    sys.exit(4)   # version sans clé d API : à configurer à la main
for f in s["fields"]:
    if f["name"] == "host": f["value"] = os.environ["H"]
    elif f["name"] == "port": f["value"] = 8080
    elif f["name"] == "useSsl": f["value"] = False
    elif f["name"] == "urlBase": f["value"] = ""
    elif f["name"] == "apiKey": f["value"] = os.environ["K"]
s.update(name="qBittorrent", enable=True, priority=1, removeCompletedDownloads=True, removeFailedDownloads=True)
s.pop("id", None)
print(json.dumps(s))')
    case $? in
        0) ;;
        4) echo "$svc : qBittorrent sans clé d'API dans cette version, client à ajouter à la main" >&2; return 0 ;;
        *) return 1 ;;
    esac
    arr_api "$svc" "$user" POST /downloadclient "$body" >/dev/null
}

# Prowlarr → application ($3 = sonarr|radarr|readarr), par clés d'API
prowlarr_application() {
    local user="$1" app="$2" name key body
    case "$app" in sonarr) name=Sonarr ;; radarr) name=Radarr ;; readarr) name=Readarr ;; *) return 1 ;; esac
    arr_api prowlarr "$user" GET /applications | N="$name" python3 -c 'import json,os,sys; sys.exit(0 if any(a["implementation"]==os.environ["N"] for a in json.load(sys.stdin)) else 1)' && return 0
    key=$(arr_api_key "$app" "$user"); [ -n "$key" ] || return 1
    body=$(arr_api prowlarr "$user" GET /applications/schema | N="$name" \
        PU="http://prowlarr-$user:9696/prowlarr" AU="http://$app-$user:$(traefik_service_port "$app")/$app" K="$key" python3 -c '
import json, os, sys
s = next(x for x in json.load(sys.stdin) if x["implementation"] == os.environ["N"])
for f in s["fields"]:
    if f["name"] == "prowlarrUrl": f["value"] = os.environ["PU"]
    elif f["name"] == "baseUrl": f["value"] = os.environ["AU"]
    elif f["name"] == "apiKey": f["value"] = os.environ["K"]
s.update(name=os.environ["N"], syncLevel="fullSync")
s.pop("id", None)
print(json.dumps(s))') || return 1
    arr_api prowlarr "$user" POST /applications "$body" >/dev/null
}

# Prowlarr → FlareSolverr (proxy des indexeurs étiquetés « flaresolverr »)
prowlarr_flaresolverr() {
    local user="$1" tag body
    grep -q "^  flaresolverr-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null || return 0
    arr_api prowlarr "$user" GET /indexerproxy | python3 -c 'import json,sys; sys.exit(0 if any(p["implementation"]=="FlareSolverr" for p in json.load(sys.stdin)) else 1)' && return 0
    tag=$(arr_api prowlarr "$user" GET /tag | python3 -c 'import json,sys; print(next((t["id"] for t in json.load(sys.stdin) if t["label"]=="flaresolverr"), ""))')
    [ -n "$tag" ] || tag=$(arr_api prowlarr "$user" POST /tag '{"label":"flaresolverr"}' | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || return 1
    body=$(arr_api prowlarr "$user" GET /indexerproxy/schema | T="$tag" FS="http://flaresolverr-$user:8191/" python3 -c '
import json, os, sys
s = next(x for x in json.load(sys.stdin) if x["implementation"] == "FlareSolverr")
for f in s["fields"]:
    if f["name"] == "host": f["value"] = os.environ["FS"]
s.update(name="FlareSolverr", tags=[int(os.environ["T"])])
s.pop("id", None)
print(json.dumps(s))') || return 1
    # Prowlarr teste FlareSolverr avant d'enregistrer : il vient peut-être
    # de démarrer (60 s max)
    local i
    for i in $(seq 1 12); do
        arr_api prowlarr "$user" POST /indexerproxy "$body" >/dev/null && return 0
        [ "$i" = 12 ] || sleep 5
    done
    return 1
}

# Toute la chaîne d'un utilisateur (services présents seulement).
# $1=utilisateur. Retour 0 si tout est appliqué.
arr_chain() {
    local user="$1" svc qkey rc=0 have=()
    for svc in $ARR_SERVICES; do
        grep -q "^  $svc-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null && have+=("$svc")
    done
    [ ${#have[@]} -gt 0 ] || return 0
    for svc in "${have[@]}"; do
        arr_wait "$svc" "$user" || { echo "$svc-$user ne répond pas" >&2; rc=1; continue; }
        if ! arr_isolated "$svc" "$user"; then
            echo "$svc-$user : hors du réseau privé de $user, connexion unique non appliquée (lancez generate_traefik_labels.sh)" >&2; rc=1
        else
            arr_external "$svc" "$user" || { echo "$svc-$user : connexion unique non appliquée" >&2; rc=1; }
        fi
        arr_french "$svc" "$user" || { echo "$svc-$user : interface en français non appliquée" >&2; rc=1; }
    done
    qkey=""
    grep -q "^  qbittorrent-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null && qkey=$(qbit_ensure_api_key "$user")
    for svc in sonarr radarr readarr; do
        [[ " ${have[*]} " == *" $svc "* ]] || continue
        arr_root_folder "$svc" "$user" || { echo "$svc-$user : dossier racine non créé" >&2; rc=1; }
        if [ "$svc" != readarr ]; then
            arr_french_profiles "$svc" "$user" || { echo "$svc-$user : profils en français non appliqués" >&2; rc=1; }
        fi
        if [ -n "$qkey" ]; then
            arr_download_client "$svc" "$user" "$qkey" || { echo "$svc-$user : client qBittorrent non ajouté" >&2; rc=1; }
        fi
    done
    if [[ " ${have[*]} " == *" prowlarr "* ]]; then
        for svc in sonarr radarr readarr; do
            [[ " ${have[*]} " == *" $svc "* ]] || continue
            prowlarr_application "$user" "$svc" || { echo "prowlarr-$user → $svc non relié" >&2; rc=1; }
        done
        prowlarr_flaresolverr "$user" || { echo "prowlarr-$user : FlareSolverr non ajouté" >&2; rc=1; }
    fi
    return $rc
}
