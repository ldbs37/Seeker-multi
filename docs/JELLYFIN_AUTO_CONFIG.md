# Configuration Automatique Jellyfin - Utilisateurs et Bibliothèques

## 🎯 Objectif

Automatiser la création de comptes utilisateur Jellyfin et la configuration de leurs bibliothèques média personnelles.

## 🔑 Prérequis : Obtenir la clé API Admin

### 1. Se connecter à Jellyfin en tant qu'admin

Accédez à `http://votre-serveur:8096` et connectez-vous avec le compte admin créé lors de l'installation.

### 2. Générer une clé API

1. Allez dans **Tableau de bord** (icône engrenage en haut à droite)
2. Cliquez sur **Paramètres Avancés** dans le menu de gauche
3. Cliquez sur **Clés API**
4. Cliquez sur **+ Nouvelle clé API**
5. Entrez un nom (ex: "Seedbox Auto Config")
6. Copiez la clé générée et **sauvegardez-la en lieu sûr**

### 3. Sauvegarder la clé API

```bash
# Créer un fichier sécurisé pour stocker la clé
sudo bash -c 'echo "JELLYFIN_API_KEY=votre_cle_api_ici" > /opt/seedbox/.jellyfin_api'
sudo chmod 600 /opt/seedbox/.jellyfin_api
```

## 📦 Utilisation

### Créer un utilisateur Jellyfin manuellement

```bash
cd /opt/seedbox/scripts

# Charger la clé API
source /opt/seedbox/.jellyfin_api

# Créer l'utilisateur
sudo ./configure_jellyfin_user.sh <username> <password> $JELLYFIN_API_KEY
```

**Exemple :**
```bash
source /opt/seedbox/.jellyfin_api
sudo ./configure_jellyfin_user.sh john MyJellyfinPass123 $JELLYFIN_API_KEY
```

### Intégration automatique lors de la création d'utilisateur

Pour que chaque nouvel utilisateur obtienne automatiquement un compte Jellyfin, modifiez `/opt/seedbox/scripts/add_user.sh` :

**Ajoutez à la fin du script (avant le message de succès) :**

```bash
# Configuration Jellyfin automatique (si installé)
if docker ps --format '{{.Names}}' | grep -q "^jellyfin$"; then
    if [ -f "$INSTALL_DIR/.jellyfin_api" ]; then
        log "Configuration du compte Jellyfin..."
        source "$INSTALL_DIR/.jellyfin_api"

        if "$INSTALL_DIR/scripts/configure_jellyfin_user.sh" "$USERNAME" "$PASSWORD" "$JELLYFIN_API_KEY" 2>/dev/null; then
            info "✓ Compte Jellyfin créé et configuré"
        else
            warn "Impossible de créer le compte Jellyfin automatiquement"
            info "Utilisez: sudo ./scripts/configure_jellyfin_user.sh $USERNAME <password> \$JELLYFIN_API_KEY"
        fi
    else
        info "Clé API Jellyfin non configurée"
        info "Voir: docs/JELLYFIN_AUTO_CONFIG.md"
    fi
fi
```

## 🎬 Ce que le script configure automatiquement

### 1. Compte Utilisateur
- ✅ Crée le compte Jellyfin avec le même username/password que le système
- ✅ Configure les permissions (lecture, téléchargement, transcodage)
- ✅ Désactive les droits admin par défaut

### 2. Bibliothèques Média Personnelles
Chaque utilisateur obtient ses propres bibliothèques :

| Bibliothèque | Chemin | Type de contenu |
|--------------|--------|-----------------|
| Séries TV ($USERNAME) | `/opt/seedbox/data/users/$USERNAME/tv` | tvshows |
| Films ($USERNAME) | `/opt/seedbox/data/users/$USERNAME/movies` | movies |
| Livres ($USERNAME) | `/opt/seedbox/data/users/$USERNAME/books` | books |
| Musique ($USERNAME) | `/opt/seedbox/data/users/$USERNAME/music` | music |

### 3. Configuration par Défaut
- **Monitoring en temps réel** des dossiers activé
- **Transcodage** activé (audio + vidéo)
- **Téléchargements** autorisés
- **Suppression de contenu** désactivée
- **Accès distant** activé
- **Max 5 tentatives de connexion** avant blocage

## 🔐 Permissions et Sécurité

### Permissions Utilisateur Standard
```json
{
  "IsAdministrator": false,
  "EnableMediaPlayback": true,
  "EnableAudioPlaybackTranscoding": true,
  "EnableVideoPlaybackTranscoding": true,
  "EnableContentDeletion": false,
  "EnableContentDownloading": true,
  "EnableAllFolders": false
}
```

### Isolation des Bibliothèques
- Chaque utilisateur voit uniquement **ses propres bibliothèques**
- Les chemins sont isolés par utilisateur
- Les permissions système (PUID/PGID) assurent l'isolation des fichiers

## 🔄 Intégration avec Sonarr/Radarr

Les utilisateurs peuvent configurer Sonarr/Radarr pour télécharger directement dans leurs dossiers Jellyfin :

**Sonarr :**
- Root Folder: `/opt/seedbox/data/users/$USERNAME/tv`

**Radarr :**
- Root Folder: `/opt/seedbox/data/users/$USERNAME/movies`

Jellyfin détectera automatiquement les nouveaux contenus.

## 📊 Gestion des Bibliothèques

### Forcer un scan manuel

```bash
# Scanner toutes les bibliothèques
curl -X POST http://localhost:8096/Library/Refresh \
    -H "X-Emby-Token: $JELLYFIN_API_KEY"

# Scanner une bibliothèque spécifique
curl -X POST "http://localhost:8096/Items/<LIBRARY_ID>/Refresh" \
    -H "X-Emby-Token: $JELLYFIN_API_KEY"
```

### Lister tous les utilisateurs

```bash
curl http://localhost:8096/Users \
    -H "X-Emby-Token: $JELLYFIN_API_KEY" | jq '.[].Name'
```

## 🛠️ Dépannage

### Erreur : "Jellyfin n'est pas accessible"
```bash
# Vérifier que Jellyfin est démarré
docker ps | grep jellyfin

# Vérifier les logs
docker logs jellyfin
```

### Erreur : "Clé API invalide"
```bash
# Régénérer une nouvelle clé API dans l'interface Jellyfin
# Mettre à jour le fichier
sudo bash -c 'echo "JELLYFIN_API_KEY=nouvelle_cle" > /opt/seedbox/.jellyfin_api'
```

### Bibliothèques vides
```bash
# Vérifier les permissions des dossiers
ls -la /opt/seedbox/data/users/<username>/

# S'assurer que l'utilisateur est propriétaire
sudo chown -R $(id -u <username>):$(id -u <username>) /opt/seedbox/data/users/<username>/
```

## 📚 Ressources

- [Jellyfin API Documentation](https://api.jellyfin.org/)
- [Jellyfin User Management](https://jellyfin.org/docs/general/server/users/)
- [Jellyfin Libraries](https://jellyfin.org/docs/general/server/libraries.html)

## ⚠️ Limitations

1. **API Key requise** : Nécessite une clé API admin Jellyfin
2. **Permissions statiques** : Les permissions sont définies au moment de la création
3. **Pas de SSO** : L'utilisateur doit se connecter séparément à Jellyfin (pas de Single Sign-On avec Authelia)

## 🚀 Améliorations Futures

- [ ] Synchronisation automatique des mots de passe Authelia ↔ Jellyfin
- [ ] SSO via Jellyfin LDAP/OpenID plugin + Authelia
- [ ] Configuration des profils de transcodage par utilisateur
- [ ] Quotas de stockage par bibliothèque
- [ ] Notifications webhook lors d'ajout de contenu
