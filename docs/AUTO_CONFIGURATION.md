# Auto-Configuration des Services

Ce document liste les services qui supportent l'auto-configuration (création automatique du compte admin) et ceux qui nécessitent une configuration manuelle lors du premier accès.

## Services avec Auto-Configuration ✓

Ces services créent automatiquement le compte administrateur pendant l'installation :

### Portainer (Gestion Docker)
- **Port:** 9000
- **Auto-configuration:** ✓ Oui
- **Méthode:** API REST (`POST /api/users/admin/init`)
- **Détails:** Le script collecte les identifiants de manière interactive et crée le compte admin automatiquement via l'API
- **Exigences:**
  - Nom d'utilisateur (défaut: admin)
  - Mot de passe (minimum 12 caractères)

### Jellyfin (Streaming)
- **Port:** 8096
- **Auto-configuration:** ✓ Oui
- **Méthode:** API de démarrage (`POST /Startup/User` + `POST /Startup/Complete`)
- **Détails:** Le script collecte les identifiants de manière interactive et complète le wizard de démarrage via l'API
- **Exigences:**
  - Nom d'utilisateur (défaut: admin)
  - Mot de passe (minimum 8 caractères)

---

## Services Requérant Configuration Manuelle ⚠️

Ces services nécessitent une configuration manuelle lors du premier accès via l'interface web :

### Uptime Kuma (Monitoring Uptime)
- **Port:** 3001
- **Auto-configuration:** ✗ Non supporté
- **Raison:** Pas d'API de création d'utilisateur initial, pas de variables d'environnement
- **Configuration:** Accédez à `http://votre-serveur:3001` et créez le compte admin via l'interface web
- **Note:** Feature requests ouverts (#1185, #4277) pour ajouter cette fonctionnalité

### Tautulli (Statistiques Plex)
- **Port:** 8181
- **Auto-configuration:** ✗ Non supporté nativement
- **Raison:** Pas de variables d'environnement pour la configuration initiale
- **Configuration:** Accédez à `http://votre-serveur:8181` et suivez le wizard de configuration
- **Alternative:** Possibilité de pré-configurer le fichier `config.ini` (non implémenté)

### Dashdot (Monitoring Système)
- **Port:** 3002
- **Auto-configuration:** N/A (pas d'authentification requise)
- **Configuration:** Accès direct sans authentification

### Scrutiny (Monitoring Disques)
- **Port:** 8080
- **Auto-configuration:** N/A (pas d'authentification par défaut)
- **Configuration:** Accès direct

### Duplicati (Backups)
- **Port:** 8200
- **Auto-configuration:** ✗ Non supporté
- **Configuration:** Accédez à `http://votre-serveur:8200` et configurez lors du premier accès

---

## Services Non Configurables (Pas d'Interface Admin)

Ces services ne nécessitent pas de configuration d'utilisateur :

- **Watchtower** (Mises à jour automatiques) - Pas d'interface web
- **Plex** - Utilise l'authentification Plex (compte plex.tv requis)

---

## Workflow d'Installation

### Lors de l'installation initiale (`install.sh`)

Les services avec auto-configuration demandent les identifiants de manière interactive :

```bash
Installer Portainer (gestion Docker web) ? (o/N): o

Configuration Portainer:
Nom d'utilisateur admin [admin]: admin
Mot de passe admin (min 12 caractères): ************
Confirmez le mot de passe: ************

✓ Compte administrateur Portainer créé automatiquement
```

```bash
Installer Jellyfin (alternative open-source à Plex) ? (o/N): o

Configuration Jellyfin:
Nom d'utilisateur admin [admin]: admin
Mot de passe admin (min 8 caractères): ********
Confirmez le mot de passe: ********

✓ Compte administrateur Jellyfin créé automatiquement
```

### Lors de l'ajout post-installation (`add_service.sh`)

Même fonctionnement pour les services supportant l'auto-configuration :

```bash
sudo ./add_service.sh portainer
sudo ./add_service.sh jellyfin
```

---

## Recherche et Limitations

### Analyse Swizzin

Le projet [Swizzin](https://github.com/swizzin/swizzin) a été analysé pour identifier les meilleures pratiques :

**Points clés :**
- Architecture modulaire avec scripts par application
- Système de commandes `box` pour l'installation/suppression
- Support de l'installation non-interactive avec variables d'environnement
- Chaque application a son propre script d'installation

**Leçons appliquées :**
- Séparation claire entre services système et services utilisateur
- Scripts modulaires (`add_service.sh`, `add_user_service.sh`)
- Auto-configuration quand l'API le permet
- Documentation claire des limitations

### Limitations Techniques

**Uptime Kuma :**
- Issue GitHub #4277 : "Uptime Kuma is currently next-to-impossible to declaratively configure"
- Pas de support de variables d'environnement pour l'utilisateur initial
- Workaround possible : Manipulation de la base SQLite (non recommandé)

**Tautulli :**
- Issue GitHub #2309 : Demande de support des variables d'environnement
- Configuration stockée dans `config.ini`
- Pré-configuration possible mais non implémentée (complexe)

---

## Recommandations

### Pour les Utilisateurs

1. **Installation initiale** : Préférez installer tous les services en une fois pour bénéficier de l'auto-configuration
2. **Services manuels** : Notez les URLs et configurez-les immédiatement après l'installation
3. **Sécurité** : Utilisez des mots de passe forts et uniques pour chaque service

### Pour le Développement Futur

1. **Uptime Kuma** : Surveiller les issues #1185 et #4277 pour le support des variables d'environnement
2. **Tautulli** : Envisager la pré-configuration du `config.ini` si le besoin se fait sentir
3. **Autres services** : Évaluer au cas par cas en fonction des demandes utilisateur

---

## Résumé

| Service | Auto-Config | Port | Configuration |
|---------|------------|------|---------------|
| **Portainer** | ✓ | 9000 | Automatique via API |
| **Jellyfin** | ✓ | 8096 | Automatique via API |
| **Uptime Kuma** | ✗ | 3001 | Manuelle (web UI) |
| **Tautulli** | ✗ | 8181 | Manuelle (web UI) |
| **Dashdot** | N/A | 3002 | Pas d'auth requise |
| **Scrutiny** | N/A | 8080 | Pas d'auth par défaut |
| **Duplicati** | ✗ | 8200 | Manuelle (web UI) |
| **Watchtower** | N/A | - | Pas d'interface |
| **Plex** | - | 32400 | Compte plex.tv |

---

**Dernière mise à jour :** 2025-01-13
**Version :** 2.2 (Auto-configuration Jellyfin ajoutée)
