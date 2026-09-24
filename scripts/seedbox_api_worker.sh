#!/bin/bash

#######################
# seedbox_api_worker.sh — Ouvrier (hôte) de l'API libre-service
#
# Déclenché par systemd (seedbox-api-worker.path) dès qu'une demande arrive
# dans $SPOOL/requests. Chaque demande est REVALIDÉE ici (le conteneur de
# l'API n'est pas une source de confiance) puis exécutée via les scripts
# habituels (add_user_service.sh / remove_service.sh).
#
# Usage: seedbox_api_worker.sh            # traite les demandes en attente
#        seedbox_api_worker.sh --state    # régénère seulement l'état
#######################

set -u

INSTALL_DIR="/opt/seedbox"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
SPOOL="$INSTALL_DIR/api/spool"
API_UID=65534                 # utilisateur du conteneur de l'API
ALLOWED="sonarr radarr readarr bazarr prowlarr overseerr calibre"

grep -q '^SEEDBOX_API=true' "$ENV_FILE" 2>/dev/null || exit 0
[ -d "$SPOOL/requests" ] || exit 0

for lib in lib_ports lib_traefik lib_services; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || exit 1
done
warn() { echo "[WARNING] $1" >&2; }

# Les scripts appelés ne doivent pas relancer l'ouvrier (verrou déjà pris)
export SEEDBOX_API_WORKER=1

# Un seul ouvrier à la fois
exec 9>"$SPOOL/.lock"
flock 9

# Écrit un fichier JSON lisible par le conteneur (atomique)
write_json() {
    local dest="$1" content="$2" tmp
    tmp="$SPOOL/tmp/.w$$.json"
    printf '%s\n' "$content" > "$tmp"
    chown "$API_UID:$API_UID" "$tmp"; chmod 640 "$tmp"
    mv -f "$tmp" "$dest"
}

# État de tous les utilisateurs seedbox : services installés + URL
write_state() {
    local out="{" first=true u uid s svcs urls
    traefik_detect "$ENV_FILE"
    while IFS=: read -r u _ uid _; do
        [ "$uid" -ge "$SEEDBOX_UID_MIN" ] && [ "$uid" -le "$SEEDBOX_UID_MAX" ] || continue
        [ -d "$INSTALL_DIR/data/users/$u" ] || continue
        # Lues par service_url (lib_services)
        # shellcheck disable=SC2034
        USERNAME=$u
        # shellcheck disable=SC2034
        USER_ID=$uid
        svcs=""; urls=""
        for s in $ALLOWED; do
            grep -q "^  ${s}-${u}:" "$DOCKER_COMPOSE_FILE" 2>/dev/null || continue
            svcs+="${svcs:+,}\"$s\""
            urls+="${urls:+,}\"$s\":\"$(service_url "$s")\""
        done
        $first || out+=","; first=false
        out+="\"$u\":{\"services\":[${svcs}],\"urls\":{${urls}}}"
    done < /etc/passwd
    write_json "$SPOOL/state.json" "${out}}"
}

# Champ d'une demande JSON (valeurs revalidées ensuite)
req_field() {
    python3 -c 'import json,sys
try: v = json.load(open(sys.argv[1])).get(sys.argv[2], "")
except Exception: v = ""
print(v if isinstance(v, str) else "")' "$1" "$2"
}

process() {
    local f="$1" id user action service uid ok=false msg out
    id=$(basename "$f" .json)
    [[ "$id" =~ ^[a-f0-9]{32}$ ]] || { rm -f "$f"; return; }
    mv "$f" "$SPOOL/running/$id.json" || return
    f="$SPOOL/running/$id.json"
    user=$(req_field "$f" user); action=$(req_field "$f" action); service=$(req_field "$f" service)

    uid=$(id -u "$user" 2>/dev/null || echo 0)
    if ! [[ "$user" =~ ^[a-z][a-z0-9]{0,31}$ ]] || [ "$uid" -lt "$SEEDBOX_UID_MIN" ] \
       || [ "$uid" -gt "$SEEDBOX_UID_MAX" ] || [ ! -d "$INSTALL_DIR/data/users/$user" ]; then
        msg="Utilisateur invalide"; user=""   # jamais recopié tel quel
    elif [[ " $ALLOWED " != *" $service "* ]]; then
        msg="Service non autorisé"
    elif [ "$action" = add ]; then
        if out=$("$SCRIPT_DIR/add_user_service.sh" "$user" "$service" </dev/null 2>&1); then
            ok=true; msg="$service ajouté"
        else
            msg="Échec de l'ajout de $service"
        fi
    elif [ "$action" = remove ]; then
        if ! grep -q "^  ${service}-${user}:" "$DOCKER_COMPOSE_FILE"; then
            ok=true; msg="$service n'était pas installé"
        elif out=$("$SCRIPT_DIR/remove_service.sh" "${service}-${user}" </dev/null 2>&1); then
            ok=true; msg="$service retiré (données conservées)"
        else
            msg="Échec du retrait de $service"
        fi
    else
        msg="Action invalide"
    fi
    logger -t seedbox-api "user=$user action=$action service=$service ok=$ok" 2>/dev/null || true
    $ok || [ -z "${out:-}" ] || logger -t seedbox-api "$(printf '%s' "$out" | tail -5)" 2>/dev/null || true
    write_json "$SPOOL/results/$id.json" \
        "{\"user\":\"$user\",\"ok\":$ok,\"message\":\"$msg\"}"
    rm -f "$f"
}

if [ "${1:-}" != --state ]; then
    shopt -s nullglob
    # Demandes interrompues (redémarrage) : considérées en échec
    for f in "$SPOOL"/running/*.json; do
        id=$(basename "$f" .json); user=$(req_field "$f" user)
        [[ "$user" =~ ^[a-z][a-z0-9]{0,31}$ ]] || user=""
        write_json "$SPOOL/results/$id.json" "{\"user\":\"$user\",\"ok\":false,\"message\":\"Interrompu\"}"
        rm -f "$f"
    done
    for f in "$SPOOL"/requests/*; do
        case "$f" in *.json) process "$f" ;; *) rm -f "$f" ;; esac
    done
    # Ménage : résultats de plus d'un jour, fichiers temporaires abandonnés
    find "$SPOOL/results" "$SPOOL/tmp" -type f -mmin +1440 -delete 2>/dev/null
fi
write_state
exit 0
