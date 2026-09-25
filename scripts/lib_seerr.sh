#!/bin/bash
#######################
# lib_seerr.sh — Seerr d'un utilisateur, configuré automatiquement (Jellyfin)
#
# - Jellyfin : adresse publique (https://jellyfin.<domaine>) et clé d'API
#   Jellyfin « Seerr » (tableau de bord Jellyfin → Clés API ; créée si elle
#   manque), commune à tous les Seerr. Seules les bibliothèques de
#   l'utilisateur sont cochées. NB : clé administrateur de Jellyfin, lisible
#   par chaque utilisateur dans les réglages de son Seerr.
# - Compte administrateur du Seerr = compte Jellyfin de l'utilisateur :
#   connexion avec ses identifiants Jellyfin (= seedbox).
# - Bibliothèques : ses « Séries TV (<user>) » et « Films (<user>) ».
# - Connexion : identifiants Jellyfin seulement ; ni connexion locale, ni
#   inscription d'autres comptes Jellyfin (Seerr d'une seule personne,
#   administrateur : ses demandes sont validées automatiquement).
# - Pays de diffusion et région de découverte : celui de la langue de la
#   seedbox (France pour fr), s'ils ne sont pas déjà choisis.
# - Sonarr / Radarr de l'utilisateur (clé d'API, profil « Seedbox optimisé »,
#   sinon HD-1080p ou premier profil, /data/tv et /data/movies), ajoutés s'ils manquent.
# Vérifié sur Seerr 3.0.1 et 3.4.1, Jellyfin 12.1. Idempotent ; ne touche pas à un
# Seerr déjà configuré à la main (hors ajout de Sonarr / Radarr manquants).
#
# Variables : INSTALL_DIR, DOMAIN ; fonctions de lib_jellyfin.sh (jf_api),
# lib_homarr.sh (arr_api_key, _wait_config), lib_arr.sh (arr_api),
# lib_lang.sh (seedbox_lang).
#######################

SEERR_DEVICE_PREFIX="seedbox-seerr-"
# Appareil du jeton Jellyfin de l'utilisateur enregistré dans Seerr, distinct de celui de la
# connexion de l'utilisateur : Jellyfin révoque les jetons d'un appareil à
# chaque nouvelle connexion depuis cet appareil
SEERR_API_DEVICE_PREFIX="seedbox-seerr-api-"

# Clé d'API Jellyfin « Seerr » (créée si elle manque). Affiche la clé.
seerr_jellyfin_api_key() {
    local keys key
    keys=$(jf_api GET /Auth/Keys) || return 1
    key=$(printf '%s' "$keys" | python3 -c 'import json,sys
print(next((k["AccessToken"] for k in json.loads(sys.stdin.read().lstrip("\ufeff"))["Items"] if k["AppName"] == "Seerr"), ""))')
    if [ -z "$key" ]; then
        jf_api POST "/Auth/Keys?app=Seerr" >/dev/null || return 1
        key=$(jf_api GET /Auth/Keys | python3 -c 'import json,sys
print(next((k["AccessToken"] for k in json.loads(sys.stdin.read().lstrip("\ufeff"))["Items"] if k["AppName"] == "Seerr"), ""))')
    fi
    [ -n "$key" ] && echo "$key"
}

# Jeton Jellyfin au nom de $1 (Quick Connect). Affiche « <jeton> <userId> ».
seerr_jellyfin_token() {
    local user="$1" jid hdr r code secret
    jid=$(jf_api GET /Users | U="$user" python3 -c 'import json,os,sys
print(next((u["Id"] for u in json.load(sys.stdin) if u["Name"].lower() == os.environ["U"].lower()), ""))')
    [ -n "$jid" ] || return 1
    hdr="MediaBrowser Client=\"Seerr\", Device=\"Seerr\", DeviceId=\"${SEERR_API_DEVICE_PREFIX}${user}\", Version=\"3\""
    r=$(curl -s -m 30 -X POST -H "Authorization: $hdr" "$JELLYFIN_LOCAL_URL/QuickConnect/Initiate") || return 1
    code=$(printf '%s' "$r" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().lstrip("﻿"))["Code"])' 2>/dev/null)
    secret=$(printf '%s' "$r" | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().lstrip("﻿"))["Secret"])' 2>/dev/null)
    [ -n "$code" ] && [ -n "$secret" ] || { echo "Quick Connect désactivé dans Jellyfin ?" >&2; return 1; }
    jf_api POST "/QuickConnect/Authorize?code=$code&userId=$jid" >/dev/null || return 1
    curl -s -m 30 -X POST -H "Authorization: $hdr" -H 'Content-Type: application/json' \
        --data "{\"Secret\":\"$secret\"}" "$JELLYFIN_LOCAL_URL/Users/AuthenticateWithQuickConnect" \
        | python3 -c 'import json,sys
d = json.loads(sys.stdin.read().lstrip("﻿")); print(d["AccessToken"], d["User"]["Id"])' 2>/dev/null
}

# Entrée Sonarr ou Radarr pour Seerr (JSON). $1=sonarr|radarr $2=utilisateur
_seerr_dvr() {
    local svc="$1" user="$2" key profiles
    key=$(arr_api_key "$svc" "$user"); [ -n "$key" ] || return 1
    profiles=$(arr_api "$svc" "$user" GET /qualityprofile) || return 1
    P="$profiles" S="$svc" U="$user" K="$key" D="$DOMAIN" PROFILE="${ARR_PROFILE:-}" python3 -c '
import json, os
e = os.environ; svc = e["S"]
ps = json.loads(e["P"])
p = next((x for x in ps if x["name"] == e["PROFILE"]), None) or next((x for x in ps if x["name"] == "HD-1080p"), ps[0])
d = {"id": 0, "name": svc.capitalize(), "hostname": "%s-%s" % (svc, e["U"]),
     "port": 8989 if svc == "sonarr" else 7878, "apiKey": e["K"], "useSsl": False,
     "baseUrl": "/" + svc, "activeProfileId": p["id"], "activeProfileName": p["name"],
     "activeDirectory": "/data/tv" if svc == "sonarr" else "/data/movies",
     "tags": [], "is4k": False, "isDefault": True,
     "externalUrl": "https://%s.%s/%s" % (e["U"], e["D"], svc),
     "syncEnabled": True, "preventSearch": False, "tagRequests": False, "overrideRule": []}
if svc == "sonarr":
    d.update(seriesType="standard", animeSeriesType="anime", animeTags=[],
             activeAnimeProfileId=p["id"], activeAnimeProfileName=p["name"],
             activeAnimeDirectory="/data/tv", enableSeasonFolders=True)
else:
    d.update(minimumAvailability="released")
print(json.dumps(d))'
}

# Configure le Seerr de $1 (conteneur arrêté pendant l'écriture). Retour 0
# si configuré (ou déjà configuré).
seerr_configure() {
    local user="$1" dir="$INSTALL_DIR/seerr/$1" settings db tok="" jid="" libs="[]" info="{}" key="" \
          sonarr="" radarr="" email state region cid
    settings="$dir/settings.json"; db="$dir/db/db.sqlite3"
    _wait_config "$settings" "seerr-$user" || return 1
    for _ in $(seq 1 30); do [ -s "$db" ] && break; sleep 2; done
    [ -s "$db" ] || return 1
    state=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("init" if d.get("public", {}).get("initialized") else "new")' "$settings") || return 1

    grep -q "^  sonarr-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null && sonarr=$(_seerr_dvr sonarr "$user")
    grep -q "^  radarr-$user:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null && radarr=$(_seerr_dvr radarr "$user")

    if [ "$state" = new ]; then
        # Première configuration : Jellyfin requis
        jellyfin_available && jellyfin_wizard_done || { echo "Jellyfin indisponible : Seerr de $user à configurer plus tard" >&2; return 1; }
        read -r tok jid < <(seerr_jellyfin_token "$user") || true
        [ -n "$tok" ] && [ -n "$jid" ] || { echo "Jeton Jellyfin de $user non obtenu" >&2; return 1; }
        libs=$(jf_api GET /Library/VirtualFolders | U="$user" python3 -c '
import json, os, sys
suffix = " (%s)" % os.environ["U"]; types = {"tvshows": "show", "movies": "movie"}
print(json.dumps([{"id": f["ItemId"], "name": f["Name"], "enabled": True, "type": types[f["CollectionType"]]}
                  for f in json.load(sys.stdin) if f["Name"].endswith(suffix) and f.get("CollectionType") in types]))') || return 1
        info=$(curl -fs -m 10 "$JELLYFIN_LOCAL_URL/System/Info/Public") || return 1
        email=$(awk -v u="  $user:" '$0 == u { f = 1; next } f && /^  [^ ]/ { f = 0 } f && /^    email:/ { gsub(/^    email: *"?|"$/, ""); print; exit }' \
            "$INSTALL_DIR/authelia/users_database.yml" 2>/dev/null)
    fi

    # Clé d'API Jellyfin « Seerr » (Jellyfin indisponible : clé inchangée)
    jellyfin_available && key=$(seerr_jellyfin_api_key)
    [ "$state" = new ] && [ -z "$key" ] && { echo "Clé d'API Jellyfin « Seerr » non obtenue" >&2; return 1; }

    region=$(lang_jellyfin "$(seedbox_lang)" | cut -d' ' -f2)
    cid=$(seerr_secret "$user" SEERR_CLIENT_ID)
    # Déjà configuré et rien à changer : pas de redémarrage
    if [ "$state" = init ] && CID="$cid" D="$DOMAIN" KEY="$key" SONARR="$sonarr" RADARR="$radarr" python3 -c '
import json, os, sys
s = json.load(open(sys.argv[1]))
if s.get("clientId") != os.environ["CID"] or s.get("sessionSecret") != os.environ["CID"]:
    sys.exit(1)
# Ancienne adresse interne (http://jellyfin:8096) → adresse publique
if s["jellyfin"].get("ip") == "jellyfin":
    sys.exit(1)
if os.environ["KEY"] and s["jellyfin"].get("ip") == "jellyfin." + os.environ["D"] and s["jellyfin"].get("apiKey") != os.environ["KEY"]:
    sys.exit(1)
if s["jellyfin"].get("ip") == "jellyfin." + os.environ["D"] and (s["jellyfin"].get("port") != 443 or not s["jellyfin"].get("useSsl")):
    sys.exit(1)
if s["jellyfin"].get("ip") == "jellyfin." + os.environ["D"] and (s["main"].get("localLogin") or s["main"].get("newPlexLogin")
        or not s["main"].get("streamingRegion") or not s["main"].get("discoverRegion")):
    sys.exit(1)
for k in ("sonarr", "radarr"):
    v = os.environ[k.upper()]
    if not v:
        continue
    new = json.loads(v)
    for x in s.get(k, []):
        if x.get("hostname") == new["hostname"] and x.get("activeProfileName") == "HD-1080p" != new["activeProfileName"]:
            sys.exit(1)
    if not any(x.get("hostname") == new["hostname"] for x in s.get(k, [])):
        sys.exit(1)' "$settings"; then
        seerr_session_refresh "$user"
        return 0
    fi
    docker stop "seerr-$user" >/dev/null 2>&1 || true
    CID="$cid" KEY="$key" REGION="$region" ST="$state" TOK="$tok" JID="$jid" LIBS="$libs" INFO="$info" SONARR="$sonarr" RADARR="$radarr" \
    U="$user" D="$DOMAIN" EMAIL="${email:-$user@$DOMAIN}" LANG_SB="$(seedbox_lang)" \
    DEV="${SEERR_DEVICE_PREFIX}${user}" python3 - "$settings" "$db" << 'PY'
import json, os, sqlite3, sys
e = os.environ; path, db = sys.argv[1], sys.argv[2]
s = json.load(open(path))
# Secret de signature des sessions fixé par la seedbox (connexion
# automatique) : clientId jusqu'à Seerr 3.3, sessionSecret depuis 3.4
s["clientId"] = e["CID"]
s["sessionSecret"] = e["CID"]
if e["ST"] == "new":
    info = json.loads(e["INFO"].lstrip("﻿"))
    s["main"].update(mediaServerType=2, mediaServerLogin=True,
                     applicationUrl="https://seerr-%s.%s" % (e["U"], e["D"]), locale=e["LANG_SB"])
    s["jellyfin"].update(name=info.get("ServerName", "Jellyfin"), ip="jellyfin.%s" % e["D"], port=443, useSsl=True,
                         urlBase="", externalHostname="https://jellyfin.%s" % e["D"],
                         libraries=json.loads(e["LIBS"]), serverId=info["Id"], apiKey=e["KEY"])
    s["public"]["initialized"] = True
    c = sqlite3.connect(db)
    fields = dict(email=e["EMAIL"], username=e["U"], jellyfinUsername=e["U"], jellyfinUserId=e["JID"],
                  jellyfinDeviceId=e["DEV"], jellyfinAuthToken=e["TOK"], permissions=2, userType=3,
                  avatar="/avatarproxy/%s" % e["JID"])
    if c.execute("select 1 from user where id = 1").fetchone():
        c.execute("update user set " + ", ".join("%s = ?" % k for k in fields) + " where id = 1", list(fields.values()))
    else:
        c.execute("insert into user (id, %s) values (1, %s)" % (", ".join(fields), ", ".join("?" * len(fields))),
                  list(fields.values()))
    c.commit()
# Jellyfin par son adresse publique (https://jellyfin.<domaine>) ; ancienne
# adresse interne remplacée
if s["jellyfin"].get("ip") == "jellyfin":
    s["jellyfin"].update(ip="jellyfin.%s" % e["D"], port=443, useSsl=True, urlBase="")
# Seerr configuré par la seedbox : connexion Jellyfin seulement, pas de
# connexion locale ni de nouveaux comptes
if s["jellyfin"].get("ip") == "jellyfin.%s" % e["D"]:
    s["jellyfin"].update(port=443, useSsl=True)
    if e["KEY"]:
        s["jellyfin"]["apiKey"] = e["KEY"]
    s["main"].update(localLogin=False, newPlexLogin=False)
    # Pays de diffusion / région de découverte, sauf choix de l'utilisateur
    for k in ("streamingRegion", "discoverRegion"):
        if not s["main"].get(k):
            s["main"][k] = e["REGION"]
# Sonarr / Radarr manquants (jamais de doublon, rien de remplacé)
for key, env in (("sonarr", "SONARR"), ("radarr", "RADARR")):
    if not e[env]:
        continue
    lst = s.setdefault(key, [])
    new = json.loads(e[env])
    # Ancien profil par défaut (HD-1080p) → profil de la seedbox
    for x in lst:
        if x.get("hostname") == new["hostname"] and x.get("activeProfileName") == "HD-1080p" != new["activeProfileName"]:
            x.update(activeProfileId=new["activeProfileId"], activeProfileName=new["activeProfileName"])
            if "activeAnimeProfileId" in new:
                x.update(activeAnimeProfileId=new["activeAnimeProfileId"], activeAnimeProfileName=new["activeAnimeProfileName"])
    if any(x.get("hostname") == new["hostname"] for x in lst):
        continue
    new["id"] = max([x["id"] for x in lst], default=-1) + 1
    new["isDefault"] = not any(x.get("isDefault") and not x.get("is4k") for x in lst)
    lst.append(new)
open(path, "w").write(json.dumps(s, indent=1))
PY
    local rc=$?
    seerr_session_refresh "$user" || rc=1
    docker start "seerr-$user" >/dev/null 2>&1 || true
    return $rc
}

# Session de l'administrateur (id 1) présentée par Traefik : créée ou
# prolongée (Seerr la raccourcit à 30 jours à chaque usage). Possible Seerr
# en marche. $1=utilisateur
seerr_session_refresh() {
    local db="$INSTALL_DIR/seerr/$1/db/db.sqlite3"
    [ -s "$db" ] || return 1
    SID=$(seerr_secret "$1" SEERR_SESSION_ID) python3 - "$db" << 'PY'
import json, os, sqlite3, sys
c = sqlite3.connect(sys.argv[1], timeout=30)
sess = {"cookie": {"originalMaxAge": 2592000000, "expires": "2100-01-01T00:00:00.000Z",
                   "httpOnly": True, "path": "/", "sameSite": "lax"}, "userId": 1}
c.execute("insert or replace into session (id, expiredAt, json) values (?, ?, ?)",
          (os.environ["SID"], 4102444800000, json.dumps(sess)))
c.commit()
PY
}

# Prolongation quotidienne des sessions Seerr (timer systemd)
seerr_sessions_timer_ensure() {
    command -v systemctl >/dev/null 2>&1 || return 0
    [ -f /etc/systemd/system/seedbox-seerr-sessions.timer ] && return 0
    cat > /etc/systemd/system/seedbox-seerr-sessions.service << EOF
[Unit]
Description=Seedbox - prolongation des sessions Seerr (connexion automatique)

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/arr_setup.sh --seerr-sessions
EOF
    cat > /etc/systemd/system/seedbox-seerr-sessions.timer << 'EOF'
[Unit]
Description=Seedbox - prolongation quotidienne des sessions Seerr

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now seedbox-seerr-sessions.timer >/dev/null 2>&1 || true
}
