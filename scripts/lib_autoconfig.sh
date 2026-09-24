#!/bin/bash
#######################
# lib_autoconfig.sh — Création automatique des comptes administrateur
# Portainer et Jellyfin via leur API (utilisée par install.sh et add_service.sh).
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
    code=$(curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost:9000/api/users/admin/init \
        -H "Content-Type: application/json" \
        -d "{\"Username\":\"$(json_escape "$user")\",\"Password\":\"$(json_escape "$pass")\"}") || code=000
    case "$code" in
        200|204) log "✓ Compte administrateur Portainer créé ($user)" ;;
        409)     info "Portainer : un administrateur existe déjà" ;;
        *)       warn "Création admin Portainer échouée (HTTP $code) — à faire dans les minutes suivant le 1er démarrage"
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
    curl -s -o /dev/null -X POST "$base/Startup/Configuration" -H "Content-Type: application/json" \
        -d '{"UICulture":"fr-FR","MetadataCountryCode":"FR","PreferredMetadataLanguage":"fr"}' || true
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
