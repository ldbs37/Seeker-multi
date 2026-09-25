#!/bin/bash
#######################
# healthcheck.sh — Vérification complète de la seedbox
#
# Teste : Docker, validité du docker-compose, état de TOUS les conteneurs
# (running / restart-loop / health), réseau Traefik, Authelia, pare-feu,
# fail2ban, espace disque et quotas.
#
# Appelé par update.sh après une mise à jour, ou directement :
#   healthcheck.sh            # rapport complet
#   healthcheck.sh --quiet    # n'affiche que WARN/FAIL + résumé
#
# Code de sortie : 0 si aucun FAIL, 1 si au moins un FAIL.
#######################

set -uo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
COMPOSE="$INSTALL_DIR/docker-compose.yml"
ENV_FILE="$INSTALL_DIR/.env"
QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

PASS=0; WARN=0; FAIL=0
ok()   { PASS=$((PASS+1)); $QUIET || echo -e "  ${GREEN}[OK]${NC}   $1"; }
wn()   { WARN=$((WARN+1)); echo -e "  ${YELLOW}[WARN]${NC} $1"; }
ko()   { FAIL=$((FAIL+1)); echo -e "  ${RED}[FAIL]${NC} $1"; }
section() { $QUIET || echo -e "\n${BLUE}== $1 ==${NC}"; }

compose() {
    if command -v docker-compose >/dev/null 2>&1; then docker-compose "$@"
    else docker compose "$@"; fi
}

#######################
# 1) Docker
#######################
section "Docker"
if command -v docker >/dev/null 2>&1; then
    if docker info >/dev/null 2>&1; then ok "Daemon Docker actif"
    else ko "Daemon Docker injoignable (droits ? service arrêté ?)"; fi
else
    ko "Docker n'est pas installé"
fi

#######################
# 2) Validité du docker-compose
#######################
section "Configuration Docker Compose"
if [ -f "$COMPOSE" ]; then
    if ( cd "$INSTALL_DIR" && compose config -q >/dev/null 2>&1 ); then
        ok "docker-compose.yml valide"
    else
        ko "docker-compose.yml INVALIDE (compose config a échoué)"
    fi
else
    ko "docker-compose.yml introuvable ($COMPOSE)"
fi

#######################
# 3) État des conteneurs
#######################
section "Conteneurs"
if [ -f "$COMPOSE" ] && docker info >/dev/null 2>&1; then
    mapfile -t SERVICES < <(cd "$INSTALL_DIR" && compose config --services 2>/dev/null | sort)
    if [ "${#SERVICES[@]}" -eq 0 ]; then
        wn "Aucun service défini dans le compose"
    fi
    for svc in "${SERVICES[@]}"; do
        # Recherche par nom (container_name = nom du service) : fiable quelle
        # que soit la version/le wrapper compose ; repli sur "compose ps"
        cid=$(docker ps -aq --filter "name=^/${svc}\$" 2>/dev/null | head -1)
        [ -n "$cid" ] || cid=$(cd "$INSTALL_DIR" && compose ps -aq "$svc" 2>/dev/null | head -1)
        if [ -z "$cid" ]; then
            wn "$svc : aucun conteneur (non démarré)"
            continue
        fi
        status=$(docker inspect -f '{{.State.Status}}' "$cid" 2>/dev/null)
        restarts=$(docker inspect -f '{{.RestartCount}}' "$cid" 2>/dev/null)
        health=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)
        case "$status" in
            running)
                if [ "$health" = "unhealthy" ]; then
                    # Traefik n'expose pas un conteneur unhealthy (→ 404)
                    ko "$svc : running mais UNHEALTHY (ignoré par Traefik : voir docker logs $svc)"
                elif [ "${restarts:-0}" -ge 5 ]; then
                    wn "$svc : running mais ${restarts} redémarrages (instable ?)"
                else
                    ok "$svc : running${health:+ ($health)}"
                fi
                ;;
            restarting) ko "$svc : en boucle de redémarrage (RESTARTING)" ;;
            exited|dead) ko "$svc : arrêté ($status)" ;;
            *) wn "$svc : état '$status'" ;;
        esac
    done
else
    wn "Vérification des conteneurs ignorée (Docker/compose indisponible)"
fi

#######################
# 4) Traefik
#######################
section "Traefik / réseau"
USE_TRAEFIK=false
[ -f "$ENV_FILE" ] && grep -q '^USE_TRAEFIK=true' "$ENV_FILE" && USE_TRAEFIK=true
if [ "$USE_TRAEFIK" = true ]; then
    if docker network inspect traefik_proxy >/dev/null 2>&1; then ok "Réseau 'traefik_proxy' présent"
    else ko "Réseau 'traefik_proxy' MANQUANT"; fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^traefik$'; then ok "Conteneur Traefik en cours"
    else ko "Conteneur Traefik absent"; fi
    if [ -f "$INSTALL_DIR/traefik/letsencrypt/acme.json" ]; then
        perms=$(stat -c '%a' "$INSTALL_DIR/traefik/letsencrypt/acme.json" 2>/dev/null)
        [ "$perms" = "600" ] && ok "acme.json présent (permissions 600)" || wn "acme.json : permissions $perms (600 attendu)"
    else
        wn "acme.json introuvable (certificats pas encore générés ?)"
    fi
else
    ko "Installation en mode « port direct », plus pris en charge : setup_traefik.sh puis generate_traefik_labels.sh"
fi

#######################
# 5) Authelia
#######################
section "Authelia (SSO)"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^authelia$'; then
    ok "Conteneur Authelia en cours"
    if curl -fs -m 5 http://localhost:9091/api/health >/dev/null 2>&1 \
       || curl -fs -m 5 http://localhost:9091/ >/dev/null 2>&1; then
        ok "Authelia répond (localhost:9091)"
    else
        wn "Authelia ne répond pas sur localhost:9091 (démarrage en cours ?)"
    fi
    if [ -s "$INSTALL_DIR/authelia/users_database.yml" ] && grep -q '^  [^ ]' "$INSTALL_DIR/authelia/users_database.yml" 2>/dev/null; then
        ok "Base utilisateurs Authelia non vide"
    else
        wn "Base utilisateurs Authelia vide (aucun utilisateur ?)"
    fi
else
    ko "Conteneur Authelia absent"
fi

#######################
# 6) Sécurité (UFW / fail2ban)
#######################
section "Sécurité"
if command -v ufw >/dev/null 2>&1; then
    ufw status 2>/dev/null | grep -qi "Status: active" && ok "Pare-feu UFW actif" || wn "UFW installé mais inactif"
else
    wn "UFW non installé"
fi
if command -v fail2ban-client >/dev/null 2>&1; then
    if fail2ban-client status 2>/dev/null | grep -q 'sshd'; then ok "fail2ban : jail sshd active"
    else wn "fail2ban actif mais jail sshd absente"; fi
else
    wn "fail2ban non installé"
fi

#######################
# 7) Espace disque
#######################
section "Espace disque"
avail_gb=$(df -BG --output=avail "$INSTALL_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
use_pct=$(df --output=pcent "$INSTALL_DIR" 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${avail_gb:-}" ]; then
    if [ "$avail_gb" -lt 5 ]; then ko "Espace disque critique : ${avail_gb}G libres sur $(df -h "$INSTALL_DIR" | tail -1 | awk '{print $6}')"
    elif [ "${use_pct:-0}" -ge 90 ]; then wn "Disque rempli à ${use_pct}% (${avail_gb}G libres)"
    else ok "Espace disque OK (${avail_gb}G libres, ${use_pct}% utilisé)"; fi
else
    wn "Impossible de lire l'espace disque pour $INSTALL_DIR"
fi

#######################
# 8) Quotas (informatif)
#######################
section "Quotas"
QUOTA_LIB="$(dirname "$0")/lib_quota.sh"
if [ -f "$QUOTA_LIB" ]; then
    # shellcheck source=/dev/null
    source "$QUOTA_LIB"
    if quota_project_active "$INSTALL_DIR/data" 2>/dev/null; then
        ok "Quotas projet actifs sur le système de fichiers"
    else
        wn "Quotas projet NON actifs (voir enable_quotas.sh) — limites non appliquées"
    fi
else
    wn "lib_quota.sh introuvable"
fi

#######################
# Résumé
#######################
echo ""
echo -e "${BLUE}=== Résumé ===${NC}"
echo -e "  ${GREEN}OK: $PASS${NC}   ${YELLOW}WARN: $WARN${NC}   ${RED}FAIL: $FAIL${NC}"
if [ "$FAIL" -gt 0 ]; then
    echo -e "${RED}✗ Des problèmes CRITIQUES ont été détectés.${NC}"
    exit 1
elif [ "$WARN" -gt 0 ]; then
    echo -e "${YELLOW}⚠ Système fonctionnel, avec des avertissements.${NC}"
    exit 0
else
    echo -e "${GREEN}✓ Système sain.${NC}"
    exit 0
fi
