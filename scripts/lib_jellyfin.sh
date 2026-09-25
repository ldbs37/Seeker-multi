#!/bin/bash
#######################
# lib_jellyfin.sh — Comptes Jellyfin des utilisateurs seedbox + connexion
# unique via Authelia (plugin « SSO Authentication »)
#
# - Clé d'API « seedbox » (reprise ou créée dans la base de Jellyfin).
# - Chaque utilisateur : compte Jellyfin (même nom ; même mot de passe que la
#   seedbox quand il est connu — add_user.sh, update_password.sh), SES
#   bibliothèques (séries et films dans son dossier), accès
#   limité à celles-ci ; les administrateurs seedbox (groupe admins) sont
#   administrateurs Jellyfin et voient tout.
# - Mode Traefik : bouton « Se connecter avec Authelia » sur la page de
#   connexion (plugin 9p4/jellyfin-plugin-sso, client OIDC « jellyfin »).
#   À chaque connexion, le plugin applique les droits selon les groupes
#   Authelia (u-<user> → ses bibliothèques, admins → tout + administrateur,
#   seul le groupe users peut se connecter). Applis TV/mobile : mot de passe
#   seedbox, ou Quick Connect (code validé depuis le navigateur).
#
# Vérifié sur Jellyfin 10.11.11 et 12.1 (images officielles) et le plugin
# 4.0.0.4 ; en-têtes « Authorization: MediaBrowser » (Jellyfin 12 ne lit plus
# X-Emby-Token ni X-Emby-Authorization).
# Variables : INSTALL_DIR, DOMAIN (mode Traefik).
#######################

JELLYFIN_LOCAL_URL="${JELLYFIN_LOCAL_URL:-http://localhost:8096}"
JF_SSO_NAME="SSO Authentication"
JF_SSO_GUID="505ce9d1-d916-42fa-86ca-673ef241d7df"
JF_SSO_VERSION="4.0.0.4"
JF_SSO_MANIFEST="https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json"
JF_SSO_PROVIDER="authelia"
JF_KEY=""

# Enregistre la clé d'API (aussi lue par update_password.sh)
_jf_save_key() {
    printf 'JELLYFIN_URL=%s\nJELLYFIN_API_KEY=%s\n' "$JELLYFIN_LOCAL_URL" "$1" > "$INSTALL_DIR/.jellyfin_api"
    chmod 600 "$INSTALL_DIR/.jellyfin_api"
}

# Clé d'API créée par l'API (identifiants administrateur connus : fin de
# l'assistant). $1=administrateur $2=mot de passe. Affiche la clé.
jellyfin_api_key_from_login() {
    local h token key
    # En-tête « Authorization: MediaBrowser » : seul accepté par Jellyfin 12
    # (X-Emby-Authorization supprimé), valable aussi en 10.11
    h='Authorization: MediaBrowser Client="seedbox", Device="seedbox", DeviceId="seedbox-setup", Version="1.0"'
    token=$(curl -s -m 30 -X POST "$JELLYFIN_LOCAL_URL/Users/AuthenticateByName" -H "$h" -H 'Content-Type: application/json' \
        -d "$(N="$1" P="$2" python3 -c 'import json,os; print(json.dumps({"Username":os.environ["N"],"Pw":os.environ["P"]}))')" \
        | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().lstrip("\ufeff"))["AccessToken"])' 2>/dev/null) || return 1
    [ -n "$token" ] || return 1
    curl -s -o /dev/null -m 30 -X POST "$JELLYFIN_LOCAL_URL/Auth/Keys?app=seedbox" -H "$h, Token=\"$token\"" || return 1
    key=$(curl -s -m 30 "$JELLYFIN_LOCAL_URL/Auth/Keys" -H "$h, Token=\"$token\"" \
        | python3 -c 'import json,sys; print(next((k["AccessToken"] for k in json.loads(sys.stdin.read().lstrip("\ufeff"))["Items"] if k["AppName"]=="seedbox"), ""))')
    [ -n "$key" ] || return 1
    _jf_save_key "$key"; echo "$key"
}

# Clé d'API Jellyfin du serveur (administrateur) : celle de
# $INSTALL_DIR/.jellyfin_api, sinon la clé « seedbox » de Jellyfin, sinon
# créée dans sa base — Jellyfin ARRÊTÉ le temps de l'écriture (écrire dans
# la base d'un Jellyfin en marche peut l'endommager). Affiche la clé.
jellyfin_ensure_api_key() {
    local db key rc
    key=$(sed -n 's/^JELLYFIN_API_KEY=\([0-9a-f]\{32\}\)$/\1/p' "$INSTALL_DIR/.jellyfin_api" 2>/dev/null)
    [ -n "$key" ] && { echo "$key"; return 0; }
    db=$(find -L "$INSTALL_DIR/jellyfin/config" -maxdepth 3 -name jellyfin.db -size +0 2>/dev/null | head -1)
    [ -n "$db" ] || return 1
    key=$(python3 -c '
import sqlite3, sys
db = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
row = db.execute("select AccessToken from ApiKeys where Name = ? order by Id limit 1", ("seedbox",)).fetchone()
print(row[0] if row else "")' "$db" 2>/dev/null)
    if [ -z "$key" ]; then
        key=$(openssl rand -hex 16)
        echo "Jellyfin : création de la clé d'API (arrêt de quelques secondes)..." >&2
        docker stop jellyfin >/dev/null 2>&1 || true
        python3 -c '
import datetime, sqlite3, sys
db = sqlite3.connect(sys.argv[1], timeout=30)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S")
cols = {c[1] for c in db.execute("pragma table_info(ApiKeys)")}
row = {"DateCreated": now, "DateLastActivity": now, "Name": "seedbox", "AccessToken": sys.argv[2]}
row = {k: v for k, v in row.items() if k in cols}
db.execute("insert into ApiKeys(%s) values (%s)" % (",".join(row), ",".join("?" * len(row))), list(row.values()))
db.commit()' "$db" "$key"
        rc=$?
        docker start jellyfin >/dev/null 2>&1 || true
        [ "$rc" -eq 0 ] || return 1
        jellyfin_wait || return 1
    fi
    _jf_save_key "$key"
    echo "$key"
}

# Appel d'API. $1=méthode $2=chemin [$3=corps JSON]. Corps sur stdout ;
# retour 0 si HTTP 2xx.
jf_api() {
    local out code
    [ -n "$JF_KEY" ] || JF_KEY=$(jellyfin_ensure_api_key) || return 1
    # Clé d'API dans « Authorization: MediaBrowser Token=… » (Jellyfin 12 ne lit
    # plus X-Emby-Token ni ?api_key=)
    out=$(curl -s -m 60 -X "$1" -H "Authorization: MediaBrowser Token=\"$JF_KEY\"" -H 'Content-Type: application/json' \
        ${3:+--data "$3"} -w '\n%{http_code}' "$JELLYFIN_LOCAL_URL$2") || return 1
    code=${out##*$'\n'}
    out=${out%$'\n'*}
    printf '%s' "${out#$'\xef\xbb\xbf'}"
    [[ "$code" == 2* ]]
}

# Jellyfin joignable (JELLYFIN_WAIT secondes, 120 par défaut) ?
jellyfin_wait() {
    local i n=$(( ${JELLYFIN_WAIT:-120} / 2 ))
    [ "$n" -ge 1 ] || n=1
    for i in $(seq 1 "$n"); do
        curl -fs -m 5 "$JELLYFIN_LOCAL_URL/health" >/dev/null 2>&1 && return 0
        [ "$i" = "$n" ] || sleep 2
    done
    return 1
}

jellyfin_available() {
    grep -q "^  jellyfin:" "$INSTALL_DIR/docker-compose.yml" 2>/dev/null && jellyfin_wait
}

# Assistant de premier démarrage terminé ?
jellyfin_wizard_done() {
    curl -fs -m 10 "$JELLYFIN_LOCAL_URL/System/Info/Public" 2>/dev/null \
        | python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.stdin.read().lstrip("\ufeff")).get("StartupWizardCompleted") else 1)' 2>/dev/null
}

# Termine l'assistant s'il ne l'est pas : administrateur $1 (mot de passe $2,
# sinon aléatoire : connexion via Authelia, ou update_password.sh), langue
# de la seedbox. Retour 0 si l'assistant est terminé.
jellyfin_wizard_ensure() {
    local user="$1" pass="${2:-}" lang="fr" culture="fr-FR" country="FR" base="$JELLYFIN_LOCAL_URL" body
    jellyfin_wizard_done && return 0
    [ -n "$pass" ] || pass=$(openssl rand -base64 24)
    if declare -F seedbox_lang >/dev/null; then
        lang=$(seedbox_lang); read -r culture country <<< "$(lang_jellyfin "$lang")"
    fi
    # Ordre imposé : Configuration → User (GET puis POST) → RemoteAccess → Complete
    curl -s -o /dev/null -X POST "$base/Startup/Configuration" -H "Content-Type: application/json" \
        -d "{\"UICulture\":\"$culture\",\"MetadataCountryCode\":\"$country\",\"PreferredMetadataLanguage\":\"$lang\"}" || true
    curl -s -o /dev/null "$base/Startup/User" || true
    body=$(N="$user" P="$pass" python3 -c 'import json,os; print(json.dumps({"Name":os.environ["N"],"Password":os.environ["P"]}))')
    curl -s -o /dev/null -X POST "$base/Startup/User" -H "Content-Type: application/json" -d "$body" || true
    curl -s -o /dev/null -X POST "$base/Startup/RemoteAccess" -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' || true
    curl -s -o /dev/null -X POST "$base/Startup/Complete" || true
    # Jellyfin finit de s'initialiser après l'assistant
    local i
    for i in $(seq 1 30); do
        jellyfin_wizard_done && break
        sleep 2
    done
    jellyfin_wizard_done || return 1
    # Clé d'API créée par l'API (sans toucher à la base)
    for i in $(seq 1 10); do
        JF_KEY=$(jellyfin_api_key_from_login "$user" "$pass") && break
        sleep 3
    done
    [ -n "$JF_KEY" ]
}

# Premier administrateur seedbox (groupe admins d'Authelia)
jellyfin_first_admin() {
    local u
    for u in $(_jf_seedbox_users); do
        password_user_is_admin "$u" "$INSTALL_DIR/authelia/users_database.yml" 2>/dev/null && { echo "$u"; return 0; }
    done
    return 1
}

# Tout synchroniser (migration, installation existante) : assistant, comptes
# et bibliothèques de chaque utilisateur (mot de passe inchangé ; aléatoire
# pour un compte créé), connexion unique en mode Traefik.
jellyfin_sync_all() {
    local u admin
    jellyfin_available || return 1
    if ! jellyfin_wizard_done; then
        admin=$(jellyfin_first_admin) || admin=$(_jf_seedbox_users | head -1)
        [ -n "$admin" ] || return 1
        jellyfin_wizard_ensure "$admin" || return 1
    fi
    for u in $(_jf_seedbox_users); do
        jellyfin_user_sync "$u" || echo "Jellyfin : compte de $u incomplet" >&2
    done
    if [ "${USE_TRAEFIK:-false}" = true ]; then jellyfin_sso_ensure || return 1; fi
    return 0
}

# Bibliothèques d'un utilisateur : « <Libellé> (<user>) » sur
# /media/users/<user>/<dossier> (data monté en lecture seule sur /media).
# Créées si absentes. Affiche la liste JSON de leurs ItemId.
jellyfin_user_libraries() {
    local user="$1" existing label dir type name q uid
    uid=$(id -u "$user")
    mkdir -p "$INSTALL_DIR/data/users/$user"/{tv,movies}
    chown "$uid:$uid" "$INSTALL_DIR/data/users/$user"/{tv,movies} 2>/dev/null || true
    existing=$(jf_api GET /Library/VirtualFolders) || return 1
    # Anciennes bibliothèques Livres / Musique (versions précédentes) : retirées
    # de Jellyfin (fichiers conservés)
    for label in Livres Musique; do
        J="$existing" N="$label ($user)" python3 -c 'import json,os,sys; sys.exit(0 if any(f["Name"]==os.environ["N"] for f in json.loads(os.environ["J"].lstrip("\ufeff"))) else 1)' || continue
        q=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.urlencode({"name":sys.argv[1],"refreshLibrary":"false"}))' "$label ($user)")
        jf_api DELETE "/Library/VirtualFolders?$q" >/dev/null || echo "Bibliothèque Jellyfin « $label ($user) » non retirée" >&2
    done
    while IFS='|' read -r label dir type; do
        name="$label ($user)"
        J="$existing" N="$name" python3 -c 'import json,os,sys; sys.exit(0 if any(f["Name"]==os.environ["N"] for f in json.loads(os.environ["J"])) else 1)' && continue
        q=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.urlencode({"name":sys.argv[1],"collectionType":sys.argv[2],"paths":sys.argv[3],"refreshLibrary":"false"}))' \
            "$name" "$type" "/media/users/$user/$dir")
        # Jellyfin parfois occupé (initialisation, scan) : quelques essais
        for _ in 1 2 3 4 5; do
            jf_api POST "/Library/VirtualFolders?$q" '{"LibraryOptions":{"EnableRealtimeMonitor":true}}' >/dev/null && break
            sleep 3
            # Créée malgré l'erreur ?
            jf_api GET /Library/VirtualFolders | N="$name" python3 -c 'import json,os,sys; sys.exit(0 if any(f["Name"]==os.environ["N"] for f in json.loads(sys.stdin.read().lstrip("\ufeff"))) else 1)' && break
        done || echo "Bibliothèque Jellyfin « $name » non créée" >&2
    done << 'LIBS'
Séries TV|tv|tvshows
Films|movies|movies
LIBS
    jf_api GET /Library/VirtualFolders | U="$user" python3 -c '
import json, os, sys
suffix = " (%s)" % os.environ["U"]
print(json.dumps([f["ItemId"] for f in json.loads(sys.stdin.read().lstrip("\ufeff")) if f["Name"].endswith(suffix)]))'
}

# Compte Jellyfin d'un utilisateur seedbox : créé s'il manque (mot de passe
# donné, sinon aléatoire : connexion par Authelia ou update_password.sh),
# mot de passe mis à jour s'il est donné, bibliothèques, droits.
# $1=utilisateur [$2=mot de passe]. Retour 0 si tout est appliqué.
jellyfin_user_sync() {
    local user="$1" pass="${2:-}" users jid folders admin=false policy
    users=$(jf_api GET /Users) || return 1
    jid=$(J="$users" N="$user" python3 -c 'import json,os; print(next((u["Id"] for u in json.loads(os.environ["J"]) if u["Name"].lower()==os.environ["N"].lower()), ""))')
    if [ -z "$jid" ]; then
        [ -n "$pass" ] || pass=$(openssl rand -base64 24)
        jid=$(jf_api POST /Users/New "$(N="$user" P="$pass" python3 -c 'import json,os; print(json.dumps({"Name":os.environ["N"],"Password":os.environ["P"]}))')" \
            | python3 -c 'import json,sys; print(json.loads(sys.stdin.read().lstrip("\ufeff")).get("Id",""))' 2>/dev/null)
        [ -n "$jid" ] || { echo "Compte Jellyfin $user non créé" >&2; return 1; }
    elif [ -n "$pass" ]; then
        jf_api POST "/Users/$jid/Password" "$(P="$pass" python3 -c 'import json,os; print(json.dumps({"NewPw":os.environ["P"],"ResetPassword":False}))')" >/dev/null \
            || echo "Mot de passe Jellyfin de $user non mis à jour" >&2
    fi
    folders=$(jellyfin_user_libraries "$user") || return 1
    declare -F password_user_is_admin >/dev/null \
        && password_user_is_admin "$user" "$INSTALL_DIR/authelia/users_database.yml" && admin=true
    # Politique complète relue puis modifiée (champs obligatoires conservés)
    policy=$(jf_api GET "/Users/$jid" | A="$admin" F="$folders" python3 -c '
import json, os, sys
p = json.loads(sys.stdin.read().lstrip("\ufeff"))["Policy"]
if os.environ["A"] == "true":
    p.update({"IsAdministrator": True, "EnableAllFolders": True})
else:
    p.update({"IsAdministrator": False, "EnableAllFolders": False, "EnabledFolders": json.loads(os.environ["F"]),
              "EnableContentDeletion": False, "EnableRemoteControlOfOtherUsers": False,
              "EnablePublicSharing": False})
print(json.dumps(p))') || return 1
    jf_api POST "/Users/$jid/Policy" "$policy" >/dev/null || { echo "Droits Jellyfin de $user non appliqués" >&2; return 1; }
    jf_api POST /Library/Refresh >/dev/null || true
}

# Supprime le compte Jellyfin et les bibliothèques d'un utilisateur (ses
# fichiers restent sur le disque).
jellyfin_user_remove() {
    local user="$1" jid names n q
    jid=$(jf_api GET /Users | N="$user" python3 -c 'import json,os,sys; print(next((u["Id"] for u in json.loads(sys.stdin.read().lstrip("\ufeff")) if u["Name"].lower()==os.environ["N"].lower()), ""))') || return 1
    [ -n "$jid" ] && jf_api DELETE "/Users/$jid" >/dev/null
    names=$(jf_api GET /Library/VirtualFolders | U="$user" python3 -c '
import json, os, sys
print("\n".join(f["Name"] for f in json.loads(sys.stdin.read().lstrip("\ufeff")) if f["Name"].endswith(" (%s)" % os.environ["U"])))')
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        q=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.urlencode({"name":sys.argv[1],"refreshLibrary":"false"}))' "$n")
        jf_api DELETE "/Library/VirtualFolders?$q" >/dev/null || true
    done <<< "$names"
    return 0
}

# Utilisateurs seedbox (UID de la plage seedbox, dossier de données présent)
_jf_seedbox_users() {
    awk -F: -v min="${SEEDBOX_UID_MIN:-2001}" -v max="${SEEDBOX_UID_MAX:-2999}" \
        '$3 >= min && $3 <= max { print $1 }' /etc/passwd | while read -r u; do
        [ -d "$INSTALL_DIR/data/users/$u" ] && echo "$u"
    done
}

# Client OIDC « jellyfin » dans la configuration Authelia (s'il manque).
# $1 = configuration.yml. Retour 0 si modifiée (redémarrage d'Authelia).
authelia_ensure_oidc_jellyfin() {
    local cfg="$1" env="$INSTALL_DIR/.env" secret hash
    [ -f "$cfg" ] && grep -q '^identity_providers:' "$cfg" || return 1
    grep -q "client_id: 'jellyfin'" "$cfg" && return 1
    grep -qE '^JELLYFIN_OIDC_SECRET=[0-9a-f]{64}$' "$env" \
        || echo "JELLYFIN_OIDC_SECRET=$(openssl rand -hex 32)" >> "$env"
    chmod 600 "$env"
    secret=$(grep '^JELLYFIN_OIDC_SECRET=' "$env" | cut -d= -f2)
    hash=$(docker run --rm "${HOMARR_AUTHELIA_IMAGE:-authelia/authelia:4.39.28}" authelia crypto hash generate pbkdf2 \
        --variant sha512 --password "$secret" 2>/dev/null | awk '/Digest:/{print $2}')
    [[ "$hash" == '$pbkdf2-sha512$'* ]] || { echo "hachage du secret OIDC Jellyfin impossible" >&2; return 2; }
    AE_DOMAIN="$DOMAIN" AE_HASH="$hash" python3 - "$cfg" << 'EOF_PY'
import os, re, sys
path = sys.argv[1]; s = open(path).read()
client = (
    "      - client_id: 'jellyfin'\n"
    "        client_name: 'Jellyfin'\n"
    "        client_secret: '%s'\n"
    "        public: false\n"
    "        authorization_policy: 'one_factor'\n"
    "        consent_mode: 'implicit'\n"
    "        require_pkce: true\n"
    "        pkce_challenge_method: 'S256'\n"
    "        redirect_uris:\n"
    "          - 'https://jellyfin.%s/sso/OID/redirect/authelia'\n"
    "        scopes:\n"
    "          - 'openid'\n"
    "          - 'profile'\n"
    "          - 'groups'\n"
    "        userinfo_signed_response_alg: 'none'\n"
    "        token_endpoint_auth_method: 'client_secret_post'\n"
) % (os.environ["AE_HASH"], os.environ["AE_DOMAIN"])
s2 = re.sub(r"^(    clients:\n)", lambda m: m.group(1) + client, s, count=1, flags=re.M)
if s2 == s:
    sys.exit(1)
open(path, "w").write(s2)
EOF_PY
    chmod 600 "$cfg"
}

# Plugin SSO : installé si absent (Jellyfin redémarré), fournisseur
# « authelia » configuré (droits selon les groupes), bouton de connexion.
# À appeler après la création des comptes (correspondance groupes →
# bibliothèques recalculée à chaque appel).
jellyfin_sso_ensure() {
    local secret plugins repos conf users u f label
    secret=$(grep '^JELLYFIN_OIDC_SECRET=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2)
    [ -n "$secret" ] && [ -n "${DOMAIN:-}" ] || return 1
    plugins=$(jf_api GET /Plugins) || return 1
    if ! P="$plugins" python3 -c 'import json,os,sys; sys.exit(0 if any(p["Name"] in ("SSO-Auth","SSO Authentication") for p in json.loads(os.environ["P"])) else 1)'; then
        repos=$(jf_api GET /Repositories | M="$JF_SSO_MANIFEST" python3 -c '
import json, os, sys
r = [x for x in json.loads(sys.stdin.read().lstrip("\ufeff")) if x["Url"] != os.environ["M"]]
r.append({"Name": "SSO Authentication", "Url": os.environ["M"], "Enabled": True})
print(json.dumps(r))') || return 1
        jf_api POST /Repositories "$repos" >/dev/null || return 1
        jf_api POST "/Packages/Installed/$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$JF_SSO_NAME")?assemblyGuid=$JF_SSO_GUID&version=$JF_SSO_VERSION&repositoryUrl=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$JF_SSO_MANIFEST")" >/dev/null \
            || { echo "Installation du plugin SSO de Jellyfin impossible" >&2; return 1; }
        # Téléchargement puis chargement au redémarrage
        for _ in $(seq 1 30); do
            jf_api GET /Plugins | grep -q '"SSO-Auth"\|"SSO Authentication"' && break
            sleep 2
        done
        docker restart jellyfin >/dev/null 2>&1 || true
        sleep 5; jellyfin_wait || return 1
    fi
    # Correspondance groupes Authelia → bibliothèques
    users=$(_jf_seedbox_users)
    conf=$(jf_api GET /Library/VirtualFolders | U="$users" D="$DOMAIN" S="$secret" python3 -c '
import json, os, sys
libs = json.loads(sys.stdin.read().lstrip("\ufeff")); users = os.environ["U"].split()
mapping = [{"Role": "u-" + u, "Folders": [f["ItemId"] for f in libs if f["Name"].endswith(" (%s)" % u)]} for u in users]
mapping.append({"Role": "admins", "Folders": [f["ItemId"] for f in libs]})
print(json.dumps({
    "OidEndpoint": "https://auth.%s" % os.environ["D"], "OidClientId": "jellyfin", "OidSecret": os.environ["S"],
    "Enabled": True, "EnableAuthorization": True, "EnableAllFolders": False, "EnabledFolders": [],
    "AdminRoles": ["admins"], "Roles": ["users"], "EnableFolderRoles": True, "FolderRoleMapping": mapping,
    "EnableLiveTv": False, "EnableLiveTvManagement": False,
    "RoleClaim": "groups", "OidScopes": ["groups"], "DefaultUsernameClaim": "preferred_username",
    "SchemeOverride": "https", "DisablePushedAuthorization": True, "NewPath": True}))') || return 1
    jf_api POST "/sso/OID/Add/$JF_SSO_PROVIDER" "$conf" >/dev/null || { echo "Configuration du plugin SSO impossible" >&2; return 1; }
    # Bouton sur la page de connexion (texte de la page de connexion de Jellyfin)
    case "$(declare -F seedbox_lang >/dev/null && seedbox_lang || echo fr)" in
        en) label="Sign in with Authelia" ;; de) label="Mit Authelia anmelden" ;;
        es) label="Iniciar sesión con Authelia" ;; it) label="Accedi con Authelia" ;;
        *) label="Se connecter avec Authelia" ;;
    esac
    f=$(jf_api GET /System/Configuration/branding | L="$label" D="$DOMAIN" python3 -c '
import json, os, re, sys
b = json.loads(sys.stdin.read().lstrip("\ufeff"))
btn = ("<!-- seedbox-sso --><form action=\"https://jellyfin.%s/sso/OID/start/authelia\">"
       "<button class=\"raised block emby-button button-submit\">%s</button></form><!-- /seedbox-sso -->") % (os.environ["D"], os.environ["L"])
d = re.sub(r"<!-- seedbox-sso -->.*?<!-- /seedbox-sso -->", "", b.get("LoginDisclaimer") or "", flags=re.S)
b["LoginDisclaimer"] = btn + d
css = re.sub(r"/\* seedbox-sso \*/.*?/\* /seedbox-sso \*/", "", b.get("CustomCss") or "", flags=re.S)
b["CustomCss"] = css + "/* seedbox-sso */ .disclaimerContainer { display: block; } /* /seedbox-sso */"
print(json.dumps(b))') || return 1
    jf_api POST /System/Configuration/branding "$f" >/dev/null || echo "Bouton de connexion Authelia non ajouté" >&2
    return 0
}
