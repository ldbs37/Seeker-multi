#!/usr/bin/env python3
"""
API libre-service de la seedbox (mode Traefik uniquement).

Chaque utilisateur ajoute/retire ses services optionnels et redémarre ses
services depuis https://<user>.<domaine>/seedbox-api/ (tuile « Mes
services » sur son tableau de bord Homarr).

Sécurité :
  - Tourne dans un conteneur SANS privilège (pas de socket Docker, rootfs en
    lecture seule) : elle ne fait que déposer des demandes dans /spool. Un
    ouvrier côté hôte (seedbox_api_worker.sh) les revalide puis les exécute.
  - Joignable uniquement via Traefik derrière Authelia : l'identité vient de
    l'en-tête Remote-User posé par Authelia ; Traefik ajoute une clé secrète
    (X-Seedbox-Api-Key) que les autres conteneurs ne connaissent pas.
  - Un utilisateur ne gère que SES services (Remote-User == sous-domaine).
  - Anti-CSRF : les POST exigent du JSON + l'en-tête X-Requested-With.

Bibliothèque standard uniquement.
"""

import hmac
import json
import os
import re
import secrets
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SPOOL = os.environ.get("SPOOL_DIR", "/spool")
API_KEY = os.environ.get("SEEDBOX_API_KEY", "")
DOMAIN = os.environ.get("DOMAIN", "")
PREFIX = "/seedbox-api"
PORT = int(os.environ.get("PORT", "8000"))

SERVICES = {
    "sonarr": "Séries TV",
    "radarr": "Films",
    "readarr": "Livres",
    "bazarr": "Sous-titres",
    "prowlarr": "Indexeurs",
    "seerr": "Demandes de films/séries (connexion Jellyfin)",
    "calibre": "Bibliothèque e-books (Calibre-Web)",
}
# Plus proposés à l'ajout ; retirables s'ils sont installés
RETIRED = {"readarr", "bazarr"}
# Services de base : redémarrage seulement (ni ajout ni retrait)
BASE = {
    "qbittorrent": "Téléchargements (qBittorrent)",
    "filebrowser": "Fichiers",
    "flaresolverr": "FlareSolverr (pour Prowlarr)",
}
# Services partagés (un conteneur pour tous) : redémarrage réservé aux admins
SHARED = {
    "jellyfin": "Films et séries (Jellyfin)",
    "stirling-pdf": "Outils PDF (Stirling-PDF)",
}
USER_RE = re.compile(r"^[a-z][a-z0-9]{0,31}$")
JOB_RE = re.compile(r"^[a-f0-9]{32}$")

if len(API_KEY) < 32:
    raise SystemExit("SEEDBOX_API_KEY absente ou trop courte")


def read_json(path, default):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def pending_job(user):
    """Demande en attente/en cours de l'utilisateur (une seule à la fois)."""
    for d in ("requests", "running"):
        try:
            names = os.listdir(os.path.join(SPOOL, d))
        except OSError:
            continue
        for n in names:
            if n.endswith(".json") and read_json(os.path.join(SPOOL, d, n), {}).get("user") == user:
                return n[:-5]
    return None


PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Mes services</title>
<style>
:root{--bg:#f6f7f9;--fg:#1d2330;--card:#fff;--mut:#6b7280;--acc:#2563eb;--bad:#dc2626;--ok:#16a34a}
@media (prefers-color-scheme:dark){:root{--bg:#111418;--fg:#e6e8eb;--card:#1b2027;--mut:#9aa3ad;--acc:#60a5fa;--bad:#f87171;--ok:#4ade80}}
body{margin:0;font:15px/1.5 system-ui,sans-serif;background:var(--bg);color:var(--fg)}
main{max-width:720px;margin:0 auto;padding:24px 16px}
h1{font-size:22px;margin:0 0 4px} p{color:var(--mut);margin:0 0 20px}
.row{display:flex;align-items:center;gap:12px;background:var(--card);border-radius:10px;padding:12px 14px;margin-bottom:8px}
.row b{flex:1} .row small{display:block;color:var(--mut);font-weight:400}
button{border:0;border-radius:8px;padding:8px 14px;font:inherit;cursor:pointer;background:var(--acc);color:#fff}
button.rm{background:transparent;color:var(--bad);border:1px solid var(--bad)}
button.rs{background:transparent;color:var(--acc);border:1px solid var(--acc)}
.dot{width:10px;height:10px;border-radius:50%;flex:none;background:var(--mut)}
.dot.running{background:var(--ok)} .dot.unhealthy,.dot.restarting{background:#d97706}
.dot.exited,.dot.dead,.dot.absent{background:var(--bad)}
h2{font-size:16px;margin:24px 0 8px}
button:disabled{opacity:.5;cursor:default}
a{color:var(--acc)} #msg{min-height:1.5em;margin:12px 0;font-weight:600}
</style></head><body><main>
<h1>Mes services</h1>
<p>Redémarrez un service qui ne répond plus, ajoutez ou retirez vos
applications. Retirer un service conserve ses données.</p>
<div id="msg"></div><div id="list">Chargement…</div>
<p style="margin-top:20px"><a href="/">← Retour au tableau de bord</a></p>
</main><script>
const api=p=>fetch('PREFIX'+p,{headers:{'X-Requested-With':'fetch'}}).then(r=>r.json());
const msg=(t,c)=>{const m=document.getElementById('msg');m.textContent=t;m.style.color=c||''};
const ST={running:'actif',unhealthy:'ne répond pas',restarting:'redémarre',exited:'arrêté',dead:'arrêté',absent:'absent',created:'arrêté'};
function row(l,s,label,d,on,canAdd,canRs=true){
  const r=document.createElement('div');r.className='row';
  if(on){const dot=document.createElement('span');const st=d.status[s]||'absent';dot.className='dot '+st;dot.title=ST[st]||st;r.appendChild(dot)}
  const b=document.createElement('b');b.textContent=s;const sm=document.createElement('small');
  sm.textContent=label+(on?' · '+(ST[d.status[s]]||d.status[s]||'?'):'');b.appendChild(sm);r.appendChild(b);
  if(on&&d.urls[s]){const a=document.createElement('a');a.href=d.urls[s];a.textContent='Ouvrir';r.appendChild(a)}
  const btn=(t,c,f)=>{const x=document.createElement('button');x.textContent=t;if(c)x.className=c;x.disabled=!!d.pending;x.onclick=f;r.appendChild(x)};
  if(on&&canRs)btn('Redémarrer','rs',()=>act('restart',s));
  if(canAdd)btn(on?'Retirer':'Ajouter',on?'rm':'',()=>act(on?'remove':'add',s));
  l.appendChild(r)}
async function load(){
  const d=await api('/services');const l=document.getElementById('list');l.textContent='';
  const h=t=>{const x=document.createElement('h2');x.textContent=t;l.appendChild(x)};
  if(Object.keys(d.base).length){h('Services de base');for(const [s,label] of Object.entries(d.base))row(l,s,label,d,true,false)}
  if(Object.keys(d.shared||{}).length){h('Services partagés');for(const [s,label] of Object.entries(d.shared))row(l,s,label,d,true,false,d.admin)}
  h('Applications');
  for(const [s,label] of Object.entries(d.catalog))row(l,s,label,d,d.installed.includes(s),true);
  if(d.pending){msg('Opération en cours…');poll(d.pending)}
}
async function act(action,s){
  if(action==='remove'&&!confirm('Retirer '+s+' ? (les données sont conservées)'))return;
  if(action==='restart'&&!confirm('Redémarrer '+s+' ?'))return;
  const r=await fetch('PREFIX/services',{method:'POST',headers:{'Content-Type':'application/json','X-Requested-With':'fetch'},body:JSON.stringify({action,service:s})});
  const d=await r.json();if(!r.ok){msg(d.error||'Erreur','var(--bad)');return}
  msg(action==='restart'?'Redémarrage en cours…':'Opération en cours (peut prendre quelques minutes)…');document.querySelectorAll('button').forEach(b=>b.disabled=true);poll(d.job)}
async function poll(id){
  const d=await api('/jobs/'+id);
  if(d.status==='done'){msg(d.ok?'Terminé ✓':'Échec : '+(d.message||'voir l\\'administrateur'),d.ok?'var(--ok)':'var(--bad)');load();return}
  setTimeout(()=>poll(id),3000)}
load();
</script></body></html>
""".replace("PREFIX", PREFIX)


class Handler(BaseHTTPRequestHandler):
    server_version = "seedbox-api"
    sys_version = ""

    def log_message(self, fmt, *args):  # journal minimal (stdout du conteneur)
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

    # ---- helpers -------------------------------------------------------
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'unsafe-inline'; "
                         "style-src 'unsafe-inline'; connect-src 'self'")
        self.end_headers()
        self.wfile.write(data)

    def auth(self):
        """Utilisateur authentifié, ou None (réponse d'erreur déjà envoyée)."""
        key = self.headers.get("X-Seedbox-Api-Key", "")
        if not hmac.compare_digest(key.encode(), API_KEY.encode()):
            self.send(403, {"error": "Accès direct interdit"})
            return None
        user = self.headers.get("Remote-User", "")
        host = self.headers.get("Host", "").split(":")[0].lower()
        if not USER_RE.match(user) or host != f"{user}.{DOMAIN}":
            self.send(403, {"error": "Utilisateur non autorisé pour ce domaine"})
            return None
        return user

    def route(self):
        path = self.path.split("?", 1)[0]
        if not path.startswith(PREFIX):
            return None
        return path[len(PREFIX):] or "/"

    # ---- GET -----------------------------------------------------------
    def do_GET(self):
        sub = self.route()
        if sub is None:
            return self.send(404, {"error": "Introuvable"})
        user = self.auth()
        if not user:
            return
        if sub == "/":
            return self.send(200, PAGE.encode(), "text/html")
        if sub == "/services":
            state = read_json(os.path.join(SPOOL, "state.json"), {}).get(user, {})
            installed = [s for s in state.get("services", []) if s in SERVICES]
            base = [s for s in state.get("base", []) if s in BASE]
            shared = [s for s in state.get("shared", []) if s in SHARED]
            urls = {s: u for s, u in state.get("urls", {}).items() if s in SERVICES or s in BASE or s in SHARED}
            status = {s: v for s, v in state.get("status", {}).items() if s in SERVICES or s in BASE or s in SHARED}
            catalog = {s: d for s, d in SERVICES.items() if s not in RETIRED or s in installed}
            return self.send(200, {"catalog": catalog, "installed": installed,
                                   "base": {s: BASE[s] for s in base},
                                   "shared": {s: SHARED[s] for s in shared},
                                   "admin": state.get("admin") is True, "urls": urls,
                                   "status": status, "pending": pending_job(user)})
        if sub.startswith("/jobs/"):
            job = sub[6:]
            if not JOB_RE.match(job):
                return self.send(400, {"error": "Identifiant invalide"})
            res = read_json(os.path.join(SPOOL, "results", job + ".json"), None)
            if res is not None:
                if res.get("user") != user:
                    return self.send(404, {"error": "Introuvable"})
                return self.send(200, {"status": "done", "ok": res.get("ok", False),
                                       "message": res.get("message", "")})
            for d in ("requests", "running"):
                req = read_json(os.path.join(SPOOL, d, job + ".json"), None)
                if req is not None:
                    if req.get("user") != user:
                        return self.send(404, {"error": "Introuvable"})
                    return self.send(200, {"status": "pending"})
            return self.send(404, {"error": "Introuvable"})
        return self.send(404, {"error": "Introuvable"})

    # ---- POST ----------------------------------------------------------
    def do_POST(self):
        sub = self.route()
        if sub != "/services":
            return self.send(404, {"error": "Introuvable"})
        user = self.auth()
        if not user:
            return
        # Anti-CSRF : un formulaire d'un autre site ne peut envoyer ni JSON
        # ni en-tête personnalisé sans pré-vérification CORS (refusée)
        if (not self.headers.get("Content-Type", "").startswith("application/json")
                or not self.headers.get("X-Requested-With")):
            return self.send(400, {"error": "Requête invalide"})
        try:
            length = min(int(self.headers.get("Content-Length", "0")), 4096)
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.send(400, {"error": "JSON invalide"})
        action, service = body.get("action"), body.get("service")
        if not ((action in ("add", "remove") and service in SERVICES
                 and not (action == "add" and service in RETIRED))
                or (action == "restart" and (service in SERVICES or service in BASE))
                or (action == "restart" and service in SHARED
                    and read_json(os.path.join(SPOOL, "state.json"), {}).get(user, {}).get("admin") is True)):
            return self.send(400, {"error": "Action ou service non autorisé"})
        if pending_job(user):
            return self.send(409, {"error": "Une opération est déjà en cours"})
        job = secrets.token_hex(16)
        req = {"user": user, "action": action, "service": service, "time": int(time.time())}
        tmp = os.path.join(SPOOL, "tmp", job + ".tmp")  # hors de requests/ (surveillé)
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(req, f)
        os.rename(tmp, os.path.join(SPOOL, "requests", job + ".json"))  # atomique
        return self.send(202, {"job": job})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
