#!/bin/bash
#######################
# lib_autoconfig.sh — Création automatique des comptes administrateur
# Portainer et Jellyfin via leur API, disques de Scrutiny (utilisée par
# install.sh et add_service.sh).
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
