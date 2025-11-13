# Scripts de Gestion Seedbox

Ce dossier contient les scripts de gestion pour votre installation seedbox multi-utilisateurs.

## 📋 Scripts disponibles

### 👤 Gestion des utilisateurs

#### `add_user.sh`
Ajoute un nouvel utilisateur avec tous ses services.

**Usage:**
```bash
sudo ./add_user.sh <username> <password> <email> [quota_gb]
```

**Exemple:**
```bash
sudo ./add_user.sh john MySecurePass123 john@example.com 500
```

**Services créés automatiquement:**
- qBittorrent (téléchargements)
- Sonarr (séries TV)
- Radarr (films)
- Readarr (livres)
- Bazarr (sous-titres)
- Prowlarr (indexeurs)
- Overseerr (requêtes)
- Homarr (dashboard)
- Calibre-web (bibliothèque ebooks)
- Filebrowser (gestionnaire de fichiers)

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
sudo ./update_quota.sh john 1000
```

---

### 🔧 Gestion des services optionnels

#### `add_service.sh`
Installe un service optionnel supplémentaire.

**Usage:**
```bash
sudo ./add_service.sh <service_name>
```

**Services disponibles:**

| Service | Description | Port |
|---------|-------------|------|
| `scrutiny` | Monitoring des disques durs (S.M.A.R.T.) | 8080 |
| `uptime-kuma` | Surveillance de disponibilité des services | 3001 |
| `watchtower` | Mises à jour automatiques des conteneurs | - |
| `duplicati` | Système de backup automatique | 8200 |

**Exemples:**
```bash
# Installer le monitoring des disques
sudo ./add_service.sh scrutiny

# Installer le système de backup
sudo ./add_service.sh duplicati

# Installer la surveillance de disponibilité
sudo ./add_service.sh uptime-kuma

# Activer les mises à jour automatiques
sudo ./add_service.sh watchtower
```

---

## 🚀 Exemples d'utilisation

### Ajouter un utilisateur complet
```bash
# Créer l'utilisateur "alice" avec 750GB de quota
sudo ./add_user.sh alice SecurePassword456 alice@example.com 750

# Vérifier que les services sont démarrés
docker ps | grep alice
```

### Gérer les quotas
```bash
# Vérifier le quota actuel
sudo quota -v -u alice

# Augmenter le quota à 1TB
sudo ./update_quota.sh alice 1000
```

### Installer des services optionnels
```bash
# Monitoring des disques
sudo ./add_service.sh scrutiny

# Système de backup
sudo ./add_service.sh duplicati
```

### Supprimer un utilisateur
```bash
# Supprimer complètement (avec données)
sudo ./remove_user.sh alice

# Ou garder les données pour restauration ultérieure
sudo ./remove_user.sh alice --keep-data
```

---

## 📊 Ports par utilisateur

Chaque utilisateur se voit attribuer des ports uniques basés sur son UID:

| Service | Port de base | Calcul |
|---------|--------------|--------|
| qBittorrent | 8080 | 8080 + (UID - 1000) * 10 |
| Sonarr | 8989 | 8989 + (UID - 1000) |
| Radarr | 7878 | 7878 + (UID - 1000) |
| Readarr | 8787 | 8787 + (UID - 1000) |
| Bazarr | 6767 | 6767 + (UID - 1000) |
| Prowlarr | 9696 | 9696 + (UID - 1000) |
| Overseerr | 5055 | 5055 + (UID - 1000) |
| Homarr | 7575 | 7575 + (UID - 1000) |
| Calibre | 8083 | 8083 + (UID - 1000) |
| Filebrowser | 8081 | 8081 + (UID - 1000) |

**Exemple:** Pour le premier utilisateur (UID 1001):
- qBittorrent: 8090
- Sonarr: 8990
- Radarr: 7879
- etc.

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
docker logs qbittorrent-john
```

### Redémarrer tous les services d'un utilisateur
```bash
docker restart $(docker ps --format '{{.Names}}' | grep username)
```

### Vérifier l'utilisation du quota
```bash
sudo quota -v -u username
```

### Réinitialiser un mot de passe utilisateur
1. Modifier le fichier `/opt/seedbox/authelia/users_database.yml`
2. Générer un nouveau hash:
   ```bash
   docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password "NewPassword"
   ```
3. Redémarrer Authelia:
   ```bash
   docker restart authelia
   ```

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
├── <service>/
│   └── <username>/
│       └── (configuration)
└── docker-compose.yml
```

---

## ⚠️ Notes importantes

1. **Sauvegardez** toujours avant de supprimer un utilisateur
2. Les scripts modifient le fichier `docker-compose.yml` - un backup est créé automatiquement (`.bak`)
3. Utilisez `--keep-data` lors de la suppression si vous prévoyez de recréer l'utilisateur
4. Les quotas nécessitent que le système de quotas soit activé sur votre partition
5. Vérifiez l'espace disque disponible avant d'ajouter des utilisateurs

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

### Vérifier l'espace disque
```bash
df -h
du -sh /opt/seedbox/data/users/*
```
