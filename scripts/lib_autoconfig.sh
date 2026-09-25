#!/bin/bash
#######################
# lib_autoconfig.sh — Création automatique des comptes administrateur
# Portainer et Jellyfin via leur API, disques de Scrutiny, sauvegarde
# Duplicati, connexion unique d'Uptime Kuma (utilisée par install.sh,
# add_service.sh et generate_traefik_labels.sh).
# À sourcer. Requiert les fonctions log/warn/info de l'appelant.
#######################

# Échappe une chaîne pour l'insérer dans une valeur JSON
json_escape() {
    local s=$1
    s=${s//\\/\\\\}; s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# Attend qu'une URL réponde (max $2 secondes, défaut 90)
wait_for_url() {
    local url="$1" max="${2:-90}" t=0
    while [ "$t" -lt "$max" ]; do
        curl -fs -o /dev/null -m 3 "$url" && return 0
        sleep 2; t=$((t + 2))
    done
    return 1
}

# Premier compte du groupe « admins » d'Authelia (affiche son nom).
# $1=dossier d'installation
autoconfig_first_admin() {
    awk '/^  [a-z][a-z0-9]*:[[:space:]]*$/ { u = $1; sub(/:$/, "", u) }
         /^      - admins[[:space:]]*$/ && u != "" { print u; exit }' "${1:-/opt/seedbox}/authelia/users_database.yml" 2>/dev/null
}

# Uptime Kuma sans page de connexion (réglage « disableAuth ») : accès déjà
# réservé aux admins par Authelia. Compte créé s'il n'y en a pas (mot de
# passe aléatoire, inutile ensuite). Base SQLite ou MariaDB intégrée. Vérifié
# sur Uptime Kuma 2.5.5. $1=dossier d'installation $2=nom du compte
autoconfig_uptime_kuma() {
    local dir="${1:-/opt/seedbox}" user="${2:-admin}" data type hash n
    data="$dir/uptime-kuma"
    type=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("type", ""))' "$data/db-config.json" 2>/dev/null)
    case "$type" in
        sqlite|embedded-mariadb) ;;
        *) info "Uptime Kuma : base « ${type:-inconnue} » non prise en charge, connexion laissée telle quelle"; return 0 ;;
    esac
    # Requête SQL (sortie brute) sur la base d'Uptime Kuma
    _kuma_sql() {
        if [ "$type" = sqlite ]; then
            python3 -c 'import sqlite3,sys
c = sqlite3.connect(sys.argv[1])
for r in c.execute(sys.argv[2]).fetchall(): print("\t".join(str(x) for x in r))
c.commit()' "$data/kuma.db" "$1"
        else
            docker exec -u node uptime-kuma mariadb --socket=/app/data/run/mariadb.sock -u node -N -B kuma -e "$1"
        fi
    }
    # Base créée et à jour (tables présentes) au premier démarrage
    for _ in $(seq 1 60); do
        _kuma_sql "select 1 from setting limit 1" >/dev/null 2>&1 && _kuma_sql "select 1 from user limit 1" >/dev/null 2>&1 && break
        sleep 2
    done
    n=$(_kuma_sql "select count(*) from setting where \`key\` = 'disableAuth' and value = 'true'" 2>/dev/null) \
        || { warn "Uptime Kuma : base injoignable ($type)"; return 1; }
    [ "$n" = 1 ] && return 0
    log "Uptime Kuma : connexion unique (Authelia)..."
    hash=$(docker exec -e PW="$(openssl rand -hex 24)" uptime-kuma node -e 'console.log(require("bcryptjs").hashSync(process.env.PW, 10))' 2>/dev/null)
    [[ "$hash" == '$2'* ]] || { warn "Uptime Kuma : conteneur injoignable, connexion unique non appliquée"; return 1; }
    [[ "$user" =~ ^[a-z0-9_-]+$ ]] || user="admin"
    { [ "$(_kuma_sql "select count(*) from user")" != 0 ] \
        || _kuma_sql "insert into user (username, password, active) values ('$user', '$hash', 1)"; } \
        && if [ "$(_kuma_sql "select count(*) from setting where \`key\` = 'disableAuth'")" = 0 ]; then
               _kuma_sql "insert into setting (\`key\`, value, type) values ('disableAuth', 'true', 'general')"
           else
               _kuma_sql "update setting set value = 'true' where \`key\` = 'disableAuth'"
           fi \
        || { warn "Uptime Kuma : réglage non enregistré"; return 1; }
    # Redémarrage : Uptime Kuma garde ses réglages en mémoire
    docker restart uptime-kuma >/dev/null 2>&1 || true
    log "✓ Uptime Kuma : ouvert directement après Authelia"
}

# Client OIDC « portainer » dans la configuration Authelia (s'il manque),
# réservé au groupe admins. $1 = configuration.yml. Retour 0 si modifiée
# (redémarrage d'Authelia).
authelia_ensure_oidc_portainer() {
    local cfg="$1" env="$INSTALL_DIR/.env" secret hash
    [ -f "$cfg" ] && grep -q '^identity_providers:' "$cfg" || return 1
    grep -q "client_id: 'portainer'" "$cfg" && return 1
    grep -qE '^PORTAINER_OIDC_SECRET=[0-9a-f]{64}$' "$env" \
        || echo "PORTAINER_OIDC_SECRET=$(openssl rand -hex 32)" >> "$env"
    chmod 600 "$env"
    secret=$(grep '^PORTAINER_OIDC_SECRET=' "$env" | cut -d= -f2)
    hash=$(${AUTHELIA_BIN:-docker run --rm authelia/authelia:4.39.28 authelia} crypto hash generate pbkdf2 \
        --variant sha512 --password "$secret" 2>/dev/null | awk '/Digest:/{print $2}')
    [[ "$hash" == '$pbkdf2-sha512$'* ]] || { echo "hachage du secret OIDC Portainer impossible" >&2; return 2; }
    AE_DOMAIN="$DOMAIN" AE_HASH="$hash" python3 - "$cfg" << 'EOF_PY'
import os, re, sys
path = sys.argv[1]; s = open(path).read()
# Politique « admins » (groupe admins seulement) : sinon tout compte Authelia
# pourrait obtenir un code pour ce client
if not re.search(r"^    authorization_policies:\n", s, re.M):
    pol = ("    authorization_policies:\n"
           "      admins:\n"
           "        default_policy: 'deny'\n"
           "        rules:\n"
           "          - policy: 'one_factor'\n"
           "            subject: 'group:admins'\n")
    s = re.sub(r"^(    clients:\n)", lambda m: pol + m.group(1), s, count=1, flags=re.M)
client = (
    "      - client_id: 'portainer'\n"
    "        client_name: 'Portainer'\n"
    "        client_secret: '%s'\n"
    "        public: false\n"
    "        authorization_policy: 'admins'\n"
    "        consent_mode: 'implicit'\n"
    "        redirect_uris:\n"
    "          - 'https://portainer.%s'\n"
    "        scopes:\n"
    "          - 'openid'\n"
    "          - 'profile'\n"
    "          - 'email'\n"
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

# Portainer : bouton « Login with OAuth » (Authelia ; déjà connecté : un
# (retour 3 : compte ou mot de passe Portainer refusé)
# clic, rien à saisir) et session de 7 jours. Le compte Portainer du même
# nom (administrateur) est utilisé ; aucun compte créé automatiquement.
# Portainer CE ne permet ni de masquer le formulaire classique ni la
# redirection automatique. Vérifié sur Portainer CE 2.45.1 et Authelia
# 4.39. $1=utilisateur Portainer (admin) $2=mot de passe $3=compte Authelia
# de l'administrateur (défaut $1) : compte Portainer administrateur du même
# nom créé s'il manque (la connexion OAuth retrouve le compte par son nom)
autoconfig_portainer_sso() {
    local user="$1" pass="$2" sso="${3:-$1}" base="${PORTAINER_URL:-http://localhost:9000}" secret jwt body code
    secret=$(grep '^PORTAINER_OIDC_SECRET=' "$INSTALL_DIR/.env" 2>/dev/null | cut -d= -f2)
    [ -n "$secret" ] && [ -n "${DOMAIN:-}" ] || { warn "Portainer : client OIDC absent d'Authelia"; return 1; }
    wait_for_url "$base/api/status" 90 || { warn "Portainer ne répond pas : connexion Authelia non configurée"; return 1; }
    jwt=$(U="$user" P="$pass" python3 -c 'import json,os; print(json.dumps({"Username": os.environ["U"], "Password": os.environ["P"]}))' \
        | curl -s -m 30 -X POST -H 'Content-Type: application/json' --data @- "$base/api/auth" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("jwt",""))' 2>/dev/null)
    [ -n "$jwt" ] || { warn "Portainer : connexion refusée pour « $user » (nom du compte ou mot de passe Portainer incorrect)"; return 3; }
    if ! curl -s -m 30 -H "Authorization: Bearer $jwt" "$base/api/users" | N="$sso" python3 -c 'import json,os,sys
sys.exit(0 if any(u["Username"].lower() == os.environ["N"].lower() for u in json.load(sys.stdin)) else 1)'; then
        body=$(N="$sso" P="$(openssl rand -hex 24)" python3 -c 'import json,os; print(json.dumps({"Username": os.environ["N"], "Password": os.environ["P"], "Role": 1}))')
        code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $jwt" \
            -H 'Content-Type: application/json' --data "$body" "$base/api/users")
        [ "$code" = 200 ] || { warn "Portainer : compte administrateur « $sso » non créé (HTTP $code)"; return 1; }
    fi
    body=$(S="$secret" D="$DOMAIN" A="${AUTHELIA_URL:-https://auth.$DOMAIN}" R="${PORTAINER_PUBLIC_URL:-https://portainer.$DOMAIN}" python3 -c '
import json, os
e = os.environ; a = e["A"]
print(json.dumps({"AuthenticationMethod": 3, "UserSessionTimeout": "168h", "OAuthSettings": {
    "ClientID": "portainer", "ClientSecret": e["S"],
    "AuthorizationURI": a + "/api/oidc/authorization", "AccessTokenURI": a + "/api/oidc/token",
    "ResourceURI": a + "/api/oidc/userinfo", "RedirectURI": e["R"], "LogoutURI": a + "/logout",
    "UserIdentifier": "preferred_username", "Scopes": "openid profile email",
    "OAuthAutoCreateUsers": False, "DefaultTeamID": 0, "SSO": True, "AuthStyle": 1}}))')
    code=$(curl -s -m 30 -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $jwt" \
        -H 'Content-Type: application/json' --data "$body" "$base/api/settings")
    [ "$code" = 200 ] || { warn "Portainer : réglages OAuth refusés (HTTP $code)"; return 1; }
    log "✓ Portainer : connexion via Authelia (bouton « Login with OAuth »)"
}

# Client OIDC d'Authelia (Authelia redémarré si ajouté) puis connexion
# Portainer via Authelia. $1=utilisateur Portainer (admin) $2=mot de passe
# $3=compte Authelia de l'administrateur
portainer_sso_setup() {
    local cfg="$INSTALL_DIR/authelia/configuration.yml"
    if authelia_ensure_oidc_portainer "$cfg"; then
        docker restart authelia >/dev/null 2>&1 || { warn "Redémarrez Authelia : docker restart authelia"; return 1; }
        sleep 5
    fi
    grep -q "client_id: 'portainer'" "$cfg" 2>/dev/null || { warn "Portainer : fournisseur OIDC d'Authelia absent"; return 1; }
    autoconfig_portainer_sso "$@"
}

# Crée l'administrateur Portainer. $1=utilisateur $2=mot de passe (≥12)
autoconfig_portainer() {
    local user="$1" pass="$2" code
    log "Configuration automatique de Portainer..."
    if ! wait_for_url http://localhost:9000/api/status 90; then
        warn "Portainer n'est pas prêt : créez le compte admin via un tunnel SSH (ssh -L 9000:localhost:9000 …)"
        return 1
    fi
    local body try token
    body="{\"Username\":\"$(json_escape "$user")\",\"Password\":\"$(json_escape "$pass")\"}"
    for try in 1 2; do
        # Portainer récent : jeton d'installation à usage unique, écrit dans ses
        # logs (« setup_token=… »), exigé dans l'en-tête X-Setup-Token (sinon 403)
        token=$(docker logs portainer 2>&1 | grep -o 'setup_token=[0-9a-fA-F]*' | tail -1 | cut -d= -f2)
        code=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:9000/api/users/admin/init \
            -H "Content-Type: application/json" ${token:+-H "X-Setup-Token: $token"} -d "$body") || code=000
        # 403 persistant : délai de 5 min dépassé (installation longue) ou jeton
        # périmé → redémarrage (nouveau jeton) puis nouvel essai
        [ "$try" = 1 ] && [ "$code" = 403 ] || break
        info "Portainer verrouillé (délai de 5 min ou jeton périmé) : redémarrage..."
        docker restart portainer >/dev/null 2>&1 || break
        wait_for_url http://localhost:9000/api/status 90 || break
    done
    case "$code" in
        200|204) log "✓ Compte administrateur Portainer créé ($user)" ;;
        409)     info "Portainer : un administrateur existe déjà" ;;
        *)       warn "Création admin Portainer échouée (HTTP $code) : docker restart portainer, puis dans les 5 min"
                 warn "  jeton : docker logs portainer 2>&1 | grep setup_token  (à coller dans l'écran de configuration)"
                 return 1 ;;
    esac
}

# Termine l'assistant Jellyfin et crée l'administrateur. $1=utilisateur $2=mdp
autoconfig_jellyfin() {
    local user="$1" pass="$2" code base=http://localhost:8096
    log "Configuration automatique de Jellyfin..."
    if ! wait_for_url "$base/health" 120; then
        warn "Jellyfin n'est pas prêt : terminez l'assistant sur http://<serveur>:8096"
        return 1
    fi
    # Ordre imposé par l'assistant : Configuration → User → RemoteAccess → Complete
    # Langue choisie à l'installation (lib_lang.sh), français par défaut
    local lang="fr" culture="fr-FR" country="FR"
    if declare -F seedbox_lang >/dev/null; then
        lang=$(seedbox_lang); read -r culture country <<< "$(lang_jellyfin "$lang")"
    fi
    curl -s -o /dev/null -X POST "$base/Startup/Configuration" -H "Content-Type: application/json" \
        -d "{\"UICulture\":\"$culture\",\"MetadataCountryCode\":\"$country\",\"PreferredMetadataLanguage\":\"$lang\"}" || true
    curl -s -o /dev/null "$base/Startup/User" || true
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$base/Startup/User" -H "Content-Type: application/json" \
        -d "{\"Name\":\"$(json_escape "$user")\",\"Password\":\"$(json_escape "$pass")\"}") || code=000
    curl -s -o /dev/null -X POST "$base/Startup/RemoteAccess" -H "Content-Type: application/json" \
        -d '{"EnableRemoteAccess":true,"EnableAutomaticPortMapping":false}' || true
    curl -s -o /dev/null -X POST "$base/Startup/Complete" || true
    case "$code" in
        200|204) log "✓ Compte administrateur Jellyfin créé ($user)" ;;
        *)       warn "Création admin Jellyfin échouée (HTTP $code) — terminez l'assistant sur http://<serveur>:8096"
                 return 1 ;;
    esac
}

# Scrutiny : disques derrière un contrôleur RAID matériel (LSI/Dell PERC…).
# Le système n'y voit qu'un disque virtuel sans SMART ; les disques physiques
# sont joignables par /dev/sg*. Écrit collector.yaml (disque virtuel ignoré,
# disques physiques ajoutés) s'il n'existe pas, puis lance un premier relevé
# (sinon rien avant minuit). $1 = INSTALL_DIR (défaut /opt/seedbox)
autoconfig_scrutiny() {
    local dir="${1:-/opt/seedbox}" cfg d out serials="" ignore="" devs="" type _
    cfg="$dir/scrutiny/config/collector.yaml"
    for _ in $(seq 1 30); do docker exec scrutiny true >/dev/null 2>&1 && break; sleep 2; done
    docker exec scrutiny true >/dev/null 2>&1 || { warn "Scrutiny ne répond pas : configuration des disques non faite"; return 1; }
    if [ ! -f "$cfg" ]; then
        # Disques « blocs » : virtuels (sans SMART) à ignorer, numéros de série des autres
        for d in /dev/sd? /dev/nvme?n1; do
            [ -e "$d" ] || continue
            out=$(docker exec scrutiny smartctl -i "$d" 2>/dev/null)
            if grep -qi "Virtual Disk\|lacks SMART" <<< "$out"; then
                ignore+="  - device: $d"$'\n'"    ignore: true"$'\n'
            else
                serials+=" $(sed -n 's/^Serial [Nn]umber: *//p' <<< "$out")"
            fi
        done
        # Disques physiques derrière le contrôleur (pas déjà vus en /dev/sd*)
        if [ -n "$ignore" ]; then
            for d in /dev/sg*; do
                [ -e "$d" ] || continue
                out=$(docker exec scrutiny smartctl -i "$d" 2>/dev/null)
                grep -q "SMART support is: *Enabled" <<< "$out" || continue
                grep -qi "Virtual Disk" <<< "$out" && continue
                [[ " $serials " == *" $(sed -n 's/^Serial [Nn]umber: *//p' <<< "$out") "* ]] && continue
                type=scsi; grep -q "^Device Model:" <<< "$out" && type=sat
                devs+="  - device: $d"$'\n'"    type: '$type'"$'\n'
            done
        fi
        if [ -n "$devs" ]; then
            printf 'version: 1\n# Généré par la seedbox : contrôleur RAID matériel\ndevices:\n%s%s' "$ignore" "$devs" > "$cfg"
            log "Scrutiny : disques physiques derrière le contrôleur RAID ajoutés ($(grep -c 'type:' "$cfg"))"
        fi
    fi
    # Premier relevé (ensuite : chaque nuit)
    docker exec scrutiny scrutiny-collector-metrics run >/dev/null 2>&1 \
        && log "Scrutiny : premier relevé des disques effectué" \
        || warn "Scrutiny : premier relevé en échec (docker exec scrutiny scrutiny-collector-metrics run)"
}

# Duplicati : sauvegarde « Configuration seedbox » (tout /opt/seedbox sauf les
# fichiers des utilisateurs — leur config/ est gardée —, caches, journaux,
# archives et Duplicati lui-même), chiffrée, chaque nuit à 3 h 30, rétention
# 7 jours / 4 semaines / 12 mois, vers /backups (à remplacer par une
# destination distante dans Duplicati). Créée si absente.
# $1 = INSTALL_DIR (défaut /opt/seedbox)
autoconfig_duplicati() {
    local dir="${1:-/opt/seedbox}" env pass phrase token list body at base="${DUPLICATI_URL:-http://localhost:8200}" api
    env="$dir/.env"
    pass=$(grep '^DUPLICATI_PASSWORD=' "$env" 2>/dev/null | cut -d= -f2-)
    phrase=$(grep '^DUPLICATI_BACKUP_PASSPHRASE=' "$env" 2>/dev/null | cut -d= -f2-)
    [ -n "$pass" ] && [ -n "$phrase" ] || { warn "Duplicati : secrets absents du .env"; return 1; }
    log "Configuration automatique de Duplicati..."
    api="$base/api/v1"
    wait_for_url "$base/" 120 || { warn "Duplicati ne répond pas : sauvegarde non préconfigurée"; return 1; }
    token=$(P="$pass" python3 -c 'import json,os; print(json.dumps({"Password": os.environ["P"], "RememberMe": False}))' \
        | curl -s -m 30 -X POST -H 'Content-Type: application/json' --data @- "$api/auth/login" \
        | python3 -c 'import json,sys; print(json.load(sys.stdin).get("AccessToken",""))' 2>/dev/null)
    [ -n "$token" ] || { warn "Duplicati : connexion à l'API refusée (mot de passe ?)"; return 1; }
    list=$(curl -s -m 30 -H "Authorization: Bearer $token" "$api/backups")
    if L="$list" python3 -c 'import json,os,sys
sys.exit(0 if any(b["Backup"]["Name"] == "Configuration seedbox" for b in json.loads(os.environ["L"] or "[]")) else 1)' 2>/dev/null; then
        info "Duplicati : sauvegarde « Configuration seedbox » déjà présente"
        return 0
    fi
    at=$(date -d 'tomorrow 03:30' --iso-8601=seconds)
    body=$(PH="$phrase" AT="$at" python3 -c '
import json, os, re
s = "/seedbox/"
x = lambda p: {"Include": False, "Expression": p}
filters = [x("[" + re.escape(s) + "data/users/[^/]+/(?!config/).+]"),   # fichiers des utilisateurs (config/ gardée)
           x(s + "duplicati/"), x(s + "backups/"), x(s + "jellyfin/cache/"),
           x(s + "jellyfin/config/metadata/"), x(s + "jellyfin/config/transcodes/"),
           x(s + "scrutiny/influxdb/"), x(s + "vuetorrent/"), x(s + "api/spool/"),
           x("[.*/logs/.*]"), x("*.pid")]
for i, f in enumerate(filters): f["Order"] = i
print(json.dumps({"Backup": {"ID": None, "Name": "Configuration seedbox",
    "Description": "Configuration de la seedbox (sans les fichiers des utilisateurs). Remplacez la destination locale par une destination distante.",
    "Tags": [], "TargetURL": "file:///backups/configuration-seedbox", "DBPath": None, "Sources": [s],
    "Settings": [{"Name": "encryption-module", "Value": "aes"}, {"Name": "compression-module", "Value": "zip"},
                 {"Name": "dblock-size", "Value": "50mb"}, {"Name": "passphrase", "Value": os.environ["PH"]},
                 {"Name": "retention-policy", "Value": "1W:1D,4W:1W,12M:1M"}],
    "Filters": filters, "Metadata": {}},
    "Schedule": {"Tags": [], "Repeat": "1D", "Time": os.environ["AT"], "AllowedDays": []}}))')
    if curl -s -m 30 -X POST -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
            --data "$body" "$api/backups" | grep -q '"ID"'; then
        log "✓ Duplicati : sauvegarde « Configuration seedbox » créée (chaque nuit, 3 h 30, vers /backups)"
        info "   Phrase de chiffrement (à conserver HORS du serveur pour pouvoir restaurer) :"
        info "   sudo grep DUPLICATI_BACKUP_PASSPHRASE $env"
    else
        warn "Duplicati : sauvegarde non créée"; return 1
    fi
}
