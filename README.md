# Seedbox Multi-Utilisateurs - Version Simplifiée

Une solution **simple et efficace** de seedbox multi-utilisateurs avec authentification centralisée et gestion facile des utilisateurs.

## 🎯 Caractéristiques

### ✨ Architecture Simplifiée
- **Sans Traefik** - Architecture réseau simple avec ports directs
- **Authentification centralisée** - Authelia pour la gestion des utilisateurs
- **Services optionnels** - Installez uniquement ce dont vous avez besoin
- **Gestion facilitée** - Scripts dédiés pour toutes les opérations

### 📋 Services Par Utilisateur
- 🖥️ **Homarr** - Dashboard personnel
- 📥 **qBittorrent + VueTorrent** - Client torrent
- 📺 **Sonarr** - Séries TV
- 🎬 **Radarr** - Films
- 📚 **Readarr** - Livres
- 💬 **Bazarr** - Sous-titres
- 🔍 **Prowlarr** - Indexeurs
- 📝 **Overseerr** - Requêtes
- 📖 **Calibre-web** - Bibliothèque ebooks
- 📂 **Filebrowser** - Gestionnaire de fichiers

### 🛡️ Services Système
- 🔐 **Authelia** - Authentification centralisée
- 🎥 **Plex** - Serveur de streaming média
- 🚦 **FlareSolverr** - Bypass Cloudflare

### 🔧 Services Optionnels
- 💽 **Scrutiny** - Monitoring des disques (S.M.A.R.T.)
- 📊 **Uptime Kuma** - Surveillance de disponibilité
- 🔄 **Watchtower** - Mises à jour automatiques
- 💾 **Duplicati** - Système de backup

### 🔒 Sécurité
- Authentification centralisée (Authelia)
- Protection fail2ban
- Espaces utilisateurs isolés
- Quotas par utilisateur
- Pare-feu UFW configuré

## 🔧 Prérequis

### Matériel Recommandé
- **CPU:** 4 cœurs minimum
- **RAM:** 8 GB minimum
- **Stockage:** 20 GB minimum pour le système
- **Connexion:** 100 Mbps minimum

### Système
- Ubuntu 22.04 LTS ou Debian 12
- Un nom de domaine (optionnel)
- Accès root

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
   - Nom de domaine
   - Email administrateur

2. **Utilisateur administrateur**
   - Nom d'utilisateur
   - Mot de passe sécurisé

3. **Services optionnels**
   - Scrutiny (monitoring disques)
   - Uptime Kuma (monitoring uptime)
   - Watchtower (mises à jour auto)
   - Duplicati (backups)

4. **Utilisateurs initiaux**
   - Ajoutez vos premiers utilisateurs
   - Définissez les quotas

## 🎮 Menu Interactif de Gestion

Pour une gestion simplifiée, utilisez le menu interactif :

```bash
cd /opt/seedbox
sudo ./menu.sh
```

Le menu vous permet de :
- 👥 **Gérer les utilisateurs** - Ajouter, supprimer, modifier quotas
- 🔧 **Gérer les services** - Installer, supprimer des services système
- 📊 **Monitoring** - État système, services, quotas, logs
- 🛠️ **Maintenance** - Redémarrages, mises à jour, sauvegardes

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
sudo ./add_user.sh <username> <password> <email> [quota_gb]
```

**Exemple:**
```bash
sudo ./add_user.sh john MySecurePass123 john@example.com 500
```

Chaque utilisateur obtient **automatiquement** tous ses services configurés !

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

## 🔧 Services Optionnels

### Installer un service après l'installation

```bash
cd /opt/seedbox/scripts
sudo ./add_service.sh <service_name>
```

**Services disponibles:**

| Service | Commande | Description | Port |
|---------|----------|-------------|------|
| Scrutiny | `sudo ./add_service.sh scrutiny` | Monitoring S.M.A.R.T. des disques | 8080 |
| Uptime Kuma | `sudo ./add_service.sh uptime-kuma` | Surveillance de disponibilité | 3001 |
| Watchtower | `sudo ./add_service.sh watchtower` | Mises à jour automatiques | - |
| Duplicati | `sudo ./add_service.sh duplicati` | Système de backup | 8200 |

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

### Services Système
- **Authelia:** `http://votre-serveur:9091`
- **Plex:** `http://votre-serveur:32400/web`
- **FlareSolverr:** `http://votre-serveur:8191`

### Services Optionnels
- **Scrutiny:** `http://votre-serveur:8080`
- **Uptime Kuma:** `http://votre-serveur:3001`
- **Duplicati:** `http://votre-serveur:8200`

### Services Utilisateur

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

### ✅ Par rapport à la version complexe

| Caractéristique | Avant (Traefik) | Maintenant |
|-----------------|-----------------|------------|
| Complexité | Élevée | Simple |
| Configuration réseau | Reverse proxy complexe | Ports directs |
| Certificats SSL | Let's Encrypt auto | Manuel (optionnel) |
| Temps d'installation | Long | Rapide |
| Debugging | Difficile | Facile |
| Ajout d'utilisateur | Complexe | 1 commande |
| Services optionnels | Tous installés | À la carte |

### 🎯 Architecture Simplifiée

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

## 🔄 Migration depuis l'ancienne version

Si vous aviez l'ancienne version avec Traefik :

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

- Chaque utilisateur a son espace totalement isolé
- Les quotas sont appliqués au niveau système
- L'authentification est centralisée via Authelia
- Les services optionnels peuvent être ajoutés à tout moment
- La configuration est simple et maintenable

## 💡 Cas d'usage

### Pour un usage personnel
```bash
# Installation minimale
sudo ./install.sh
# Ne sélectionnez aucun service optionnel
# Ajoutez juste votre utilisateur personnel
```

### Pour un serveur partagé
```bash
# Installation complète avec monitoring
sudo ./install.sh
# Activez Scrutiny et Uptime Kuma
# Ajoutez plusieurs utilisateurs avec des quotas
```

### Pour production
```bash
# Installation avec backups et mises à jour auto
sudo ./install.sh
# Activez Duplicati et Watchtower
# Configurez les quotas appropriés
```

## 📚 Documentation

Pour plus d'informations, consultez la documentation dans `/docs` :

- **[MENU.md](docs/MENU.md)** - Guide complet du menu interactif de gestion
- **[AUTO_CONFIGURATION.md](docs/AUTO_CONFIGURATION.md)** - Guide sur l'auto-configuration des services (Portainer, Jellyfin)
- **[INSTALLATION.md](docs/INSTALLATION.md)** - Guide d'installation détaillé
- **[scripts/README.md](scripts/README.md)** - Documentation des scripts de gestion

### Services avec Auto-Configuration

Les services suivants créent automatiquement le compte administrateur :
- ✓ **Portainer** - Le script collecte les identifiants et crée le compte admin via l'API
- ✓ **Jellyfin** - Auto-configuration via l'API de démarrage Jellyfin

### Services Nécessitant Configuration Manuelle

Ces services requièrent une configuration via l'interface web au premier accès :
- ⚠️ **Uptime Kuma**, **Organizr**, **Tautulli**, **Duplicati**

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

**Version:** 2.3 (Menu Interactif de Gestion)
**Dernière mise à jour:** 2025-01-13
