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


def main():
    board = load(sys.argv[1], None)
    wanted = load(sys.argv[2], [])
    state_path = sys.argv[3]
    first_pass = not os.path.exists(state_path)
    done = set()
    if not first_pass:
        with open(state_path) as f:
            done = {line.strip() for line in f if line.strip()}

    sections = [s for s in board["sections"] if s.get("kind") == "empty"]
    section = sorted(sections, key=lambda s: s.get("yOffset") or 0)[0]
    sid = section["id"]
    layouts = board["layouts"]
    items = board["items"]

    def in_section(item, layout_id):
        return next((l for l in item["layouts"] if l["layoutId"] == layout_id and l["sectionId"] == sid), None)

    def app_item(app_id):
        return next((i for i in items if i["kind"] == "app" and (i.get("options") or {}).get("appId") == app_id), None)

    order, added = [], []   # order : (élément du tableau, largeur, hauteur)
    for spec in wanted:
        existing = app_item(spec["options"].get("appId")) if spec["kind"] == "app" else None
        if existing is not None:
            order.append((existing, spec["w"], spec["h"]))
            continue
        if spec["kind"] != "app" and spec["key"] in done:
            continue
        if spec["kind"] != "app" and first_pass and any(i["kind"] == spec["kind"] for i in items):
            continue    # widget déjà mis à la main
        item = {
            "id": new_id(),
            "kind": spec["kind"],
            "options": spec.get("options") or {},
            "integrationIds": spec.get("integrationIds") or [],
            "advancedOptions": {"title": spec.get("title"), "customCssClasses": [], "borderColor": ""},
            "layouts": [],
        }
        items.append(item)
        order.append((item, spec["w"], spec["h"]))
        added.append(spec["key"])

    if not added and not first_pass:
        print(json.dumps({"save": None, "added": []}))
        return

    ordered_ids = {id(i) for i, _, _ in order}
    for layout in layouts:
        lid = layout["id"]
        grid = Grid(layout["columnCount"])
        if first_pass:
            # Éléments voulus d'abord, puis ceux ajoutés à la main (même taille)
            others = [i for i in items if id(i) not in ordered_ids and in_section(i, lid)]
            others.sort(key=lambda i: (in_section(i, lid)["yOffset"], in_section(i, lid)["xOffset"]))
            queue = order + [(i, in_section(i, lid)["width"], in_section(i, lid)["height"]) for i in others]
        else:
            for i in items:
                l = in_section(i, lid)
                if l:
                    grid.mark(l["xOffset"], l["yOffset"], l["width"], l["height"])
            queue = [(i, w, h) for i, w, h in order if not in_section(i, lid)]
        for item, w, h in queue:
            x, y, w, h = grid.place(w, h)
            item["layouts"] = [l for l in item["layouts"] if l["layoutId"] != lid]
            item["layouts"].append({"layoutId": lid, "sectionId": sid, "xOffset": x, "yOffset": y, "width": w, "height": h})

    save = {"id": board["id"], "sections": board["sections"], "items": items}
    print(json.dumps({"save": save, "added": added}))


if __name__ == "__main__":
    main()
