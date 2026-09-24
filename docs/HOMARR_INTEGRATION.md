# Homarr et API libre-service des utilisateurs

## Tableau de bord Homarr

### Mode Traefik : Homarr 1.x partagé + connexion unique

Un seul Homarr (`ghcr.io/homarr-labs/homarr`) sur **https://votre-domaine.com**,
avec connexion **automatique** via Authelia (OIDC) : on se connecte une fois
sur Authelia, Homarr ne redemande rien.

- Après une connexion directe sur `https://auth.votre-domaine.com`, Authelia
  renvoie vers le tableau de bord ; `https://<user>.votre-domaine.com/` aussi.
- **Première visite de l'administrateur** : terminer l'assistant de Homarr et
  indiquer **`admins`** comme groupe administrateur (les groupes viennent
  d'Authelia).
- Chaque utilisateur est créé dans Homarr à sa première connexion.
- Mise en place (automatique à l'installation et par
  `generate_traefik_labels.sh`) : `scripts/lib_homarr.sh` ajoute au `.env`
  `HOMARR_SECRET_KEY` et `HOMARR_OIDC_SECRET`, et à la configuration Authelia
  le fournisseur OIDC et le client `homarr` (avec une `claims_policy` qui met
  groupes, nom et email dans l'id_token — Authelia 4.39 ne le fait plus par
  défaut). Données : `/opt/seedbox/homarr/appdata`.
- Les anciens Homarr individuels sont retirés par la migration (leurs fichiers
  restent dans `data/users/<user>/config/homarr`).

#### Tableaux de bord préconfigurés

`scripts/homarr_provision.sh` crée pour chaque utilisateur un tableau de bord
**`https://votre-domaine.com/boards/<user>`** — où renvoie
`https://<user>.votre-domaine.com/` — avec une tuile par service installé
(qBittorrent, Fichiers, Sonarr, Radarr, Seerr…). Il passe par l'API de Homarr :

1. Une fois, l'admin crée un jeton : `https://votre-domaine.com/manage/tools/api`
   → onglet **Authentification** → **Créer un jeton API** (le copier : il
   n'est affiché qu'une fois).
2. `sudo /opt/seedbox/scripts/homarr_provision.sh --set-key '<jeton>'`
   (enregistre le jeton dans `.env` et prépare tous les utilisateurs).

Ensuite, c'est automatique : ajout d'un utilisateur ou d'un service → tuile
ajoutée ; suppression d'un utilisateur → tableau de bord, applis et groupe
retirés. Idempotent (relançable sans doublon, personnalisations conservées).
Retirer un service laisse sa tuile (à supprimer à la main).

**Cloisonnement** : chaque tableau de bord est **privé**, réservé au groupe
personnel `u-<user>`. Ce groupe est ajouté au compte Authelia (add_user.sh ;
migration pour les comptes existants), transmis à Homarr à chaque connexion
(OIDC, groupes synchronisés par nom), et reçoit le droit de **modifier** son
tableau de bord, qui devient aussi sa page d'accueil. Les administrateurs
(groupe `admins`) voient tout. Un utilisateur connecté avant la création de
son groupe doit se reconnecter une fois.

### Mode port direct : Homarr 0.16 par utilisateur

Sans Authelia devant les services, pas de connexion unique possible : chaque
utilisateur garde son Homarr 0.16 (port `20001`+), dont la configuration est
générée par `configure_homarr.sh` (une tuile par service).

## API libre-service (mode Traefik)

Permet à chaque utilisateur d'**ajouter ou retirer ses services optionnels
lui-même**, sans SSH ni intervention de l'admin, depuis la page
`https://<user>.votre-domaine.com/seedbox-api/` (lien « ➕ Ajouter / retirer
des services » sur son Homarr).

Services proposés : Sonarr, Radarr, Readarr, Bazarr, Prowlarr, Seerr,
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
