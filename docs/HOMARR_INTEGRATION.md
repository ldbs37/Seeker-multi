# Homarr et API libre-service des utilisateurs

## Tableau de bord Homarr

Chaque utilisateur a son Homarr (`https://<user>.votre-domaine.com/` en mode
Traefik, port `20001`+ en mode direct) généré par `configure_homarr.sh` : il
liste automatiquement ses services et est régénéré à chaque ajout/retrait.

```bash
sudo ./scripts/configure_homarr.sh <user>   # régénération manuelle
```

## API libre-service (mode Traefik)

Permet à chaque utilisateur d'**ajouter ou retirer ses services optionnels
lui-même**, sans SSH ni intervention de l'admin, depuis la page
`https://<user>.votre-domaine.com/seedbox-api/` (lien « ➕ Ajouter / retirer
des services » sur son Homarr).

Services proposés : Sonarr, Radarr, Readarr, Bazarr, Prowlarr, Overseerr,
Calibre-Web. qBittorrent, Homarr et Filebrowser (services de base) ne sont
pas concernés. Retirer un service **conserve ses données**.

### Activation

```bash
sudo /opt/seedbox/scripts/setup_api.sh             # activer / mettre à jour
sudo /opt/seedbox/scripts/setup_api.sh --disable   # désactiver
```

Ou : `sudo ./menu.sh` → **Traefik & SSO** → **API libre-service**.

Prérequis : mode Traefik + Authelia (c'est Authelia qui identifie
l'utilisateur ; en mode port direct l'API n'est pas disponible).

### Architecture

```
Navigateur ──HTTPS──► Traefik ──► Authelia (forward-auth : qui est-ce ?)
                        │  ajoute Remote-User (Authelia) + clé secrète
                        ▼
              conteneur seedbox-api  (aucun privilège)
                        │  dépose une demande JSON
                        ▼
         /opt/seedbox/api/spool/requests/
                        │  systemd : seedbox-api-worker.path
                        ▼
     seedbox_api_worker.sh (hôte, root) : REVALIDE puis exécute
     add_user_service.sh / remove_service.sh
```

| Élément | Emplacement |
|---------|-------------|
| Code de l'API (Python, bibliothèque standard) | `scripts/seedbox_api.py` → `/opt/seedbox/api/app/` |
| Ouvrier côté hôte | `scripts/seedbox_api_worker.sh` |
| Unités systemd | `/etc/systemd/system/seedbox-api-worker.{path,service}` |
| File d'attente / résultats / état | `/opt/seedbox/api/spool/` |
| Clé partagée Traefik → API | `SEEDBOX_API_KEY` dans `/opt/seedbox/.env` (mode 600) |

### Sécurité

- **Conteneur sans privilège** : pas de socket Docker, système de fichiers en
  lecture seule, utilisateur `nobody`, `cap_drop: ALL`,
  `no-new-privileges`. Compromis, il ne pourrait que déposer des demandes.
- **L'ouvrier ne fait pas confiance au conteneur** : utilisateur seedbox
  existant (UID 2001+), service dans la liste autorisée, action connue ;
  sinon la demande est rejetée.
- **Identité par Authelia** : en-tête `Remote-User` posé par Traefik après
  authentification ; l'API exige que l'utilisateur corresponde au
  sous-domaine (`alice` ne gère que `alice.votre-domaine.com`), en plus des
  règles d'accès Authelia. Les variantes d'en-têtes (`Remote_User`…) sont
  supprimées par Traefik (`aliasHeadersStrategy: delete`).
- **Clé secrète** (`X-Seedbox-Api-Key`) ajoutée par Traefik : les autres
  conteneurs du réseau `traefik_proxy` ne peuvent pas appeler l'API
  directement en se faisant passer pour un utilisateur.
- **Anti-CSRF** : les actions exigent une requête JSON avec un en-tête
  personnalisé (impossible depuis un formulaire d'un autre site).
- Une seule opération à la fois par utilisateur.

### Journal et dépannage

```bash
journalctl -t seedbox-api                        # actions exécutées
journalctl -u seedbox-api-worker.service         # exécutions de l'ouvrier
docker logs seedbox-api                          # requêtes HTTP
systemctl status seedbox-api-worker.path
```

L'état affiché aux utilisateurs (`spool/state.json`) est mis à jour
automatiquement par `add_user*.sh`, `remove_*.sh` et l'ouvrier.
