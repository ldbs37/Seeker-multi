#!/bin/bash
#######################
# torrent_cleanup.sh — Ménage des torrents de Radarr / Sonarr dans
# qBittorrent (chaque utilisateur), toutes les 5 minutes (minuteur systemd).
# On ne supprime un film ou une série qu'à un endroit : Radarr / Sonarr.
#
# Seuls les torrents des catégories de Radarr / Sonarr, terminés, dont plus
# aucun fichier n'est dans la bibliothèque (lien dur disparu), sont touchés :
# - « doublon » : le film / l'épisode est toujours dans Radarr / Sonarr avec
#   un autre fichier (mise à niveau) → partagé 7 jours (pour le tracker),
#   puis supprimé avec ses fichiers ;
# - « supprimé » : le film / la série / l'épisode a été supprimé dans Radarr /
#   Sonarr → supprimé avec ses fichiers dès 72 h de partage atteintes
#   (tout de suite si déjà atteintes).
# Jamais touchés : torrents encore dans la bibliothèque (partage sans
# limite), en attente d'import dans Radarr / Sonarr (file d'attente), et
# torrents ajoutés à la main (autre catégorie ou aucune, ou catégorie de
# Radarr / Sonarr mais jamais importés). Radarr / Sonarr effacent
# l'historique d'un média supprimé : les torrents déjà vus importés sont
# retenus dans $INSTALL_DIR/torrent_cleanup/<user>.json.
# Étiquettes « doublon » / « supprimé » visibles dans qBittorrent en
# attendant la suppression. Pas de corbeille : suppression définitive.
#
# Réglages (.env) : CLEANUP_DUPLICATE_HOURS (168), CLEANUP_DELETED_HOURS (72).
# Usage: torrent_cleanup.sh [--dry-run] [utilisateur...]
#        torrent_cleanup.sh --install-timer
#######################

set -u

INSTALL_DIR="${INSTALL_DIR:-/opt/seedbox}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$INSTALL_DIR/.env"
DOCKER_COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"

for lib in lib_ports lib_traefik lib_services lib_homarr lib_arr; do
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/$lib.sh" || exit 1
done

# Minuteur systemd (idempotent)
cleanup_timer_ensure() {
    command -v systemctl >/dev/null 2>&1 || return 0
    cat > /etc/systemd/system/seedbox-torrent-cleanup.service << EOF
[Unit]
Description=Seedbox - ménage des torrents Radarr / Sonarr (doublons, médias supprimés)
After=docker.service

[Service]
Type=oneshot
ExecStart=$SCRIPT_DIR/torrent_cleanup.sh
EOF
    cat > /etc/systemd/system/seedbox-torrent-cleanup.timer << 'EOF'
[Unit]
Description=Seedbox - ménage des torrents Radarr / Sonarr

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 && systemctl enable --now seedbox-torrent-cleanup.timer >/dev/null 2>&1 || true
}

_env_hours() {
    local v
    v=$(sed -n "s/^$1=\([0-9]\+\)$/\1/p" "$ENV_FILE" 2>/dev/null | tail -1)
    echo "${v:-$2}"
}

# Adresse du conteneur $1 (premier réseau)
_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'; }

# Ménage des torrents de $1
cleanup_user() {
    local user="$1" conf qkey qip svc url key arrs=""
    conf="$INSTALL_DIR/data/users/$user/config/qbittorrent/qBittorrent/qBittorrent.conf"
    qkey=$(sed -n 's/^WebUI\\APIKey=\(qbt_[A-Za-z0-9]\{28\}\)$/\1/p' "$conf" 2>/dev/null | head -1)
    qip=$(_ip "qbittorrent-$user")
    [ -n "$qkey" ] && [ -n "$qip" ] || return 0
    for svc in radarr sonarr; do
        grep -q "^  $svc-$user:" "$DOCKER_COMPOSE_FILE" 2>/dev/null || continue
        url=$(arr_api_url "$svc" "$user") || continue
        key=$(sed -n 's|.*<ApiKey>\([0-9a-fA-F]\{32\}\)</ApiKey>.*|\1|p' "$INSTALL_DIR/$svc/$user/config.xml" 2>/dev/null | head -1)
        [ -n "$key" ] && arrs+="$svc $url $key"$'\n'
    done
    [ -n "$arrs" ] || return 0
    QB="http://$qip:8080" QK="$qkey" ARRS="$arrs" USER_DIR="$INSTALL_DIR/data/users/$user" \
    DUP_H="$(_env_hours CLEANUP_DUPLICATE_HOURS 168)" DEL_H="$(_env_hours CLEANUP_DELETED_HOURS 72)" \
    DRY="$DRY" U="$user" MEM="$INSTALL_DIR/torrent_cleanup/$user.json" python3 << 'PY'
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

QB, QK, U = os.environ["QB"], os.environ["QK"], os.environ["U"]
DUP, DEL = int(os.environ["DUP_H"]) * 3600, int(os.environ["DEL_H"]) * 3600
DRY = os.environ["DRY"] == "1"
TAG_DUP, TAG_DEL = "doublon", "supprimé"

def http(url, headers, data=None):
    req = urllib.request.Request(url, headers=headers,
                                 data=urllib.parse.urlencode(data).encode() if data is not None else None)
    with urllib.request.urlopen(req, timeout=30) as r:
        body = r.read()
    return json.loads(body) if body[:1] in (b"[", b"{") else None

def qb(path, data=None):
    return http(QB + "/api/v2/" + path, {"Authorization": "Bearer " + QK}, data)

class Arr:
    def __init__(self, svc, url, key):
        self.svc, self.url, self.key = svc, url, key
    def get(self, path, **q):
        try:
            return http(self.url + path + ("?" + urllib.parse.urlencode(q, doseq=True) if q else ""),
                        {"X-Api-Key": self.key})
        except urllib.error.HTTPError as e:
            if e.code == 404:
                return None
            raise
    def category(self):
        field = "movieCategory" if self.svc == "radarr" else "tvCategory"
        for c in self.get("/downloadclient") or []:
            if c.get("implementation") == "QBittorrent" and c.get("enable"):
                for f in c["fields"]:
                    if f["name"] == field and f.get("value"):
                        return f["value"]
        return None
    def queued(self):
        # Téléchargements de Radarr / Sonarr pas encore importés
        q = self.get("/queue", pageSize=2000) or {}
        return {(r.get("downloadId") or "").upper() for r in q.get("records", [])}
    def state(self, h):
        """doublon | supprimé | None (historique vide : inconnu, ou média
        supprimé, qui efface son historique)"""
        recs = (self.get("/history", downloadId=h.upper(), pageSize=200) or {}).get("records", [])
        if self.svc == "radarr":
            ids = {r["movieId"] for r in recs if r.get("movieId")}
            items = [self.get("/movie/%d" % i) for i in ids]
        else:
            ids = {r["episodeId"] for r in recs if r.get("episodeId")}
            items = [self.get("/episode/%d" % i) for i in ids]
        if not recs:
            return None
        return TAG_DUP if any(it and it.get("hasFile") for it in items) else TAG_DEL

def linked(t):
    """Au moins un fichier encore lié (bibliothèque). None : fichiers introuvables."""
    files = qb("torrents/files?" + urllib.parse.urlencode({"hash": t["hash"]})) or []
    save = t["save_path"].rstrip("/")
    if not save.startswith("/data"):
        return None
    base = os.environ["USER_DIR"] + save[len("/data"):]
    seen = False
    for f in files:
        p = os.path.join(base, f["name"])
        try:
            st = os.stat(p)
        except OSError:
            continue
        seen = True
        if st.st_nlink > 1:
            return True
    return False if seen else None

def settag(t, tag):
    cur = {x.strip() for x in t["tags"].split(",") if x.strip()}
    for old in {TAG_DUP, TAG_DEL} & cur - {tag}:
        DRY or qb("torrents/removeTags", {"hashes": t["hash"], "tags": old})
    if tag and tag not in cur:
        DRY or qb("torrents/addTags", {"hashes": t["hash"], "tags": tag})

# Torrents déjà vus importés ou connus de Radarr / Sonarr : sans historique
# ensuite, leur média a été supprimé ; les autres (ajoutés à la main) ne
# sont jamais touchés
MEM = os.environ["MEM"]
try:
    known = set(json.load(open(MEM)))
except (OSError, ValueError):
    known = set()
present = set()

arrs = []
for line in os.environ["ARRS"].strip().splitlines():
    a = Arr(*line.split())
    try:
        cat = a.category()
        if cat:
            arrs.append((a, cat, a.queued()))
    except Exception as e:
        print(f"{U} : {a.svc} injoignable ({e}), ignoré", file=sys.stderr)

now = time.time()
for a, cat, queued in arrs:
    for t in qb("torrents/info?" + urllib.parse.urlencode({"category": cat})) or []:
        present.add(t["hash"])
        if t["progress"] < 1 or t["hash"].upper() in queued:
            settag(t, None); continue
        lk = linked(t)
        if lk:
            known.add(t["hash"])
        if lk is not False:
            settag(t, None); continue
        try:
            st = a.state(t["hash"])
        except Exception as e:
            print(f"{U} : {t['name']} : {a.svc} injoignable ({e})", file=sys.stderr); continue
        if st:
            known.add(t["hash"])
        elif t["hash"] in known:
            st = TAG_DEL
        else:
            settag(t, None); continue
        limit = DUP if st == TAG_DUP else DEL
        seeded = t.get("seeding_time", 0)
        # Arrêté : le temps de partage n'avance plus, on compte depuis la fin
        if t["state"].startswith(("stopped", "paused")) and t.get("completion_on", 0) > 0:
            seeded = max(seeded, now - t["completion_on"])
        if seeded >= limit:
            print(f"{U} : {t['name']} ({st}, {cat}) supprimé de qBittorrent avec ses fichiers"
                  + (" [simulation]" if DRY else ""))
            DRY or qb("torrents/delete", {"hashes": t["hash"], "deleteFiles": "true"})
        else:
            settag(t, st)

if not DRY and arrs:
    os.makedirs(os.path.dirname(MEM), exist_ok=True)
    tmp = MEM + ".tmp"
    json.dump(sorted(known & present), open(tmp, "w"))
    os.replace(tmp, MEM)
PY
}

[[ $EUID -eq 0 ]] || { echo "Ce script doit être exécuté en tant que root" >&2; exit 1; }
[ "${1:-}" = --install-timer ] && { cleanup_timer_ensure; exit 0; }
DRY=0; [ "${1:-}" = --dry-run ] && { DRY=1; shift; }
[ -f "$DOCKER_COMPOSE_FILE" ] || exit 0
USERS="$*"
[ -n "$USERS" ] || USERS=$(sed -n 's/^  qbittorrent-\([a-z_][a-z0-9_-]*\):$/\1/p' "$DOCKER_COMPOSE_FILE")
RC=0
for u in $USERS; do cleanup_user "$u" || RC=1; done
exit $RC
