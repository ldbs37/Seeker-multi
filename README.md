# Seedbox Multi-Utilisateurs - Version Flexible

Une solution **simple et efficace** de seedbox multi-utilisateurs avec authentification centralisée SSO et gestion facile des utilisateurs.

## 🎯 Caractéristiques

### ✨ Architecture
- **🔒 HTTPS partout** - Traefik, certificats Let's Encrypt automatiques
- **🔐 Connexion unique (SSO)** - Authelia : un seul login pour tous les services
- **🛡️ Utilisateurs isolés** - Chacun n'accède qu'à ses services (règles Authelia + réseau Docker privé)
- **📦 Services optionnels** - Installez uniquement ce dont vous avez besoin
- **🚀 Gestion facilitée** - Scripts dédiés et menu interactif

### 📋 Services Par Utilisateur

**Services Obligatoires (tous les utilisateurs) :**
- 📥 **qBittorrent + VueTorrent** - Client torrent avec l'interface moderne VueTorrent (installée et activée automatiquement)
- 🖥️ **Homarr** - Tableau de bord personnel (Homarr partagé, préconfiguré)
- 📂 **FileBrowser Quantum** - Gestionnaire de fichiers web (aperçus, recherche, liens de partage publics)

**Services Optionnels (installables à la demande) :**
- 📺 **Sonarr** - Gestion de séries TV
- 🎬 **Radarr** - Gestion de films
- 🔍 **Prowlarr** - Gestion d'indexeurs
- 📝 **Seerr** - Demandes de films/séries (successeur d'Overseerr)
- 📖 **Calibre-web** - Bibliothèque ebooks

**Tout est préconfiguré** :
- 🔐 Connexion unique via Authelia : aucune page de connexion (Seerr : identifiants Jellyfin)
- 🔗 Sonarr / Radarr → qBittorrent, dossiers `tv/` et `movies/`
- 🔍 Prowlarr → Sonarr / Radarr, avec son FlareSolverr
- 📝 Seerr → Jellyfin (seulement vos bibliothèques) et Sonarr / Radarr ; demandes validées automatiquement
- 📖 Calibre-web → bibliothèque `books/`
- 🛡️ Chaque utilisateur a son réseau Docker privé : les autres ne peuvent pas joindre ses services

> Readarr (abandonné par ses auteurs), Bazarr, Plex et Tautulli ne sont plus
> proposés ; une installation existante les conserve.

### 🛡️ Services Système (accès administrateur)
- 🔐 **Authelia** - Authentification centralisée
- 🎥 **Jellyfin** - Serveur de streaming (comptes et bibliothèques privées automatiques, connexion via Authelia — voir [docs/JELLYFIN_AUTO_CONFIG.md](docs/JELLYFIN_AUTO_CONFIG.md))
- 🐋 **Portainer** - Gestion Docker via interface web

### 🔧 Services Optionnels (accès administrateur)
- 💽 **Scrutiny** - Monitoring des disques (S.M.A.R.T.)
- 📊 **Uptime Kuma** - Surveillance de disponibilité
- 🎨 **Dashdot** - Dashboard de monitoring système
- 🔄 **Watchtower** - Mises à jour automatiques
- 💾 **Duplicati** - Système de backup

### 👥 Rôles Utilisateurs
- **Administrateur** (premier utilisateur créé) : Accès aux services système + services utilisateur
- **Utilisateurs Standard** : Accès uniquement aux services utilisateur (qBittorrent, Homarr, FileBrowser Quantum + optionnels)

### 🔒 Sécurité
- **SSO (Single Sign-On)** - Un seul login pour tous les services
- **SSL automatique** - Certificats Let's Encrypt générés automatiquement
- **Authentification centralisée** - Authelia pour gestion des utilisateurs
- **Protection fail2ban** - Contre les attaques par force brute
- **Espaces utilisateurs isolés** - Chaque utilisateur dans son environnement
- **Quotas par utilisateur** - Limitation de l'espace disque via **quota projet** (limite le dossier de chaque utilisateur). Nécessite d'activer les quotas sur le système de fichiers : `sudo scripts/enable_quotas.sh` (voir note ci-dessous)
- **Pare-feu UFW** - Configuré automatiquement

### 🌐 Accès
- ✅ HTTPS automatique (Let's Encrypt)
- ✅ URLs propres : `https://<utilisateur>.domaine.com/<service>`
- ✅ Un seul login (Authelia), sur tous les services
- ⚠️ Nécessite : nom de domaine (le vôtre ou DuckDNS, gratuit) + DNS wildcard, ports 80/443 ouverts

## 🔧 Prérequis

### Matériel Recommandé
- **CPU:** 4 cœurs minimum
- **RAM:** 8 GB minimum (10 GB avec Traefik)
- **Stockage:** 20 GB minimum pour le système
- **Connexion:** 100 Mbps minimum

### Système
- **OS:** Ubuntu 22.04/24.04 LTS ou Debian 12
- **Système de fichiers:** ext4 ou xfs recommandé (pour les quotas)
- **Accès:** root (sudo)

### Domaine et réseau (requis)
- **Nom de domaine:** Requis (ex: `example.com`, ou DuckDNS gratuit)
- **DNS wildcard:** `*.example.com` pointant vers votre serveur
- **Ports ouverts:** 80/tcp et 443/tcp dans le firewall

## 📥 Installation

### Installation Rapide

```bash
# 1. Cloner le repository
git clone https://github.com/votre-repo/Seeker-multi.git
cd Seeker-multi

# 2. Rendre le script exécutable
chmod +x install.sh

# 3. Lancer l'installation
sudo ./install.sh
```

### Installation Interactive

Le script vous guidera à travers la configuration :

1. **Configuration du domaine**
   - Nom de domaine (ex: `example.com`)
   - Email administrateur (pour Let's Encrypt)

2. **DNS** (Cloudflare automatique, autre fournisseur, ou DuckDNS)
   - DNS wildcard `*.example.com` → IP du serveur
   - Ports 80/443 ouverts dans le firewall
   - Si ce n'est pas prêt, l'installation s'arrête avec la marche à suivre

3. **Premier utilisateur (Administrateur)**
   - Le premier utilisateur créé sera automatiquement administrateur
   - Nom d'utilisateur et mot de passe sécurisé
   - Quota de stockage
   - Accès aux services système + services utilisateur

4. **Services système optionnels**
   - Jellyfin (streaming média)
   - Scrutiny (monitoring disques)
   - Uptime Kuma (monitoring uptime)
   - Dashdot (dashboard monitoring)
   - Portainer (gestion Docker)
   - Watchtower (mises à jour auto)
   - Duplicati (backups)

5. **Utilisateurs supplémentaires (optionnel)**
   - Créés comme utilisateurs standard
   - Choisissez les services optionnels à installer pour chaque utilisateur
   - Services obligatoires : qBittorrent + Homarr + FileBrowser Quantum

## 🎮 Menu Interactif de Gestion

Pour une gestion simplifiée, utilisez le menu interactif :

```bash
cd /opt/seedbox
sudo ./menu.sh
```

Le menu vous permet de :
- 👥 **Gérer les utilisateurs** - Ajouter, supprimer, modifier quotas, mots de passe
- 🔧 **Gérer les services** - Installer, supprimer des services système
- 📊 **Monitoring** - État système, services, quotas, logs
- 🛠️ **Maintenance** - Redémarrages, mises à jour, sauvegardes
- 🌐 **Traefik & SSO** 🆕 - Installer Traefik, gérer SSL, voir certificats

### Interface du Menu

```
╔════════════════════════════════════════════════════════════╗
║                                                            ║
║        🎬 SEEDBOX MULTI-UTILISATEURS - MENU GESTION       ║
║                                                            ║
╚════════════════════════════════════════════════════════════╝

MENU PRINCIPAL

1. 👥  Gestion des utilisateurs
2. 🔧  Gestion des services système
3. 📊  Monitoring
4. 🛠️   Maintenance
5. 🌐  Traefik & SSO

0. ❌  Quitter
```

## 👥 Gestion des Utilisateurs

### Via le Menu Interactif (Recommandé)

```bash
sudo ./menu.sh
# Puis sélectionnez: 1. Gestion des utilisateurs
```

### Via les Scripts Directs

### Ajouter un utilisateur

```bash
cd /opt/seedbox/scripts
sudo ./add_user.sh <username> <password> <email> [quota_gb] [--admin]
```

**Exemples:**
```bash
# Créer un utilisateur standard (quota 500 Go)
sudo ./add_user.sh john 'Seedbox!2026x' john@example.com 500

# Créer un administrateur
sudo ./add_user.sh admin 'Admin!Seedbox42' admin@example.com 1000 --admin
```

**Règles :**
- **Nom d'utilisateur** : minuscules et chiffres, commence par une lettre
  (`^[a-z][a-z0-9]{0,31}$`) — il sert de sous-domaine et de nom de conteneur.
- **Mot de passe** : 8 caractères minimum, dont 1 majuscule et 1 caractère
  spécial ; le même mot de passe sert à tous les
  services (Linux, Authelia, qBittorrent, gestion de fichiers, Jellyfin). Le compte
  admin de Portainer, distinct, demande 12 caractères minimum.
- **UID** : attribués à partir de 2001 ; chaque utilisateur reçoit un bloc de
  20 ports à partir de 20000 (voir [Accès aux services](#-accès-aux-services)).

**Services installés automatiquement :**
- **Tous les utilisateurs** : qBittorrent + Homarr + FileBrowser Quantum
- **Services optionnels** : Choisis lors de la création (Sonarr, Radarr, etc.)
- **Mode interactif** : Le script propose une sélection de services à installer

### Supprimer un utilisateur

```bash
# Suppression complète (avec données)
sudo ./remove_user.sh <username>

# Suppression en gardant les données
sudo ./remove_user.sh <username> --keep-data

# Sans confirmation interactive (scripts)
sudo ./remove_user.sh <username> --yes
```

Le script retire les conteneurs **et** leurs blocs du `docker-compose.yml`, le
compte Authelia, la règle de pare-feu du port torrent et le quota. Le dernier
administrateur ne peut pas être supprimé.

### Lister / retirer les services

```bash
sudo ./list_user_services.sh john        # état + URL de chaque service
sudo ./add_user_service.sh john sonarr   # ajouter un service à john
sudo ./remove_service.sh sonarr-john     # retirer un service d'un utilisateur
sudo ./remove_service.sh portainer       # retirer un service système
```

Les données et configurations restent sur le disque après un retrait.

### Quotas disque (activation préalable)

Les quotas utilisent des **quotas projet** : chaque utilisateur a un dossier
(`/opt/seedbox/data/users/<user>`) dont la taille est limitée, quel que soit le
propriétaire des fichiers.

⚠️ Les quotas Linux doivent d'abord être **activés sur le système de fichiers**
(option de montage + `quotaon`). Ce n'est pas fait automatiquement à
l'installation. Lancez une fois :

```bash
sudo ./enable_quotas.sh            # cible /opt/seedbox par défaut
```

- **ext4** : fonctionnalités `project` + `quota` et option `prjquota`. Ces
  fonctionnalités ne s'activent que **disque démonté** : sur la partition
  **racine**, le script affiche la commande à lancer en **mode rescue**
  (`e2fsck -f /dev/sdXN && tune2fs -O project,quota -Q prjquota /dev/sdXN`)
  sans rien modifier ; relancez-le ensuite, les quotas s'activent sans autre
  redémarrage.
- **XFS** : option `pquota` (sur la racine : `rootflags=pquota` dans GRUB).

Tant que les quotas ne sont pas activés, `add_user.sh` crée les utilisateurs
normalement mais **sans appliquer** de limite (un avertissement s'affiche).

### Modifier un quota

```bash
sudo ./update_quota.sh <username> <quota_gb>
```

**Exemple:**
```bash
sudo ./update_quota.sh john 1000  # 1TB
```

### Mises à jour (système / Docker / module)

Les images Docker sont **épinglées** à l'installation (stabilité et
reproductibilité, pas de rupture surprise). Pour mettre à jour **quand vous le
décidez**, utilisez le module dédié — via le menu (**Maintenance → Mises à
jour**) ou directement :

```bash
sudo ./update.sh              # menu interactif
sudo ./update.sh --system     # système : apt update && upgrade
sudo ./update.sh --docker     # re-pull des tags épinglés + redéploiement
sudo ./update.sh --bump       # changer la version d'une image (choix + tag)
sudo ./update.sh --seedbox    # met à jour scripts + menu depuis le dépôt git
sudo ./update.sh --all        # système + re-pull Docker + module
sudo ./update.sh --check      # vérification complète du système (healthcheck)
```

Après chaque mise à jour Docker, un **healthcheck complet** est lancé
automatiquement (état de tous les conteneurs, Traefik, Authelia, réseau,
pare-feu, espace disque, quotas). Il est aussi disponible seul :

```bash
sudo ./healthcheck.sh          # rapport complet (menu : Monitoring → Vérification complète)
sudo ./healthcheck.sh --quiet  # n'affiche que les avertissements/erreurs
```
Code de sortie `0` si aucun problème critique, `1` sinon.

### Sauvegarde & restauration de la configuration

Sauvegarde **complète de la config** (Authelia + base utilisateurs, `.env`,
`docker-compose.yml`, `traefik/` + certificats, configs système et
par-utilisateur, mappings de quotas) — **hors** téléchargements, médias et
caches. Menu : **Maintenance → Créer une sauvegarde / Restaurer**.

```bash
sudo ./backup.sh                 # sauvegarde horodatée dans /var/backups/seedbox
sudo ./restore.sh                # liste les sauvegardes et restaure celle choisie
sudo ./restore.sh <archive.tar.gz>
```

- **Retour en arrière** : `restore.sh` arrête la stack, restaure les fichiers,
  redémarre et lance le healthcheck.
- **Filet de sécurité** : avant toute restauration, un **snapshot** de la
  config actuelle est créé (la commande pour annuler la restauration est
  affichée à la fin).
- **Snapshot automatique** : `update.sh` crée une sauvegarde de la config
  **avant** chaque mise à jour Docker/module → on peut toujours revenir à
  l'état précédent en cas de problème.

- **Changer une version** (`--bump`) : liste les images, vous choisissez la
  nouvelle version ; le `docker-compose.yml` est **sauvegardé** avant
  modification, et **restauré automatiquement** si le déploiement échoue.
- **Module seedbox** (`--seedbox`) : met à jour uniquement les scripts de
  gestion et le menu (ni `docker-compose.yml`, ni `.env`, ni données touchés).

### Modifier un mot de passe

```bash
sudo ./update_password.sh <username> [nouveau_mot_de_passe]
```

**Si le mot de passe n'est pas fourni, il sera demandé de manière sécurisée.**

**Ce qui est mis à jour automatiquement :**
- ✅ **Mot de passe du compte système** (compte de service sans accès SSH : les fichiers se gèrent via FileBrowser Quantum)
- ✅ **Mot de passe Authelia** (authentification centralisée)
- ✅ **Mot de passe Jellyfin** (compte créé s'il manque)
- ✅ **Mot de passe qBittorrent** (hash PBKDF2 dans fichier config)

**Fichiers, Sonarr, Radarr, Prowlarr, Calibre-web :** pas de mot de passe
propre (connexion unique via Authelia). **Seerr :** identifiants Jellyfin.

**Exemple:**
```bash
# Mode interactif (mot de passe demandé de façon sécurisée)
sudo ./update_password.sh john

# Mode direct (moins sécurisé : visible dans l'historique du shell)
sudo ./update_password.sh john 'NewSecurePass789'
```

## 🔧 Services Optionnels

### Installer un service après l'installation

```bash
cd /opt/seedbox/scripts
sudo ./add_service.sh <service_name>
```

**Services disponibles:**

| Service | Commande | Description | Adresse |
|---------|----------|-------------|---------|
| Jellyfin | `sudo ./add_service.sh jellyfin` | Serveur de streaming | `jellyfin.<domaine>` |
| Portainer | `sudo ./add_service.sh portainer` | Gestion Docker via interface web | `portainer.<domaine>` |
| Scrutiny | `sudo ./add_service.sh scrutiny` | Monitoring S.M.A.R.T. des disques | `scrutiny.<domaine>` |
| Uptime Kuma | `sudo ./add_service.sh uptime-kuma` | Surveillance de disponibilité | `uptime.<domaine>` |
| Dashdot | `sudo ./add_service.sh dashdot` | Dashboard de monitoring système | `dashdot.<domaine>` |
| Watchtower | `sudo ./add_service.sh watchtower` | Mises à jour automatiques | - |
| Duplicati | `sudo ./add_service.sh duplicati` | Système de backup | `duplicati.<domaine>` |

Les services d'administration sont réservés au groupe `admins` d'Authelia.

Pour retirer un service système : `sudo ./remove_service.sh <service>`.

### 🧩 API libre-service des utilisateurs

Chaque utilisateur peut ajouter ou retirer lui-même ses services optionnels
(Sonarr, Radarr, Prowlarr, Seerr, Calibre-Web) depuis
`https://<utilisateur>.votre-domaine.com/seedbox-api/`, lien affiché sur son
tableau de bord Homarr. Activation (désactivée par défaut) :

```bash
sudo ./setup_api.sh            # ou menu → Traefik & SSO → API libre-service
sudo ./setup_api.sh --disable
```

Protégée par Authelia (chaque utilisateur ne gère que ses services), sans
accès Docker : voir [HOMARR_INTEGRATION.md](docs/HOMARR_INTEGRATION.md).

## 📁 Structure des Dossiers

```
/opt/seedbox/
├── data/
│   └── users/
│       ├── user1/            # monté sur /data (qBittorrent, *arr)
│       │   ├── downloads/        #   téléchargements qBittorrent
│       │   ├── tv/               #   bibliothèque Sonarr
│       │   ├── movies/           #   bibliothèque Radarr
│       │   ├── books/            #   Calibre-Web
│       │   └── config/           #   qbittorrent, filebrowser
│       └── user2/
│           └── ...
├── sonarr/<user>/ radarr/<user>/ …   # configuration des *arr
├── scripts/                          # scripts de gestion + lib_*.sh
├── authelia/
├── backups/                          # snapshots de configuration (backup.sh)
├── docker-compose.yml
└── .env
```

**Pas de doublon d'espace disque :** qBittorrent et les *arr voient le même
dossier sous le **même** montage `/data`. Sonarr/Radarr importent donc par
**hardlink** (un seul fichier sur le disque, visible à la fois dans
`downloads/` pour le seed et dans `tv/`/`movies/` pour la bibliothèque).
Sonarr/Radarr sont préconfigurés ainsi (dossiers racine `/data/tv` et
`/data/movies`, *Use Hardlinks instead of Copy* activé). FileBrowser Quantum et Jellyfin affichent la
taille des deux entrées, mais le quota ne compte le fichier qu'une fois.

## 🌐 Accès aux Services

Tous les services sont accessibles en HTTPS (certificats automatiques).

#### Services Système
- **Authelia (SSO):** `https://auth.votre-domaine.com`
- **Traefik Dashboard:** `https://traefik.votre-domaine.com`
- **Jellyfin:** `https://jellyfin.votre-domaine.com`
- **Portainer:** `https://portainer.votre-domaine.com`
- **Scrutiny:** `https://scrutiny.votre-domaine.com`
- **Uptime Kuma:** `https://uptime.votre-domaine.com`
- **Dashdot:** `https://dashdot.votre-domaine.com`
- **Duplicati:** `https://duplicati.votre-domaine.com`

Traefik, Portainer, Scrutiny, Dashdot, Uptime Kuma et Duplicati sont
**réservés aux administrateurs** (groupe `admins` d'Authelia).

#### Services Utilisateur (exemple pour user `john`)
- **qBittorrent:** `https://john.votre-domaine.com/qbittorrent`
- **Tableau de bord (Homarr partagé, connexion unique):** `https://votre-domaine.com` (`https://john.votre-domaine.com` y renvoie)
- **Fichiers (FileBrowser Quantum):** `https://john.votre-domaine.com/drive` — liens de partage publics en `…/drive/public/share/…` (ancienne adresse `/files` redirigée)
- **Sonarr:** `https://john.votre-domaine.com/sonarr`
- **Radarr:** `https://john.votre-domaine.com/radarr`
- **Prowlarr:** `https://john.votre-domaine.com/prowlarr`
- **Seerr (demandes):** `https://seerr-john.votre-domaine.com` (sous-domaine dédié : pas de sous-chemins)
- **Calibre:** `https://john.votre-domaine.com/calibre`

Seul port ouvert par utilisateur : son **port torrent entrant** (TCP+UDP),
`20010 + (UID − 2001) × 20` (20010 pour le premier, 20030 pour le deuxième…),
indispensable pour être connectable. `list_user_services.sh <user>` l'affiche.

#### 🔐 Connexion SSO
1. Connectez-vous sur `https://auth.votre-domaine.com`
2. Une fois authentifié, accédez à **vos services** sans re-login
3. Chaque utilisateur n'accède qu'à `https://<son-nom>.votre-domaine.com` et
   `https://seerr-<son-nom>.votre-domaine.com` ; Jellyfin garde sa propre
   connexion pour les applis TV/mobiles (bouton Authelia dans le navigateur)
4. Sonarr, Radarr, Prowlarr, qBittorrent, les fichiers et Calibre-web
   s'ouvrent directement, sans page de connexion. Ils ne sont joignables que
   par Traefik (après Authelia), le Homarr partagé et les autres services du
   même utilisateur (réseau Docker `seedbox_u_<user>`).

## 🔧 Maintenance

### Mettre à jour
Utilisez le module de mise à jour (snapshot + vérification automatiques) :
voir [Mises à jour](#mises-à-jour-système--docker--module) ou
`sudo ./menu.sh` → Maintenance.

### Vérifier les logs d'un service
```bash
docker logs <service-username>
# Exemple:
docker logs qbittorrent-john
```

### Vérifier l'utilisation du quota
```bash
# Quotas projet (un projet par dossier utilisateur)
sudo repquota -P /opt/seedbox     # ext4
sudo xfs_quota -x -c 'report -p -h' /opt/seedbox   # XFS
```
(ou `sudo ./menu.sh` → Gestion des utilisateurs → quotas)

### Redémarrer un service
```bash
docker restart <service-username>
```

## 📊 Architecture

```
                 Internet
                    ↓
            ┌───────────────┐
            │ DNS Wildcard  │
            │ *.domain.com  │
            └───────┬───────┘
                    ↓
        ┌───────────────────────┐
        │   Traefik (Port 443)  │
        │   SSL + Reverse Proxy │
        └───────────┬───────────┘
                    ↓
        ┌───────────────────────┐
        │   Authelia (SSO)      │
        │   Forward Auth        │
        └───────────┬───────────┘
                    ↓
    ┌───────────────┴───────────────┐
    │                               │
┌───▼──────┐ ┌──────────┐  ┌────────▼───┐
│ Jellyfin │ │ Services │  │ Services   │
│ Homarr   │ │ User 1   │  │ User 2     │
└──────────┘ └──────────┘  └────────────┘
            (réseau privé) (réseau privé)

✅ HTTPS partout
✅ Un seul login
✅ URLs propres
```

## 🛠️ Dépannage

### Problèmes courants

#### Les services ne démarrent pas
```bash
# Vérifier les logs
docker-compose logs

# Redémarrer tous les services
cd /opt/seedbox
docker-compose down
docker-compose up -d
```

#### Port déjà utilisé
```bash
# Identifier le processus utilisant le port
sudo lsof -i :<port>

# Ou
sudo netstat -tulpn | grep <port>
```

#### Problèmes de quotas
```bash
# Vérifier si les quotas sont activés
sudo quotaon -ap

# Réactiver les quotas
sudo quotaon -av
```

## 🌐 Ancienne installation en port direct

Le mode « port direct » (`http://IP:port`, sans Authelia) n'est plus pris en
charge : les scripts de gestion refusent de travailler dessus et indiquent la
marche à suivre. Pour passer en HTTPS + connexion unique :

1. DNS wildcard `*.votre-domaine.com` → IP du serveur ; ports 80/443 ouverts
2. Installer Traefik :
   ```bash
   sudo /opt/seedbox/scripts/setup_traefik.sh votre-domaine.com votre@email.com
   ```
3. Migrer les services (reconstruction du `docker-compose.yml`, snapshot
   préalable, retour arrière automatique en cas d'échec) :
   ```bash
   sudo /opt/seedbox/scripts/generate_traefik_labels.sh
   ```

## 🔄 Migration depuis l'ancienne version

Si vous aviez une très ancienne version :

1. **Sauvegarder vos données**
```bash
sudo cp -r /opt/seedbox /opt/seedbox.backup
```

2. **Arrêter les anciens services**
```bash
cd /opt/seedbox
docker-compose down
```

3. **Installer la nouvelle version**
```bash
cd Seeker-multi
sudo ./install.sh
```

4. **Restaurer les données utilisateurs si nécessaire**

## 📝 Notes

- **Isolation** : chaque utilisateur a son espace, ses services et son réseau Docker privé
- **Quotas** : appliqués au niveau système (ext4/xfs requis)
- **Services optionnels** : installation à la carte, à tout moment (menu, scripts ou API libre-service)

## 💡 Cas d'usage

### Pour un serveur partagé (quelques amis)
```bash
sudo ./install.sh
# Activez Jellyfin, Scrutiny et Uptime Kuma
# Ajoutez plusieurs utilisateurs avec des quotas
# ✅ HTTPS + un seul login, chacun ne voit que ses services
```

### Pour production (multi-utilisateurs)
```bash
sudo ./install.sh
# Activez Duplicati (backups) et Watchtower (auto-update)
# Configurez les quotas appropriés par utilisateur
# ✅ HTTPS partout, un seul login, monitoring complet
```

## 📚 Documentation

Pour plus d'informations, consultez la documentation dans `/docs` :

- **[AUDIT.md](docs/AUDIT.md)** - 🔍 Rapport d'audit complet et matrice de compatibilité
- **[MENU.md](docs/MENU.md)** - Guide complet du menu interactif de gestion
- **[AUTO_CONFIGURATION.md](docs/AUTO_CONFIGURATION.md)** - Guide sur l'auto-configuration des services (Portainer, Jellyfin)
- **[INSTALLATION.md](docs/INSTALLATION.md)** - Guide d'installation détaillé
- **[AUTHELIA_SSO.md](docs/AUTHELIA_SSO.md)** 🆕 - Guide complet Traefik + Authelia SSO
- **[JELLYFIN_SSO.md](docs/JELLYFIN_SSO.md)** 🆕 - Authentification commune (SSO OIDC) pour Jellyfin via Authelia
- **[scripts/README.md](scripts/README.md)** - Documentation des scripts de gestion

### Services avec Auto-Configuration

Les services suivants créent automatiquement le compte administrateur :
- ✓ **Portainer** - Le script collecte les identifiants et crée le compte admin via l'API
- ✓ **Jellyfin** - Auto-configuration via l'API de démarrage Jellyfin

### Services Nécessitant Configuration Manuelle

Ces services requièrent une configuration via l'interface web au premier accès :
- ⚠️ **Uptime Kuma**, **Duplicati**

Voir [AUTO_CONFIGURATION.md](docs/AUTO_CONFIGURATION.md) pour les détails complets.

## 📜 Licence

Ce projet est sous licence MIT. Voir le fichier `LICENSE` pour plus de détails.

## 🤝 Contribution

Les contributions sont les bienvenues ! N'hésitez pas à :
- Ouvrir une issue pour signaler un bug
- Proposer des améliorations
- Soumettre des pull requests

## 📞 Support

Pour toute question ou problème :
- Consultez la documentation dans `/docs`
- Vérifiez les logs : `docker-compose logs`
- Ouvrez une issue sur GitHub

---

**Version:** 4.0 (HTTPS + connexion unique Authelia)
**Compatibilité vérifiée:** ✅ Debian 12, Ubuntu 22.04/24.04 LTS

### 🆕 Nouveautés v4.0
- ✅ **Un seul mode** : HTTPS (Traefik) + connexion unique (Authelia) ; le mode port direct est retiré
- ✅ **Applis préconfigurées** : Sonarr, Radarr, Prowlarr, Seerr, Calibre-web reliés automatiquement
- ✅ **Réseau privé par utilisateur** : les services des autres utilisateurs ne peuvent pas joindre les vôtres
- ✅ **Jellyfin automatique** : comptes, bibliothèques privées, bouton « Se connecter avec Authelia »
- ✅ **Retirés** : Readarr (abandonné), Bazarr, Plex, Tautulli
