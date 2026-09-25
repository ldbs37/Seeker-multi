# Scripts de Gestion Seedbox

Scripts de gestion de l'installation seedbox multi-utilisateurs
(installés dans `/opt/seedbox/scripts`). Tous requièrent `sudo`.
Le plus simple reste le menu : `sudo /opt/seedbox/menu.sh`.

## 👤 Utilisateurs

### `add_user.sh`
```bash
sudo ./add_user.sh <username> <password> <email> [quota_gb] [--admin]
```
Crée le compte système (UID ≥ 2001), le compte Authelia, les dossiers, le
quota projet et les services de base **qBittorrent + Homarr + Filebrowser**,
tous avec les mêmes identifiants. En terminal interactif, propose ensuite les
services optionnels.

- `username` : `^[a-z][a-z0-9]{0,31}$` (sert de sous-domaine et de nom de conteneur)
- `password` : 12 caractères minimum, dont 1 majuscule et 1 caractère spécial
- `quota_gb` : 500 par défaut, 0 = illimité (quotas à activer avant, voir `enable_quotas.sh`)
- `--admin` : membre du groupe `admins` d'Authelia (accès Traefik, Portainer…)

```bash
sudo ./add_user.sh john 'Seedbox!2026x' john@example.com 500
```

### `add_user_service.sh`
```bash
sudo ./add_user_service.sh <username> <service>
```
Services : `sonarr radarr readarr bazarr prowlarr seerr calibre`.
URL de base (mode Traefik) pré-configurée, tableau de bord Homarr mis à jour.

### `list_user_services.sh`
```bash
sudo ./list_user_services.sh john
```
```
Services de john (UID 2001) :
  qbittorrent  ● actif  https://john.exemple.com/qbittorrent
  homarr       ● actif  https://john.exemple.com
  sonarr       ● actif  https://john.exemple.com/sonarr
[INFO] Port torrent entrant : 20010 (TCP/UDP)
[INFO] Services installables : radarr readarr …
```

### `remove_user.sh`
```bash
sudo ./remove_user.sh <username> [--keep-data] [--yes]
```
Retire conteneurs, blocs du `docker-compose.yml`, compte Authelia, règle de
pare-feu, quota et compte système. Refuse de supprimer le dernier administrateur.

> Les comptes seedbox sont des **comptes de service sans shell** (pas d'accès
> SSH/SFTP) : les fichiers se gèrent via Filebrowser.

### `remove_service.sh`
```bash
sudo ./remove_service.sh sonarr-john   # service d'un utilisateur
sudo ./remove_service.sh portainer     # service système
```
Les données restent sur le disque. Authelia, FlareSolverr, Traefik et les
services de base d'un utilisateur ne peuvent pas être retirés ainsi.

### `update_password.sh`
```bash
sudo ./update_password.sh <username> [nouveau_mot_de_passe]
```
Met à jour : Linux, Authelia, qBittorrent, Filebrowser et Jellyfin (si clé API).
Sans mot de passe en argument, il est demandé de façon masquée.

### `update_quota.sh` / `enable_quotas.sh`
```bash
sudo ./enable_quotas.sh            # une fois (redémarrage si FS racine)
sudo ./update_quota.sh john 1000   # 1 To ; 0 = illimité
```
Quotas **projet** : la limite porte sur le dossier `data/users/<user>`.

### `configure_homarr.sh`, `configure_jellyfin_user.sh`, `disable_arr_auth.sh`
Régénère le tableau de bord Homarr d'un utilisateur ; crée/met à jour son
compte Jellyfin (accès limité à ses bibliothèques) ; passe l'authentification
d'un *arr en « External » (derrière Authelia).

## 🔧 Services système

### `add_service.sh`
```bash
sudo ./add_service.sh <plex|jellyfin|portainer|scrutiny|uptime-kuma|dashdot|tautulli|watchtower|duplicati>
```
Reconstruit la partie système du `docker-compose.yml` (validation avant
application). Portainer et Jellyfin : compte admin créé automatiquement.

### `homarr_provision.sh` (mode Traefik)
```bash
sudo ./homarr_provision.sh <user> | --all | --remove <user>
sudo ./homarr_provision.sh --set-key '<id>.<jeton>'   # facultatif : clé créée à la main
```
Tableau de bord Homarr partagé de chaque utilisateur (`https://<domaine>/boards/<user>`),
une tuile par service ; appelé automatiquement par add_user/add_user_service/remove_user.

### `setup_api.sh` (mode Traefik)
```bash
sudo ./setup_api.sh [--refresh|--disable]
```
Active l'API libre-service : chaque utilisateur ajoute/retire ses services
optionnels depuis `https://<user>.<domaine>/seedbox-api/`. Conteneur sans
privilège + ouvrier systemd côté hôte (`seedbox_api_worker.sh`) qui revalide
chaque demande. Détails : `docs/HOMARR_INTEGRATION.md`.

## 🌐 Accès distant

| Script | Rôle |
|--------|------|
| `setup_traefik.sh <domaine> <email>` | Installe Traefik + Let's Encrypt |
| `generate_traefik_labels.sh [--yes]` | Migre une installation « ports directs » vers Traefik + SSO (snapshot, validation, retour arrière auto) |
| `setup_cloudflare.sh` / `setup_duckdns.sh` | Enregistrements DNS |
| `check_dns.sh <domaine>` | Vérifie la résolution DNS (wildcard) |

## 🔄 Maintenance

| Script | Rôle |
|--------|------|
| `update.sh [--system\|--docker\|--seedbox\|--all]` | Mises à jour (snapshot avant, healthcheck après, rollback du compose si échec) |
| `healthcheck.sh [--quiet]` | Vérification complète (code retour 1 si échec) |
| `backup.sh [--auto] [--label x]` | Snapshot de configuration dans `/opt/seedbox/backups` (données média exclues) |
| `restore.sh [archive]` | Restauration (snapshot de sécurité préalable) |

## 📊 Ports (mode port direct)

Bloc de 20 ports par utilisateur : `20000 + (UID − 2001) × 20 + décalage`.

| Service | Décalage | UID 2001 | UID 2002 |
|---------|----------|----------|----------|
| qBittorrent | 0 | 20000 | 20020 |
| Homarr | 1 | 20001 | 20021 |
| Filebrowser | 2 | 20002 | 20022 |
| Sonarr | 3 | 20003 | 20023 |
| Radarr | 4 | 20004 | 20024 |
| Readarr | 5 | 20005 | 20025 |
| Bazarr | 6 | 20006 | 20026 |
| Prowlarr | 7 | 20007 | 20027 |
| Seerr | 8 | 20008 | 20028 |
| Calibre-Web | 9 | 20009 | 20029 |
| Port torrent (TCP+UDP, aussi en mode Traefik) | 10 | 20010 | 20030 |

En mode Traefik, seules les URL `https://<user>.<domaine>/<service>` (et
`https://seerr-<user>.<domaine>`) sont utilisées.

## 📁 Structure

```
/opt/seedbox/
├── data/users/<user>/        # monté sur /data (qBittorrent + *arr)
│   ├── downloads/ tv/ movies/ books/
│   └── config/{qbittorrent,homarr,filebrowser}/
├── sonarr/<user>/ radarr/<user>/ readarr/<user>/ bazarr/<user>/
├── prowlarr/<user>/ seerr/<user>/ calibre/<user>/
├── authelia/  backups/  scripts/
├── docker-compose.yml
└── .env
```

Montage `/data` unique ⇒ imports Sonarr/Radarr par **hardlink** : aucun
doublon d'espace disque entre `downloads/` et la bibliothèque. Dans les *arr,
utilisez `/data/tv`, `/data/movies` ou `/data/books` comme dossier racine et
`qbittorrent-<user>` comme hôte du client torrent.

## 🧱 Bibliothèques internes (`lib_*.sh`)

Sourcées par les scripts, source unique de vérité :
`lib_ports.sh` (UID/ports), `lib_services.sh` (blocs compose utilisateur),
`lib_traefik.sh` (routage), `lib_compose_base.sh` (services système),
`lib_qbittorrent.sh` (hash PBKDF2), `lib_autoconfig.sh` (Portainer/Jellyfin),
`lib_quota.sh` (quotas projet).

## 🛠️ Dépannage

```bash
docker logs sonarr-john              # logs d'un service
docker restart radarr-alice          # redémarrage
sudo ./healthcheck.sh                # diagnostic global
```
