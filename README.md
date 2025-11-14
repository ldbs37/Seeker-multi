# Seedbox Multi-Utilisateurs - Version Flexible

Une solution **simple et efficace** de seedbox multi-utilisateurs avec authentification centralisée SSO et gestion facile des utilisateurs.

## 🎯 Caractéristiques

### ✨ Architecture Flexible (Mode Dual)
- **🔓 Mode Port Direct** - Architecture simple sans reverse proxy (idéal pour débutants)
- **🔒 Mode Traefik + SSL** - Reverse proxy avec SSL automatique et Single Sign-On (production)
- **🔐 Authentification SSO** - Authelia pour authentification centralisée avec un seul login
- **📦 Services optionnels** - Installez uniquement ce dont vous avez besoin
- **🚀 Gestion facilitée** - Scripts dédiés avec détection automatique du mode actif

### 📋 Services Par Utilisateur

**Services Obligatoires (tous les utilisateurs) :**
- 📥 **qBittorrent + VueTorrent** - Client torrent moderne
- 🖥️ **Homarr** - Dashboard personnel avec auto-découverte
- 📂 **Filebrowser** - Gestionnaire de fichiers web

**Services Optionnels (installables à la demande) :**
- 📺 **Sonarr** - Gestion de séries TV
- 🎬 **Radarr** - Gestion de films
- 📚 **Readarr** - Gestion de livres
- 💬 **Bazarr** - Gestion de sous-titres
- 🔍 **Prowlarr** - Gestion d'indexeurs
- 📝 **Overseerr** - Système de requêtes
- 📖 **Calibre-web** - Bibliothèque ebooks

### 🛡️ Services Système (accès administrateur)
- 🔐 **Authelia** - Authentification centralisée
- 🎥 **Plex / Jellyfin** - Serveurs de streaming média
- 🚦 **FlareSolverr** - Bypass Cloudflare
- 🐋 **Portainer** - Gestion Docker via interface web

### 🔧 Services Optionnels (accès administrateur)
- 💽 **Scrutiny** - Monitoring des disques (S.M.A.R.T.)
- 📊 **Uptime Kuma** - Surveillance de disponibilité
- 🎨 **Dashdot** - Dashboard de monitoring système
- 📈 **Tautulli** - Statistiques Plex détaillées
- 🔄 **Watchtower** - Mises à jour automatiques
- 💾 **Duplicati** - Système de backup

### 👥 Rôles Utilisateurs
- **Administrateur** (premier utilisateur créé) : Accès aux services système + services utilisateur
- **Utilisateurs Standard** : Accès uniquement aux services utilisateur (qBittorrent, Homarr, Filebrowser + optionnels)

### 🔒 Sécurité
- **SSO (Single Sign-On)** - Un seul login pour tous les services (mode Traefik)
- **SSL automatique** - Certificats Let's Encrypt générés automatiquement (mode Traefik)
- **Authentification centralisée** - Authelia pour gestion des utilisateurs
- **Protection fail2ban** - Contre les attaques par force brute
- **Espaces utilisateurs isolés** - Chaque utilisateur dans son environnement
- **Quotas par utilisateur** - Limitation de l'espace disque
- **Pare-feu UFW** - Configuré automatiquement

### 🌐 Modes d'Accès

#### Mode Port Direct (Simple)
- ✅ Configuration simple, pas de DNS requis
- ✅ Accès direct : `http://IP:PORT`
- ✅ Idéal pour usage personnel/local
- ❌ Pas de SSL automatique
- ❌ Login séparé pour chaque service

#### Mode Traefik + SSL (Production)
- ✅ SSL automatique via Let's Encrypt
- ✅ URLs propres : `https://user.domain.com/service`
- ✅ Single Sign-On (un seul login pour tout)
- ✅ Protection Authelia sur tous les services
- ⚠️ Nécessite : nom de domaine + DNS wildcard configuré

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

### Pour le mode Traefik (optionnel)
- **Nom de domaine:** Requis (ex: `example.com`)
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

2. **Choix du mode d'accès** 🆕
   - **Mode Port Direct** - Simple, sans DNS (par défaut)
   - **Mode Traefik + SSL** - Avec HTTPS et SSO (si DNS configuré)
   - ⚠️ Le mode Traefik nécessite :
     - DNS wildcard `*.example.com` → IP du serveur
     - Ports 80/443 ouverts dans le firewall

3. **Premier utilisateur (Administrateur)**
   - Le premier utilisateur créé sera automatiquement administrateur
   - Nom d'utilisateur et mot de passe sécurisé
   - Quota de stockage
   - Accès aux services système + services utilisateur

4. **Services système optionnels**
   - Plex / Jellyfin (streaming média)
   - Scrutiny (monitoring disques)
   - Uptime Kuma (monitoring uptime)
   - Dashdot (dashboard monitoring)
   - Tautulli (stats Plex)
   - Portainer (gestion Docker)
   - Watchtower (mises à jour auto)
   - Duplicati (backups)

5. **Utilisateurs supplémentaires (optionnel)**
   - Créés comme utilisateurs standard
   - Choisissez les services optionnels à installer pour chaque utilisateur
   - Services obligatoires : qBittorrent + Homarr + Filebrowser

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
# Créer un utilisateur standard
sudo ./add_user.sh john MySecurePass123 john@example.com 500

# Créer un administrateur
sudo ./add_user.sh admin AdminPass456 admin@example.com 1000 --admin
```

**Services installés automatiquement :**
- **Tous les utilisateurs** : qBittorrent + Homarr + Filebrowser
- **Services optionnels** : Choisis lors de la création (Sonarr, Radarr, etc.)
- **Mode interactif** : Le script propose une sélection de services à installer

### Supprimer un utilisateur

```bash
# Suppression complète (avec données)
sudo ./remove_user.sh <username>

# Suppression en gardant les données
sudo ./remove_user.sh <username> --keep-data
```

### Modifier un quota

```bash
sudo ./update_quota.sh <username> <quota_gb>
```

**Exemple:**
```bash
sudo ./update_quota.sh john 1000  # 1TB
```

### Modifier un mot de passe

```bash
sudo ./update_password.sh <username> [nouveau_mot_de_passe]
```

**Si le mot de passe n'est pas fourni, il sera demandé de manière sécurisée.**

**Ce qui est mis à jour automatiquement :**
- ✅ **Mot de passe système Linux** (SSH, console)
- ✅ **Mot de passe Authelia** (authentification centralisée)
- ✅ **Mot de passe Jellyfin** (si configuré avec clé API)
- ✅ **Mot de passe qBittorrent** (hash PBKDF2 dans fichier config)
- ✅ **Mot de passe Filebrowser** (via CLI dans le conteneur)

**Services *arr (Sonarr, Radarr, Prowlarr, etc.) :**
- 💡 **Recommandé** : Désactiver l'authentification et s'appuyer sur Authelia
  ```bash
  sudo ./disable_arr_auth.sh <username> <service>
  ```
- ⚠️ **Alternative** : Mettre à jour manuellement (Settings → General → Security)

**Exemple:**
```bash
# Mode interactif (mot de passe demandé de façon sécurisée)
sudo ./update_password.sh john

# Mode direct (moins sécurisé)
sudo ./update_password.sh john NewSecurePass789
```

## 🔧 Services Optionnels

### Installer un service après l'installation

```bash
cd /opt/seedbox/scripts
sudo ./add_service.sh <service_name>
```

**Services disponibles:**

| Service | Commande | Description | Port |
|---------|----------|-------------|------|
| Plex | `sudo ./add_service.sh plex` | Serveur de streaming média | 32400 |
| Jellyfin | `sudo ./add_service.sh jellyfin` | Alternative open-source à Plex | 8096 |
| Portainer | `sudo ./add_service.sh portainer` | Gestion Docker via interface web | 9000 |
| Scrutiny | `sudo ./add_service.sh scrutiny` | Monitoring S.M.A.R.T. des disques | 8080 |
| Uptime Kuma | `sudo ./add_service.sh uptime-kuma` | Surveillance de disponibilité | 3001 |
| Dashdot | `sudo ./add_service.sh dashdot` | Dashboard de monitoring système | 3002 |
| Tautulli | `sudo ./add_service.sh tautulli` | Statistiques détaillées pour Plex | 8181 |
| Watchtower | `sudo ./add_service.sh watchtower` | Mises à jour automatiques | - |
| Duplicati | `sudo ./add_service.sh duplicati` | Système de backup | 8200 |

### 🚀 Gestion de Services par les Utilisateurs (API)

Les utilisateurs peuvent installer leurs propres services depuis Homarr via l'API sécurisée.

Voir [HOMARR_INTEGRATION.md](docs/HOMARR_INTEGRATION.md) pour :
- Configuration de l'API
- Intégration avec Homarr
- Interface web de gestion des services
- Sécurité et authentification JWT

## 📁 Structure des Dossiers

```
/opt/seedbox/
├── data/
│   └── users/
│       ├── user1/
│       │   ├── downloads/
│       │   ├── tv/
│       │   ├── movies/
│       │   └── books/
│       └── user2/
│           └── ...
├── scripts/
│   ├── add_user.sh
│   ├── remove_user.sh
│   ├── update_quota.sh
│   └── add_service.sh
├── authelia/
├── docker-compose.yml
└── .env
```

## 🌐 Accès aux Services

### Mode Port Direct (HTTP)

#### Services Système (accès administrateur)
- **Authelia:** `http://votre-serveur:9091`
- **Plex:** `http://votre-serveur:32400/web`
- **Jellyfin:** `http://votre-serveur:8096`
- **Portainer:** `http://votre-serveur:9000`
- **FlareSolverr:** `http://votre-serveur:8191`
- **Scrutiny:** `http://votre-serveur:8080`
- **Uptime Kuma:** `http://votre-serveur:3001`
- **Dashdot:** `http://votre-serveur:3002`
- **Tautulli:** `http://votre-serveur:8181`
- **Duplicati:** `http://votre-serveur:8200`

#### Services Utilisateur

Chaque utilisateur obtient des ports uniques calculés automatiquement :

| Service | Formule de port | Exemple (User 1) |
|---------|-----------------|------------------|
| qBittorrent | 8080 + (UID-1000)*10 | 8090 |
| Sonarr | 8989 + (UID-1000) | 8990 |
| Radarr | 7878 + (UID-1000) | 7879 |
| Readarr | 8787 + (UID-1000) | 8788 |
| Bazarr | 6767 + (UID-1000) | 6768 |
| Prowlarr | 9696 + (UID-1000) | 9697 |
| Overseerr | 5055 + (UID-1000) | 5056 |
| Homarr | 7575 + (UID-1000) | 7576 |
| Calibre | 8083 + (UID-1000) | 8084 |
| Filebrowser | 8081 + (UID-1000) | 8082 |

### Mode Traefik + SSL (HTTPS) 🆕

Avec Traefik activé, tous les services sont accessibles via HTTPS avec SSL automatique.

#### Services Système
- **Authelia (SSO):** `https://auth.votre-domaine.com`
- **Traefik Dashboard:** `https://traefik.votre-domaine.com`
- **Plex:** `https://plex.votre-domaine.com`
- **Jellyfin:** `https://jellyfin.votre-domaine.com`
- **Portainer:** `https://portainer.votre-domaine.com`
- **Scrutiny:** `https://scrutiny.votre-domaine.com`
- **Uptime Kuma:** `https://uptime.votre-domaine.com`
- **Dashdot:** `https://dashdot.votre-domaine.com`
- **Tautulli:** `https://tautulli.votre-domaine.com`
- **Duplicati:** `https://duplicati.votre-domaine.com`

#### Services Utilisateur (exemple pour user `john`)
- **qBittorrent:** `https://john.votre-domaine.com/qbittorrent`
- **Homarr:** `https://john.votre-domaine.com`
- **Filebrowser:** `https://john.votre-domaine.com/files`
- **Sonarr:** `https://john.votre-domaine.com/sonarr`
- **Radarr:** `https://john.votre-domaine.com/radarr`
- **Readarr:** `https://john.votre-domaine.com/readarr`
- **Bazarr:** `https://john.votre-domaine.com/bazarr`
- **Prowlarr:** `https://john.votre-domaine.com/prowlarr`
- **Overseerr:** `https://john.votre-domaine.com/overseerr`
- **Calibre:** `https://john.votre-domaine.com/calibre`

#### 🔐 Connexion SSO (Mode Traefik)
1. Connectez-vous sur `https://auth.votre-domaine.com`
2. Une fois authentifié, accédez à **tous les services** sans re-login
3. Session unique pour toute l'infrastructure

## 🔧 Maintenance

### Mettre à jour tous les conteneurs
```bash
cd /opt/seedbox
docker-compose pull
docker-compose up -d
```

### Vérifier les logs d'un service
```bash
docker logs <service-username>
# Exemple:
docker logs qbittorrent-john
```

### Vérifier l'utilisation du quota
```bash
sudo quota -v -u <username>
```

### Redémarrer un service
```bash
docker restart <service-username>
```

## 📊 Avantages de Cette Version

### ✅ Mode Dual : Le meilleur des deux mondes

| Caractéristique | Mode Port Direct | Mode Traefik + SSL |
|-----------------|------------------|--------------------|
| Complexité | ⭐ Simple | ⭐⭐ Intermédiaire |
| Configuration | Aucune (plug & play) | DNS wildcard requis |
| SSL/HTTPS | ❌ Manuel | ✅ Automatique (Let's Encrypt) |
| SSO | ❌ Login par service | ✅ Un seul login |
| URLs | `http://IP:PORT` | `https://user.domain.com/service` |
| Temps installation | ⚡ Rapide | ⚡ Rapide (si DNS prêt) |
| Debugging | ✅ Facile | ⭐ Moyen |
| Idéal pour | Usage personnel/local | Production/multi-users |
| Ajout utilisateur | 🚀 1 commande (détection auto) | 🚀 1 commande (détection auto) |

### 🎯 Architectures

#### Mode Port Direct
```
┌─────────────────────────────────┐
│   Serveur                       │
│                                 │
│  ┌─────────────┐  ┌──────────┐ │
│  │  Authelia   │  │  Plex    │ │
│  │  Port 9091  │  │  32400   │ │
│  └─────────────┘  └──────────┘ │
│                                 │
│  ┌─────────────────────────────┐│
│  │   Services User 1           ││
│  │   Ports: 8090, 8990...      ││
│  └─────────────────────────────┘│
│                                 │
│  ┌─────────────────────────────┐│
│  │   Services User 2           ││
│  │   Ports: 8100, 8991...      ││
│  └─────────────────────────────┘│
└─────────────────────────────────┘
```

#### Mode Traefik + SSL 🆕
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
┌───▼────┐  ┌──────────┐  ┌────────▼───┐
│ Plex   │  │ Services │  │ Services   │
│ Jellyfin  │ User 1   │  │ User 2     │
└────────┘  └──────────┘  └────────────┘

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

## 🌐 Activer Traefik Après Installation

Si vous avez installé en mode port direct et voulez passer à Traefik + SSL :

### Via le Menu (Recommandé)
```bash
cd /opt/seedbox
sudo ./menu.sh
# Sélectionnez : 5. 🌐 Traefik & SSO
# Puis : 1. Installer Traefik
```

### Via Script Direct
```bash
cd /opt/seedbox/scripts
sudo ./setup_traefik.sh votre-domaine.com votre@email.com
```

**⚠️ Important :**
- Configurez d'abord le DNS wildcard `*.votre-domaine.com` → IP serveur
- Ouvrez les ports 80/443 dans le firewall
- Les **nouveaux utilisateurs** créés après installation Traefik auront automatiquement les labels
- Les **utilisateurs existants** nécessitent une régénération des labels :
  ```bash
  sudo ./scripts/generate_traefik_labels.sh
  ```

## 🔄 Migration depuis l'ancienne version

Si vous aviez l'ancienne version sans mode dual :

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

- **Mode dual** : Choisissez entre port direct (simple) ou Traefik + SSL (production)
- **Détection automatique** : Les scripts détectent le mode actif via le fichier `.env`
- **Isolation** : Chaque utilisateur a son espace totalement isolé
- **Quotas** : Appliqués au niveau système (ext4/xfs requis)
- **SSO** : Single Sign-On avec Authelia (mode Traefik uniquement)
- **SSL automatique** : Let's Encrypt avec renouvellement auto (mode Traefik)
- **Services optionnels** : Installation à la carte, à tout moment
- **Configuration** : Simple et maintenable, adaptée au mode choisi

## 💡 Cas d'usage

### Pour un usage personnel/local
```bash
# Installation minimale en mode port direct
sudo ./install.sh
# Répondre "N" à "Utiliser Traefik ?"
# Ne sélectionnez aucun service optionnel
# Ajoutez juste votre utilisateur personnel
# ✅ Simple, rapide, aucun DNS requis
```

### Pour un serveur partagé (quelques amis)
```bash
# Installation avec monitoring en mode Traefik
sudo ./install.sh
# Répondre "o" à "Utiliser Traefik ?" (si DNS configuré)
# Activez Scrutiny et Uptime Kuma pour monitoring
# Ajoutez plusieurs utilisateurs avec des quotas
# ✅ SSL + SSO pour facilité d'accès
```

### Pour production (multi-utilisateurs)
```bash
# Installation complète avec Traefik + backups
sudo ./install.sh
# Répondre "o" à "Utiliser Traefik ?"
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
- **[scripts/README.md](scripts/README.md)** - Documentation des scripts de gestion

### Services avec Auto-Configuration

Les services suivants créent automatiquement le compte administrateur :
- ✓ **Portainer** - Le script collecte les identifiants et crée le compte admin via l'API
- ✓ **Jellyfin** - Auto-configuration via l'API de démarrage Jellyfin

### Services Nécessitant Configuration Manuelle

Ces services requièrent une configuration via l'interface web au premier accès :
- ⚠️ **Uptime Kuma**, **Tautulli**, **Duplicati**

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

**Version:** 3.0 (Mode Dual: Port Direct + Traefik SSO)
**Dernière mise à jour:** 2025-01-14
**Compatibilité vérifiée:** ✅ Debian 12, Ubuntu 22.04/24.04 LTS

### 🆕 Nouveautés v3.0
- ✅ **Mode dual** : Choix entre port direct et Traefik + SSL à l'installation
- ✅ **Détection automatique** : Scripts s'adaptent au mode actif (lecture `.env`)
- ✅ **Single Sign-On** : Un seul login pour tous les services (mode Traefik)
- ✅ **SSL automatique** : Let's Encrypt avec renouvellement auto (mode Traefik)
- ✅ **Gestion mot de passe** : Mise à jour automatique sur tous les services
- ✅ **Menu Traefik** : Nouvelle section dédiée dans le menu interactif
- ✅ **Génération labels** : Automatique lors création utilisateur/service
