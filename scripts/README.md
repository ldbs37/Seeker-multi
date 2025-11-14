# Scripts de Gestion Seedbox

Ce dossier contient les scripts de gestion pour votre installation seedbox multi-utilisateurs.

## 📋 Scripts disponibles

### 👤 Gestion des utilisateurs

#### `add_user.sh`
Ajoute un nouvel utilisateur avec les services de base (qBittorrent, Homarr, Filebrowser).

**Usage:**
```bash
sudo ./add_user.sh <username> <password> <email> [quota_gb] [--with-services]
```

**Services de base (toujours installés) :**
- qBittorrent (client torrent)
- Homarr (dashboard personnel)
- Filebrowser (gestionnaire de fichiers)

**Exemples:**
```bash
# Installation basique (services de base seulement)
sudo ./add_user.sh john MySecurePass123 john@example.com 500

# Installation interactive (propose l'installation des services optionnels)
sudo ./add_user.sh john MySecurePass123 john@example.com 500 --with-services
```

---

#### `add_user_service.sh`
Ajoute un service optionnel à un utilisateur existant.

**Usage:**
```bash
sudo ./add_user_service.sh <username> <service>
```

**Services disponibles:**
- `sonarr` - Gestion de séries TV
- `radarr` - Gestion de films
- `readarr` - Gestion de livres
- `bazarr` - Gestion de sous-titres
- `prowlarr` - Gestion d'indexeurs
- `overseerr` - Système de requêtes
- `calibre` - Bibliothèque ebooks

**Exemples:**
```bash
# Ajouter Sonarr à l'utilisateur john
sudo ./add_user_service.sh john sonarr

# Ajouter Radarr
sudo ./add_user_service.sh john radarr

# Ajouter plusieurs services
sudo ./add_user_service.sh john prowlarr
sudo ./add_user_service.sh john overseerr
```

---

#### `list_user_services.sh`
Liste tous les services d'un utilisateur (installés et disponibles).

**Usage:**
```bash
sudo ./list_user_services.sh <username>
```

**Exemple:**
```bash
sudo ./list_user_services.sh john
```

**Affichage:**
```
Services installés:
  ✓ qbittorrent - Port: 8090 - Running
  ✓ homarr - Port: 7576 - Running
  ✓ sonarr - Port: 8990 - Running

Services disponibles (non installés):
  ○ radarr - Port: 7879
  ○ readarr - Port: 8788
  ○ bazarr - Port: 6768
```

---

#### `remove_user.sh`
Supprime un utilisateur et tous ses services.

**Usage:**
```bash
sudo ./remove_user.sh <username> [--keep-data]
```

**Exemples:**
```bash
# Suppression complète (données incluses)
sudo ./remove_user.sh john

# Suppression en conservant les données
sudo ./remove_user.sh john --keep-data
```

---

#### `update_quota.sh`
Modifie le quota de stockage d'un utilisateur.

**Usage:**
```bash
sudo ./update_quota.sh <username> <quota_gb>
```

**Exemple:**
```bash
sudo ./update_quota.sh john 1000  # 1TB
```

---

### 🔧 Gestion des services système

#### `add_service.sh`
Installe un service système optionnel.

**Usage:**
```bash
sudo ./add_service.sh <service_name>
```

**Services disponibles:**

| Service | Description | Port | Commande |
|---------|-------------|------|----------|
| `plex` | Serveur de streaming média | 32400 | `sudo ./add_service.sh plex` |
| `jellyfin` | Alternative open-source à Plex | 8096 | `sudo ./add_service.sh jellyfin` |
| `scrutiny` | Monitoring S.M.A.R.T. des disques | 8080 | `sudo ./add_service.sh scrutiny` |
| `uptime-kuma` | Surveillance de disponibilité | 3001 | `sudo ./add_service.sh uptime-kuma` |
| `watchtower` | Mises à jour automatiques | - | `sudo ./add_service.sh watchtower` |
| `duplicati` | Système de backup | 8200 | `sudo ./add_service.sh duplicati` |

**Exemples:**
```bash
# Installer Jellyfin (alternative à Plex)
sudo ./add_service.sh jellyfin

# Installer le monitoring des disques
sudo ./add_service.sh scrutiny

# Installer le système de backup
sudo ./add_service.sh duplicati
```

---

## 🚀 Workflow recommandé

### Ajouter un nouvel utilisateur

**Option 1: Installation minimale (recommandée)**
```bash
# 1. Créer l'utilisateur avec services de base
sudo ./add_user.sh alice SecurePass456 alice@example.com 750

# 2. Ajouter les services dont l'utilisateur a besoin
sudo ./add_user_service.sh alice sonarr
sudo ./add_user_service.sh alice radarr
sudo ./add_user_service.sh alice prowlarr
```

**Option 2: Installation interactive**
```bash
# Le script proposera d'installer chaque service optionnel
sudo ./add_user.sh alice SecurePass456 alice@example.com 750 --with-services
```

### Vérifier les services d'un utilisateur

```bash
# Lister tous les services
sudo ./list_user_services.sh alice

# Vérifier les conteneurs Docker
docker ps | grep alice
```

### Modifier la configuration

```bash
# Augmenter le quota
sudo ./update_quota.sh alice 2000

# Ajouter un nouveau service
sudo ./add_user_service.sh alice overseerr
```

---

## 📊 Attribution des ports

Chaque utilisateur obtient des ports uniques calculés depuis son UID:

| Service | Formule | User1 (UID 1001) | User2 (UID 1002) |
|---------|---------|------------------|------------------|
| **Services de base** |||
| qBittorrent | 8080 + (UID-1000)*10 | 8090 | 8100 |
| Homarr | 7575 + (UID-1000) | 7576 | 7577 |
| Filebrowser | 8081 + (UID-1000) | 8082 | 8083 |
| **Services optionnels** |||
| Sonarr | 8989 + (UID-1000) | 8990 | 8991 |
| Radarr | 7878 + (UID-1000) | 7879 | 7880 |
| Readarr | 8787 + (UID-1000) | 8788 | 8789 |
| Bazarr | 6767 + (UID-1000) | 6768 | 6769 |
| Prowlarr | 9696 + (UID-1000) | 9697 | 9698 |
| Overseerr | 5055 + (UID-1000) | 5056 | 5057 |
| Calibre | 8083 + (UID-1000) | 8084 | 8085 |

---

## 🎯 Cas d'usage

### Utilisateur basique (downloads seulement)

```bash
# Créer avec services de base uniquement
sudo ./add_user.sh bob Password123 bob@mail.com 300

# Bob obtient : qBittorrent, Homarr, Filebrowser
```

### Utilisateur séries TV

```bash
# Services de base + Sonarr + Prowlarr
sudo ./add_user.sh alice Pass456 alice@mail.com 500
sudo ./add_user_service.sh alice sonarr
sudo ./add_user_service.sh alice prowlarr
sudo ./add_user_service.sh alice bazarr
```

### Utilisateur complet (films + séries)

```bash
# Installation interactive
sudo ./add_user.sh john Pass789 john@mail.com 1000 --with-services

# Ou manuellement
sudo ./add_user.sh john Pass789 john@mail.com 1000
sudo ./add_user_service.sh john sonarr
sudo ./add_user_service.sh john radarr
sudo ./add_user_service.sh john prowlarr
sudo ./add_user_service.sh john bazarr
sudo ./add_user_service.sh john overseerr
```

---

## 🔐 Sécurité

- Tous les scripts requièrent les privilèges root (`sudo`)
- Les mots de passe sont hashés avec Argon2 pour Authelia
- Chaque utilisateur a son propre UID/GID système
- Les données sont isolées par utilisateur
- Les quotas sont appliqués au niveau système

---

## 🛠️ Dépannage

### Vérifier les logs d'un service

```bash
docker logs <service-username>
# Exemple:
docker logs sonarr-john
```

### Redémarrer un service utilisateur

```bash
docker restart <service-username>
# Exemple:
docker restart radarr-alice
```

### Vérifier l'utilisation du quota

```bash
sudo quota -v -u <username>
```

### Service ne démarre pas

```bash
# Vérifier les logs
docker logs <service-username>

# Vérifier si le port est libre
sudo netstat -tulpn | grep <port>

# Redémarrer le service
docker restart <service-username>
```

---

## 💡 Conseils

### Optimisation de l'espace

- Commencez toujours par les services de base
- Ajoutez les services optionnels uniquement si nécessaire
- Utilisez `list_user_services.sh` pour voir ce qui est installé

### Performance

- Les services de base (qBittorrent, Homarr, Filebrowser) sont légers
- Sonarr/Radarr peuvent consommer plus de RAM avec de grandes bibliothèques
- Prowlarr est recommandé si l'utilisateur utilise Sonarr/Radarr

### Organisation

- Créez d'abord l'utilisateur avec services de base
- Testez l'accès et le fonctionnement
- Ajoutez les services optionnels progressivement
- Utilisez `list_user_services.sh` pour documenter la configuration

---

## 📁 Structure des dossiers

```
/opt/seedbox/
├── data/
│   └── users/
│       └── <username>/
│           ├── downloads/
│           ├── movies/
│           ├── tv/
│           └── books/
├── qbittorrent/<username>/
├── homarr/<username>/
├── filebrowser/<username>/
├── sonarr/<username>/       (optionnel)
├── radarr/<username>/       (optionnel)
├── readarr/<username>/      (optionnel)
├── bazarr/<username>/       (optionnel)
├── prowlarr/<username>/     (optionnel)
├── overseerr/<username>/    (optionnel)
├── calibre/<username>/      (optionnel)
└── docker-compose.yml
```

---

## 🔄 Maintenance

### Mettre à jour tous les conteneurs

```bash
cd /opt/seedbox
docker-compose pull
docker-compose up -d
```

### Nettoyer les conteneurs arrêtés

```bash
docker system prune -a
```

### Vérifier l'espace disque par utilisateur

```bash
du -sh /opt/seedbox/data/users/*
```

---

## 📞 Support

Pour toute question :
- Consultez le README principal : `../README.md`
- Vérifiez les logs : `docker-compose logs`
- Testez avec `list_user_services.sh`

---

**Version:** 2.1 (Services modulaires)
**Dernière mise à jour:** 2025
