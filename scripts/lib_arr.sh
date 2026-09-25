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
# - Téléchargements en français : Radarr, langue des profils « Original »
#   → « French » ; Sonarr (profils sans langue), format personnalisé « VF »
#   (langue française) exigé par les profils, ajouté une fois. Les MULTi sont
#   reconnues comme françaises si l'indexeur l'indique (Multi Languages).
#   Réglages modifiés ensuite conservés.
# - Nommage pour Jellyfin : renommage activé, identifiant dans le dossier et
#   le fichier ([tmdbid-…] pour Radarr, [tvdbid-…] pour Sonarr : Jellyfin
#   reconnaît le média sans deviner). Appliqué une fois (tant que le
#   renommage est désactivé, réglage d'origine), films et séries déjà
#   présents compris (renommés et déplacés ; fichiers liés à qBittorrent :
#   le partage continue).
# - Profil « Seedbox optimisé » (créé une fois, attribué aux médias déjà
#   présents et utilisé par Seerr) : 720p minimum, 1080p, 4K ; au plus 4 Go
#   par film (Radarr) ou 2 Go par heure d'épisode (Sonarr : taille rapportée
#   à l'épisode, packs de saison compris) : une 4K n'est prise que
#   « légère » ; bonus (ARR_BONUS : HEVC, AV1, 10 bits, HDR, EAC3, Atmos,
#   IMAX, 5.1 / 7.1, VFF ; malus VFQ ; 3D et upscale refusés), taille
#   préférée réduite
#   (meilleur rapport qualité / place) ; mises à niveau jusqu'à la 4K.
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
arr_french_profiles() {
    local svc="$1" user="$2" cfs schema body profiles
    profiles=$(arr_api "$svc" "$user" GET /qualityprofile) || return 1
    if [ "$svc" = radarr ]; then
        # Langue des profils : « Original » → « French »
        P="$profiles" python3 -c '
import json, os
for p in json.loads(os.environ["P"]):
    if (p.get("language") or {}).get("id") == -2:
        p["language"] = {"id": 2, "name": "French"}
        print(json.dumps(p))' | _arr_put_profiles "$svc" "$user"
        return
    fi
    # Sonarr (profils sans langue) : format personnalisé « VF » exigé,
    # appliqué à sa création
    cfs=$(arr_api "$svc" "$user" GET /customformat) || return 1
    C="$cfs" python3 -c 'import json, os, sys
sys.exit(0 if any(c["name"] == "VF" for c in json.loads(os.environ["C"])) else 1)' && return 0
    schema=$(arr_api "$svc" "$user" GET /customformat/schema) || return 1
    body=$(SCHEMA="$schema" python3 -c '
import json, os
spec = next(s for s in json.loads(os.environ["SCHEMA"]) if s["implementation"] == "LanguageSpecification")
for f in spec["fields"]:
    if f["name"] == "value":
        f["value"] = 2
spec.update(name="Français", negate=False, required=True)
print(json.dumps({"name": "VF", "includeCustomFormatWhenRenaming": False, "specifications": [spec]}))') || return 1
    body=$(arr_api "$svc" "$user" POST /customformat "$body") || return 1
    profiles=$(arr_api "$svc" "$user" GET /qualityprofile) || return 1
    CF="$body" P="$profiles" python3 -c '
import json, os
fid = json.loads(os.environ["CF"])["id"]
for p in json.loads(os.environ["P"]):
    items = {f["format"]: f for f in p.get("formatItems", [])}
    items.setdefault(fid, {"format": fid, "name": "VF", "score": 0})["score"] = 100
    p["formatItems"] = list(items.values())
    p["minFormatScore"] = max(p.get("minFormatScore") or 0, 1)
    print(json.dumps(p))' | _arr_put_profiles "$svc" "$user"
}

# Profils de qualité (un JSON par ligne sur stdin) enregistrés. $1=service $2=utilisateur
_arr_put_profiles() {
    local body
    while IFS= read -r body; do
        arr_api "$1" "$2" PUT "/qualityprofile/$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" "$body" >/dev/null || return 1
    done
}

# Commande d'un *arr, attendue (5 min au plus). $1=service $2=utilisateur $3=corps JSON
_arr_command() {
    local id st
    id=$(arr_api "$1" "$2" POST /command "$3" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || return 1
    for _ in $(seq 1 150); do
        st=$(arr_api "$1" "$2" GET "/command/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])') || return 1
        case "$st" in completed) return 0 ;; failed|aborted|cancelled|orphaned) return 1 ;; esac
        sleep 2
    done
    return 1
}

# Nommage pour Jellyfin (voir l'en-tête). $1=sonarr|radarr $2=utilisateur
arr_naming() {
    local svc="$1" user="$2" naming items body
    naming=$(arr_api "$svc" "$user" GET /config/naming) || return 1
    body=$(N="$naming" S="$svc" python3 -c '
import json, os, sys
n = json.loads(os.environ["N"])
if os.environ["S"] == "radarr":
    if n.get("renameMovies"):
        sys.exit(3)
    n.update(renameMovies=True, replaceIllegalCharacters=True, colonReplacementFormat="smart",
             movieFolderFormat="{Movie Title} ({Release Year}) [tmdbid-{TmdbId}]",
             standardMovieFormat="{Movie Title} ({Release Year}) [tmdbid-{TmdbId}] - {Quality Full}")
else:
    if n.get("renameEpisodes"):
        sys.exit(3)
    ep = "{Series TitleYear} - S{season:00}E{episode:00} - {Episode Title} {Quality Full}"
    n.update(renameEpisodes=True, replaceIllegalCharacters=True, multiEpisodeStyle=5,
             seriesFolderFormat="{Series TitleYear} [tvdbid-{TvdbId}]",
             seasonFolderFormat="Season {season:00}", specialsFolderFormat="Specials",
             standardEpisodeFormat=ep, animeEpisodeFormat=ep,
             dailyEpisodeFormat="{Series TitleYear} - {Air-Date} - {Episode Title} {Quality Full}")
print(json.dumps(n))')
    case $? in 0) ;; 3) return 0 ;; *) return 1 ;; esac
    arr_api "$svc" "$user" PUT "/config/naming/$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" "$body" >/dev/null || return 1
    # Médias déjà présents : fichiers renommés, puis dossiers déplacés (par
    # dossier racine)
    local kind=movie ids=movieIds rename=RenameMovie
    [ "$svc" = sonarr ] && { kind=series; ids=seriesIds; rename=RenameSeries; }
    items=$(arr_api "$svc" "$user" GET "/$kind") || return 1
    [ "$(printf '%s' "$items" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = 0 ] && return 0
    _arr_command "$svc" "$user" "$(I="$items" K="$ids" R="$rename" python3 -c '
import json, os
print(json.dumps({"name": os.environ["R"], os.environ["K"]: [m["id"] for m in json.loads(os.environ["I"])]}))')" || return 1
    I="$items" K="$ids" python3 -c '
import json, os, posixpath
groups = {}
for m in json.loads(os.environ["I"]):
    groups.setdefault(posixpath.dirname(m["path"].rstrip("/")), []).append(m["id"])
for root, ids in groups.items():
    print(json.dumps({os.environ["K"]: ids, "rootFolderPath": root, "moveFiles": True}))' | while IFS= read -r body; do
        arr_api "$svc" "$user" PUT "/$kind/editor" "$body" >/dev/null || exit 1
    done
}

ARR_PROFILE="Seedbox optimisé"
# Bonus du profil (nom;expression cherchée dans le nom de la release;score) :
# meilleure qualité pour peu de place, doublage de France préféré ; 3D et
# fausse 4K (upscale) refusées ; complétés dans un profil existant
ARR_BONUS='HEVC;\b(HEVC|[xh][ ._-]?265)\b;20
10 bits;\b(10[ ._-]?bits?|Hi10P?)\b;20
HDR;\bHDR(10(\+|P(lus)?)?)?\b;15
EAC3;\b(E-?AC-?3|DDP|DD\+);15
Atmos;\bATMOS\b;15
IMAX;\bIMAX\b;10
5.1 / 7.1;(?<!\d)[57][ ._]1(?!\d);10
AV1;\bAV1\b;20
VFF;\b(VFF|TRUEFRENCH|VF2)\b;10
VFQ;\bVFQ\b;-10
3D;\b(3D|H?SBS|HOU)\b;-10000
Upscale;\b(Upscaled?|AI[ ._-]?Upscal(e|ed)|Regrade[d]?)\b;-10000'

# Formats bonus manquants créés ; affiche « id score » de ceux créés.
# $1=service $2=utilisateur
_arr_bonus_formats() {
    local name re score id cfs
    cfs=$(arr_api "$1" "$2" GET /customformat) || return 1
    while IFS=';' read -r name re score; do
        C="$cfs" N="$name" python3 -c 'import json, os, sys
sys.exit(0 if any(c["name"] == os.environ["N"] for c in json.loads(os.environ["C"])) else 1)' && continue
        id=$(_arr_custom_format "$1" "$2" "$name" ReleaseTitleSpecification "$(R="$re" python3 -c 'import json, os; print(json.dumps({"value": os.environ["R"]}))')") || return 1
        echo "$id $score"
    done <<< "$ARR_BONUS"
}

# Format personnalisé créé s'il manque. Affiche son id. $1=service
# $2=utilisateur $3=nom $4=spécification (LanguageSpecification…) $5=champs (JSON)
_arr_custom_format() {
    local svc="$1" user="$2" name="$3" impl="$4" fields="$5" cfs id body
    cfs=$(arr_api "$svc" "$user" GET /customformat) || return 1
    id=$(C="$cfs" N="$name" python3 -c 'import json, os
print(next((c["id"] for c in json.loads(os.environ["C"]) if c["name"] == os.environ["N"]), ""))')
    [ -n "$id" ] && { echo "$id"; return 0; }
    body=$(SCHEMA="$(arr_api "$svc" "$user" GET /customformat/schema)" N="$name" I="$impl" F="$fields" python3 -c '
import json, os
e = os.environ
spec = next(s for s in json.loads(e["SCHEMA"]) if s["implementation"] == e["I"])
vals = json.loads(e["F"])
for f in spec["fields"]:
    if f["name"] in vals:
        f["value"] = vals[f["name"]]
spec.update(name=e["N"], negate=False, required=True)
print(json.dumps({"name": e["N"], "includeCustomFormatWhenRenaming": False, "specifications": [spec]}))') || return 1
    arr_api "$svc" "$user" POST /customformat "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

# Profil « Seedbox optimisé » (voir l'en-tête). $1=sonarr|radarr $2=utilisateur
arr_quality_profile() {
    local svc="$1" user="$2" bonus big="" profiles pid cfs defs body id kind=movie ids=movieIds
    [ "$svc" = sonarr ] && { kind=series; ids=seriesIds; }
    profiles=$(arr_api "$svc" "$user" GET /qualityprofile) || return 1
    pid=$(P="$profiles" N="$ARR_PROFILE" python3 -c 'import json, os
print(next((p["id"] for p in json.loads(os.environ["P"]) if p["name"] == os.environ["N"]), ""))')
    bonus=$(_arr_bonus_formats "$svc" "$user") || return 1
    if [ -n "$pid" ]; then
        # Profil existant : scores des nouveaux bonus seulement
        [ -n "$bonus" ] || return 0
        body=$(P="$profiles" I="$pid" B="$bonus" python3 -c '
import json, os
e = os.environ
p = next(x for x in json.loads(e["P"]) if x["id"] == int(e["I"]))
new = {int(a): int(b) for a, b in (l.split() for l in e["B"].splitlines())}
items = {f["format"]: f for f in p.get("formatItems", [])}
for fid, sc in new.items():
    items.setdefault(fid, {"format": fid, "score": 0})["score"] = sc
p["formatItems"] = list(items.values())
print(json.dumps(p))') || return 1
        arr_api "$svc" "$user" PUT "/qualityprofile/$pid" "$body" >/dev/null
        return
    fi
    [ "$svc" = radarr ] && { big=$(_arr_custom_format "$svc" "$user" "Plus de 4 Go" SizeSpecification '{"min": 4, "max": 10000}') || return 1; }
    # Taille préférée réduite (Mo par minute ; film 1080p de 2 h : 2,4 Go) ;
    # Sonarr : au plus 34 Mo/min (2 Go par heure d'épisode)
    defs=$(arr_api "$svc" "$user" GET /qualitydefinition) || return 1
    D="$defs" S="$svc" python3 -c '
import json, os
for d in json.loads(os.environ["D"]):
    n = d["quality"]["name"]
    pref = 10 if "720p" in n else 20 if "1080p" in n else 30 if "2160p" in n else None
    if pref is None or "Remux" in n:
        continue
    if os.environ["S"] == "sonarr":
        d["maxSize"] = 34
        d["minSize"] = min(d.get("minSize") or 0, 2)
    d["preferredSize"] = max(min(pref, d.get("maxSize") or pref), d.get("minSize") or 0)
    print(json.dumps(d))' | while IFS= read -r body; do
        arr_api "$svc" "$user" PUT "/qualitydefinition/$(printf '%s' "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')" "$body" >/dev/null || exit 1
    done || return 1
    cfs=$(arr_api "$svc" "$user" GET /customformat) || return 1
    body=$(SCHEMA="$(arr_api "$svc" "$user" GET /qualityprofile/schema)" C="$cfs" S="$svc" N="$ARR_PROFILE" \
           B="$bonus" BIG="$big" python3 -c '
import json, os
e = os.environ
p = json.loads(e["SCHEMA"])
# 720p minimum, jusqu à la 4K ; ni Remux, ni BR-DISK, ni Raw-HD
wanted = {"HDTV-720p", "WEB 720p", "Bluray-720p", "HDTV-1080p", "WEB 1080p", "Bluray-1080p",
          "HDTV-2160p", "WEB 2160p", "Bluray-2160p"}
cutoff = None
for i in p["items"]:
    name = i["quality"]["name"] if i.get("quality") else i["name"]
    i["allowed"] = name in wanted
    for sub in i.get("items", []):
        sub["allowed"] = i["allowed"]
    if name == "Bluray-2160p":
        cutoff = i["quality"]["id"]
scores = {c["id"]: 0 for c in json.loads(e["C"])}
for c in json.loads(e["C"]):
    if c["name"] == "VF" and e["S"] == "sonarr":
        scores[c["id"]] = 100
for l in e["B"].splitlines():
    fid, sc = l.split()
    scores[int(fid)] = int(sc)
if e["BIG"]:
    scores[int(e["BIG"])] = -10000
p.update(name=e["N"], upgradeAllowed=True, cutoff=cutoff,
         formatItems=[{"format": k, "score": v} for k, v in scores.items()],
         minFormatScore=1 if e["S"] == "sonarr" else 0, cutoffFormatScore=10000, minUpgradeFormatScore=1)
if e["S"] == "radarr":
    p["language"] = {"id": 2, "name": "French"}
p.pop("id", None)
print(json.dumps(p))') || return 1
    id=$(arr_api "$svc" "$user" POST /qualityprofile "$body" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])') || return 1
    # Médias déjà présents : nouveau profil
    body=$(arr_api "$svc" "$user" GET "/$kind" | K="$ids" Q="$id" python3 -c '
import json, os, sys
items = [m["id"] for m in json.load(sys.stdin)]
print(json.dumps({os.environ["K"]: items, "qualityProfileId": int(os.environ["Q"])}) if items else "")') || return 1
    [ -z "$body" ] || arr_api "$svc" "$user" PUT "/$kind/editor" "$body" >/dev/null
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
            arr_naming "$svc" "$user" || { echo "$svc-$user : nommage pour Jellyfin non appliqué" >&2; rc=1; }
            arr_quality_profile "$svc" "$user" || { echo "$svc-$user : profil « $ARR_PROFILE » non créé" >&2; rc=1; }
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
