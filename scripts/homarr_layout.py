#!/usr/bin/env python3
"""Mise en page d'un tableau de bord Homarr 1.x (utilisé par homarr_provision.sh).

Entrée : le tableau (sortie de board.getBoardByName), la liste des éléments
voulus, et le fichier d'état du tableau (clés déjà ajoutées une fois).
Sortie (JSON) : {"save": <entrée de board.saveBoard>, "added": [clés]}
ou {"save": null, "added": []} s'il n'y a rien à faire.

Élément voulu : {"key", "kind", "w", "h", "options", "integrationIds",
"title"?}. Une tuile d'appli (kind "app") est « présente » si une tuile du
tableau pointe sur la même appli ; un widget, si sa clé est dans l'état
(supprimé par l'utilisateur, il n'est donc pas recréé).

Premier passage (pas de fichier d'état) : tout le tableau est mis en page
dans l'ordre voulu (tuiles existantes réutilisées), les éléments ajoutés à la
main suivent. Ensuite : les éléments manquants sont ajoutés à la première
place libre, sans rien déplacer. Chaque disposition (bureau, mobile) est
remplie selon son nombre de colonnes.

Modèle (facultatif, variables d'environnement HOMARR_TEMPLATE, HOMARR_APPS,
HOMARR_INTEGRATIONS, HOMARR_USER ; HOMARR_FORCE=1 pour réappliquer) : tableau
d'un utilisateur enregistré par « save » (voir template_from_board). Au
premier passage (ou forcé), chaque élément reprend la place, la taille, les
réglages et le titre de son équivalent dans le modèle ; les widgets ajoutés à
la main dans le modèle sont recopiés (intégrations de l'utilisateur de même
nom). Les éléments ajoutés plus tard prennent leur place du modèle si elle est
libre.

Usage : homarr_layout.py <tableau> <voulus> <état>
        homarr_layout.py save <tableau> <applis> <intégrations> <propriétaire>
"""
import json
import os
import secrets
import string
import sys


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def new_id():
    # Même forme que les identifiants de Homarr (cuid2 : minuscule d'abord)
    alphabet = string.ascii_lowercase + string.digits
    return secrets.choice(string.ascii_lowercase) + "".join(secrets.choice(alphabet) for _ in range(23))


class Grid:
    def __init__(self, cols):
        self.cols = cols
        self.rows = []

    def _row(self, y):
        while len(self.rows) <= y:
            self.rows.append([False] * self.cols)
        return self.rows[y]

    def mark(self, x, y, w, h):
        for dy in range(h):
            row = self._row(y + dy)
            for dx in range(w):
                if 0 <= x + dx < self.cols:
                    row[x + dx] = True

    def fits(self, x, y, w, h):
        if x + w > self.cols:
            return False
        return all(not self._row(y + dy)[x + dx] for dy in range(h) for dx in range(w))

    def place(self, w, h):
        w = max(1, min(w, self.cols))
        y = 0
        while True:
            for x in range(self.cols - w + 1):
                if self.fits(x, y, w, h):
                    self.mark(x, y, w, h)
                    return x, y, w, h
            y += 1


# ---- Modèle ---------------------------------------------------------------
def base_name(name, user):
    """Nom sans le suffixe « (utilisateur) » ; (base, suffixé ?)."""
    suffix = " (%s)" % user
    if name.endswith(suffix):
        return name[:-len(suffix)], True
    return name, False


def item_keys(items, apps, user, first_layout):
    """Clé stable de chaque élément : « app:<nom sans utilisateur> » pour une
    tuile, « <type>#<n> » pour un widget (n-ième, dans l'ordre d'affichage)."""
    def pos(i):
        l = next((l for l in i["layouts"] if l["layoutId"] == first_layout), None)
        return (l["yOffset"], l["xOffset"]) if l else (10**6, 0)
    keys, count = {}, {}
    for i in sorted(items, key=pos):
        if i["kind"] == "app":
            name = apps.get((i.get("options") or {}).get("appId"), {}).get("name")
            keys[i["id"]] = "app:" + base_name(name, user)[0] if name else None
        else:
            n = count.get(i["kind"], 0)
            count[i["kind"]] = n + 1
            keys[i["id"]] = "%s#%d" % (i["kind"], n)
    return keys


def template_from_board(board, apps, integrations, owner):
    """Modèle : dispositions, et pour chaque élément de la première section
    sa clé, ses positions (par disposition), ses réglages (widgets) et ses
    intégrations (type + nom sans utilisateur)."""
    sections = [s for s in board["sections"] if s.get("kind") == "empty"]
    sid = sorted(sections, key=lambda s: s.get("yOffset") or 0)[0]["id"]
    layouts = {l["id"]: l for l in board["layouts"]}
    items = [i for i in board["items"] if any(l["sectionId"] == sid for l in i["layouts"])]
    keys = item_keys(items, apps, owner, board["layouts"][0]["id"])
    ints = {x["id"]: x for x in integrations}
    out = []
    for i in items:
        if not keys.get(i["id"]):
            continue
        entry = {"key": keys[i["id"]], "kind": i["kind"], "positions": {}}
        for l in i["layouts"]:
            if l["sectionId"] == sid and l["layoutId"] in layouts:
                lay = layouts[l["layoutId"]]
                entry["positions"][lay["name"]] = {"columnCount": lay["columnCount"], "x": l["xOffset"],
                                                   "y": l["yOffset"], "w": l["width"], "h": l["height"]}
        if i["kind"] == "app":
            name = apps[i["options"]["appId"]]["name"]
            base, own = base_name(name, owner)
            entry["app"] = {"base": base, "own": own, "id": i["options"]["appId"]}
            entry["options"] = {k: v for k, v in (i.get("options") or {}).items() if k != "appId"}
        else:
            entry["options"] = i.get("options") or {}
            entry["title"] = (i.get("advancedOptions") or {}).get("title")
            refs = []
            for iid in i.get("integrationIds") or []:
                x = ints.get(iid)
                if x:
                    base, own = base_name(x["name"], owner)
                    refs.append({"kind": x["kind"], "base": base, "own": own})
            entry["integrations"] = refs
        out.append(entry)
    return {"owner": owner, "layouts": [{"name": l["name"], "columnCount": l["columnCount"]}
                                        for l in board["layouts"]], "items": out}


def template_position(tpl, layout, key):
    """Place du modèle pour l'élément <key> dans la disposition <layout>
    (même nom, sinon même nombre de colonnes)."""
    if not tpl:
        return None
    entry = next((e for e in tpl["items"] if e["key"] == key), None)
    if not entry:
        return None
    p = entry["positions"].get(layout["name"])
    if p is None:
        p = next((q for q in entry["positions"].values() if q["columnCount"] == layout["columnCount"]), None)
    if p is None or p["x"] + p["w"] > layout["columnCount"]:
        return None
    return p


def main():
    if sys.argv[1] == "save":
        board = load(sys.argv[2], None)
        apps = {a["id"]: a for a in load(sys.argv[3], [])}
        print(json.dumps(template_from_board(board, apps, load(sys.argv[4], []), sys.argv[5])))
        return

    board = load(sys.argv[1], None)
    wanted = load(sys.argv[2], [])
    state_path = sys.argv[3]
    env = os.environ.get
    tpl = load(env("HOMARR_TEMPLATE", ""), None) if env("HOMARR_TEMPLATE") else None
    apps = {a["id"]: a for a in load(env("HOMARR_APPS", ""), [])} if env("HOMARR_APPS") else {}
    ints = load(env("HOMARR_INTEGRATIONS", ""), []) if env("HOMARR_INTEGRATIONS") else []
    user = env("HOMARR_USER", "")
    force = env("HOMARR_FORCE") == "1" and tpl is not None
    first_pass = force or not os.path.exists(state_path)
    done = set()
    if not first_pass:
        with open(state_path) as f:
            done = {line.strip() for line in f if line.strip()}
    tentries = {e["key"]: e for e in tpl["items"]} if tpl else {}

    sections = [s for s in board["sections"] if s.get("kind") == "empty"]
    section = sorted(sections, key=lambda s: s.get("yOffset") or 0)[0]
    sid = section["id"]
    layouts = board["layouts"]
    items = board["items"]
    ekeys = item_keys(items, apps, user, layouts[0]["id"])

    def in_section(item, layout_id):
        return next((l for l in item["layouts"] if l["layoutId"] == layout_id and l["sectionId"] == sid), None)

    def app_item(app_id):
        return next((i for i in items if i["kind"] == "app" and (i.get("options") or {}).get("appId") == app_id), None)

    def keyed_item(key):
        return next((i for i in items if ekeys.get(i["id"]) == key), None)

    def new_item(kind, options, integration_ids, title):
        item = {"id": new_id(), "kind": kind, "options": options, "integrationIds": integration_ids,
                "advancedOptions": {"title": title, "customCssClasses": [], "borderColor": ""}, "layouts": []}
        items.append(item)
        return item

    def styled(item, key, integration_ids=None):
        """Réglages et titre du modèle (widgets) ; l'appli d'une tuile reste la sienne."""
        e = tentries.get(key)
        if not e:
            return
        if item["kind"] == "app":
            item["options"] = {**e.get("options", {}), "appId": item["options"]["appId"]}
        else:
            item["options"] = e.get("options") or {}
            item["advancedOptions"] = {**(item.get("advancedOptions") or {}), "title": e.get("title")}
            if integration_ids is not None:
                item["integrationIds"] = integration_ids

    order, added, count = [], [], {}   # order : (élément, largeur, hauteur, clé)
    for spec in wanted:
        if spec["kind"] == "app":
            name = apps.get(spec["options"].get("appId"), {}).get("name")
            key = "app:" + base_name(name, user)[0] if name else None
        else:
            n = count.get(spec["kind"], 0)
            count[spec["kind"]] = n + 1
            key = "%s#%d" % (spec["kind"], n)
        if spec["kind"] == "app":
            existing = app_item(spec["options"].get("appId"))
            if existing is not None:
                if first_pass and tpl:
                    styled(existing, key)
                order.append((existing, spec["w"], spec["h"], key))
                continue
        else:
            if spec["key"] in done:
                continue
            existing = keyed_item(key) if first_pass else None
            if existing is not None and existing["kind"] == spec["kind"]:
                if tpl:     # widget du même type déjà présent : repris, au style du modèle
                    styled(existing, key, spec.get("integrationIds") or existing.get("integrationIds"))
                    order.append((existing, spec["w"], spec["h"], key))
                    added.append(spec["key"])
                continue    # (sans modèle : widget mis à la main, laissé tel quel)
        item = new_item(spec["kind"], spec.get("options") or {}, spec.get("integrationIds") or [], spec.get("title"))
        styled(item, key, spec.get("integrationIds") or [])
        order.append((item, spec["w"], spec["h"], key))
        added.append(spec["key"])

    # Éléments ajoutés à la main dans le modèle : recopiés (intégrations de
    # l'utilisateur de même nom ; tuiles d'applis communes seulement)
    if first_pass and tpl:
        keyed = {k for _, _, _, k in order}
        by_name = {x["name"]: x for x in ints}
        for e in tpl["items"]:
            if e["key"] in keyed or e["key"] in count_keys(wanted_kinds(wanted)):
                continue
            existing = keyed_item(e["key"])
            if e["kind"] == "app":
                a = e["app"]
                if a["own"] or a["base"] in ("Serveur (admin)", "Jellyfin") or a["id"] not in apps:
                    continue
                item = existing or new_item("app", {}, [], None)
                item["options"] = {**e.get("options", {}), "appId": a["id"]}
            else:
                ids = []
                for r in e.get("integrations", []):
                    x = by_name.get(r["base"] + (" (%s)" % user if r["own"] else ""))
                    if x and x["kind"] == r["kind"]:
                        ids.append(x["id"])
                if e.get("integrations") and not ids:
                    continue
                item = existing if existing is not None and existing["kind"] == e["kind"] else \
                    new_item(e["kind"], {}, [], None)
                styled(item, e["key"], ids)
            first = next(iter(e["positions"].values()))
            order.append((item, first["w"], first["h"], e["key"]))

    if not added and not first_pass:
        # Rien de nouveau : seuls des éléments sans place (nouvelle disposition)
        if not any(not in_section(i, l["id"]) for i, _, _, _ in order for l in layouts):
            print(json.dumps({"save": None, "added": []}))
            return

    ordered_ids = {id(i) for i, _, _, _ in order}
    for layout in layouts:
        lid = layout["id"]
        grid = Grid(layout["columnCount"])
        if first_pass:
            # Éléments voulus d'abord (place du modèle s'il y en a), puis ceux
            # ajoutés à la main (même taille)
            others = [i for i in items if id(i) not in ordered_ids and in_section(i, lid)]
            others.sort(key=lambda i: (in_section(i, lid)["yOffset"], in_section(i, lid)["xOffset"]))
            queue = order + [(i, in_section(i, lid)["width"], in_section(i, lid)["height"], None) for i in others]
        else:
            for i in items:
                l = in_section(i, lid)
                if l:
                    grid.mark(l["xOffset"], l["yOffset"], l["width"], l["height"])
            queue = [q for q in order if not in_section(q[0], lid)]
        # Places du modèle en premier (dans l'ordre du modèle), puis le reste
        pinned = [(q, template_position(tpl, layout, q[3])) for q in queue if q[3]]
        pinned = sorted([(q, p) for q, p in pinned if p], key=lambda qp: (qp[1]["y"], qp[1]["x"]))
        placed = set()
        for (item, _, _, _), p in pinned:
            if grid.fits(p["x"], p["y"], p["w"], p["h"]):
                grid.mark(p["x"], p["y"], p["w"], p["h"])
                item["layouts"] = [l for l in item["layouts"] if l["layoutId"] != lid]
                item["layouts"].append({"layoutId": lid, "sectionId": sid, "xOffset": p["x"], "yOffset": p["y"],
                                        "width": p["w"], "height": p["h"]})
                placed.add(id(item))
        for item, w, h, key in queue:
            if id(item) in placed:
                continue
            p = template_position(tpl, layout, key) if key else None
            if p:
                w, h = p["w"], p["h"]
            x, y, w, h = grid.place(w, h)
            item["layouts"] = [l for l in item["layouts"] if l["layoutId"] != lid]
            item["layouts"].append({"layoutId": lid, "sectionId": sid, "xOffset": x, "yOffset": y, "width": w, "height": h})

    save = {"id": board["id"], "sections": board["sections"], "items": items}
    print(json.dumps({"save": save, "added": added}))


def wanted_kinds(wanted):
    return [s["kind"] for s in wanted if s["kind"] != "app"]


def count_keys(kinds):
    """Clés « <type>#<n> » des widgets voulus (gérés par homarr_provision.sh)."""
    out, count = set(), {}
    for k in kinds:
        n = count.get(k, 0)
        count[k] = n + 1
        out.add("%s#%d" % (k, n))
    return out


if __name__ == "__main__":
    main()
