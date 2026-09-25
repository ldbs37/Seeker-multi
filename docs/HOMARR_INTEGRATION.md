# Homarr et API libre-service des utilisateurs

## Tableau de bord Homarr

### Mode Traefik : Homarr 1.x partagé + connexion unique

Un seul Homarr (`ghcr.io/homarr-labs/homarr`) sur **https://votre-domaine.com**,
avec connexion **automatique** via Authelia (OIDC) : on se connecte une fois
sur Authelia, Homarr ne redemande rien.

- Après une connexion directe sur `https://auth.votre-domaine.com`, Authelia
  renvoie vers le tableau de bord ; `https://<user>.votre-domaine.com/` aussi.
- **Aucune configuration manuelle** : à l'installation (et à chaque
  migration), `homarr_bootstrap` termine l'assistant, crée le groupe
  administrateur `admins` (celui d'Authelia), un compte de service
  `seedbox-api` (admin, sans mot de passe : connexion impossible) et sa clé
  d'API (jeton haché en bcrypt dans la base, clé dans `.env`), avec
  sauvegarde de la base avant écriture.
- Chaque utilisateur est créé dans Homarr à sa première connexion ; ses
  groupes (`admins`, `u-<user>`) sont synchronisés depuis Authelia.
- Mise en place (automatique à l'installation et par
  `generate_traefik_labels.sh`) : `scripts/lib_homarr.sh` ajoute au `.env`
  `HOMARR_SECRET_KEY` et `HOMARR_OIDC_SECRET`, et à la configuration Authelia
  le fournisseur OIDC et le client `homarr` (avec une `claims_policy` qui met
  groupes, nom et email dans l'id_token — Authelia 4.39 ne le fait plus par
  défaut). Données : `/opt/seedbox/homarr/appdata`.
- Les anciens Homarr individuels sont retirés par la migration (leurs fichiers
  restent dans `data/users/<user>/config/homarr`).

#### Tableaux de bord préconfigurés

`scripts/homarr_provision.sh` construit tout, via l'API de Homarr et la clé
créée par `homarr_bootstrap` (`--set-key '<id>.<jeton>'` permet d'en utiliser
une autre, créée dans Homarr → Gestion → Outils → API).

**Tableau de chaque utilisateur** — `https://votre-domaine.com/boards/<user>`,
où renvoie `https://<user>.votre-domaine.com/` :

| Élément | Contenu |
|---------|---------|
| Date et heure, météo | Prévisions sur 5 jours (Paris par défaut : à changer dans le widget) |
| Tuiles | Chaque service installé + Jellyfin, avec voyant d'état (vert/rouge) |
| Téléchargements | Torrents qBittorrent en cours : progression, vitesses, temps restant |
| Prochaines sorties | Calendrier Sonarr / Radarr / Readarr |
| Demandes | Statistiques et liste des demandes Seerr |
| Serveur (admins) | Lien vers le tableau d'administration |

**Tableau d'administration** — `https://votre-domaine.com/boards/admin-serveur`,
réservé au groupe `admins` : charge CPU / RAM / réseau, santé et disques
(via Dash. : `add_service.sh dashdot` s'il n'est pas installé), lectures en
cours et derniers ajouts sur Jellyfin, tuiles des services système (Portainer,
Authelia, Scrutiny, Duplicati…) avec voyant d'état.

Les lectures en cours Jellyfin ne sont que sur le tableau d'administration :
Homarr les lit avec la clé administrateur, elles montreraient à chacun ce que
regardent les autres.

**Intégrations automatiques** : Homarr joint chaque service par le réseau
Docker (`http://sonarr-<user>:8989/sonarr`…, sans passer par Authelia), avec
une clé d'API lue dans sa configuration :

| Service | Clé |
|---------|-----|
| qBittorrent | `WebUI\APIKey` de `qBittorrent.conf`, créée au besoin (qBittorrent redémarré une fois) |
| Sonarr, Radarr, Readarr | `ApiKey` de leur `config.xml` |
| Seerr | `main.apiKey` de `settings.json` |
| Jellyfin | Clé `seedbox` créée dans Jellyfin (redémarré une fois), gardée dans `/opt/seedbox/.jellyfin_api` |

Chaque intégration n'est utilisable que par le groupe de son propriétaire.
Homarr teste la connexion avant de l'enregistrer : un service pas encore prêt
(Seerr non configuré…) est signalé et repris au passage suivant
(`sudo /opt/seedbox/scripts/homarr_provision.sh --all`).

**Mise en page** : grille de 10 colonnes sur ordinateur, disposition « Mobile »
de 4 colonnes sous 800 px. La barre de recherche de Homarr (en haut) cherche
dans les applis et, par défaut, sur DuckDuckGo.

C'est automatique : ajout d'un utilisateur ou d'un service → éléments
ajoutés ; suppression d'un utilisateur → tableau de bord, applis,
intégrations et groupe retirés. Idempotent : relançable sans doublon. Après
la première mise en page rien n'est déplacé (les éléments ajoutés se placent
à la première place libre), et un widget supprimé par l'utilisateur n'est pas
recréé (liste dans `/opt/seedbox/homarr/provision/<tableau>.keys`). Retirer un
service laisse sa tuile (à supprimer à la main).

**Cloisonnement** : chaque tableau de bord est **privé**, réservé au groupe
personnel `u-<user>`. Ce groupe est ajouté au compte Authelia (add_user.sh ;
migration pour les comptes existants), transmis à Homarr à chaque connexion
(OIDC, groupes synchronisés par nom), et reçoit le droit de **modifier** son
tableau de bord, qui devient aussi sa page d'accueil. Les administrateurs
(groupe `admins`) voient tout. Un utilisateur connecté avant la création de
son groupe doit se reconnecter une fois.

#### Connexion unique qBittorrent et gestion de fichiers

Ils ont leur propre écran de connexion ; en mode Traefik il est sauté,
Authelia ayant déjà identifié l'utilisateur. Automatique à l'installation, à
l'ajout d'un utilisateur et par `generate_traefik_labels.sh` (installations
existantes), sans ouvrir d'accès aux autres conteneurs :

- **qBittorrent** : seule l'adresse de Traefik est dispensée de mot de passe
  (liste blanche `/32`). Traefik le joint par un réseau Docker dédié
  (`seedbox_sso`, interne) où il a une adresse fixe (`TRAEFIK_SSO_IP` du
  `.env`). Les *arr d'un autre utilisateur, qui joignent qBittorrent par
  `traefik_proxy`, doivent toujours s'authentifier. La prise en charge du
  reverse-proxy de qBittorrent est désactivée (sinon un en-tête
  `X-Forwarded-For` forgé imiterait Traefik).
- **FileBrowser Quantum** : authentification « proxy ». Traefik transmet le
  nom de l'utilisateur (celui du routeur, contrôlé par Authelia) dans un
  en-tête au nom **secret** (`SSO_HEADER` du `.env`), en écrasant toute valeur
  envoyée par le client ; sans cet en-tête, l'accès est refusé.

#### Gestion de fichiers : FileBrowser Quantum

Remplace Filebrowser, archivé le 1er septembre 2026 (plus aucun correctif de
sécurité). Une instance par utilisateur (`gtstef/filebrowser`, version
stable), avec son UID, sur ses fichiers (`data/users/<user>`) :
`https://<user>.votre-domaine.com/drive` (l'ancienne adresse `/files` y redirige). Aperçus (images, vidéos, documents),
recherche, mode sombre, en français. Configuration générée dans
`data/users/<user>/config/filebrowser/config.yaml` (`lib_filebrowser.sh`).

**Partage public** : clic droit sur un fichier ou un dossier → *Partager*
(durée, mot de passe facultatifs). Le lien
`https://<user>.votre-domaine.com/drive/public/share/…` s'ouvre **sans
compte** : c'est le seul chemin servi sans Authelia (routeur Traefik dédié,
en-tête de connexion retiré). Traefik normalise les chemins avant de router :
un `…/public/../` repasse par Authelia.

Migration d'une installation existante : `generate_traefik_labels.sh --yes`
(nouvelle base FileBrowser, fichiers inchangés ; les anciens réglages de
Filebrowser ne sont pas repris).

Le mot de passe reste valable pour les accès directs (applis mobiles
qBittorrent…).

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
Calibre-Web. qBittorrent, Homarr et la gestion de fichiers (services de base) ne sont
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
