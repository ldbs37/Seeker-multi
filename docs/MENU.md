# Menu Interactif de Gestion

Le menu interactif (`menu.sh`) est l'interface centralisée pour gérer votre installation Seedbox Multi-Utilisateurs. Il regroupe toutes les opérations courantes dans une interface conviviale et facile à utiliser.

## 🚀 Lancement

```bash
cd /opt/seedbox
sudo ./menu.sh
```

> **Note:** Le menu doit être exécuté avec les privilèges root (sudo) car il gère les utilisateurs système et les conteneurs Docker.

## 📋 Structure du Menu

### Menu Principal

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

## 👥 1. Gestion des Utilisateurs

Ce sous-menu permet de gérer les utilisateurs de la seedbox :

### 1.1 Ajouter un utilisateur

Crée un nouvel utilisateur avec ses services de base (qBittorrent, Homarr, Filebrowser).

**Informations demandées:**
- Nom d'utilisateur
- Mot de passe
- Email
- Quota en GB (par défaut: 500)
- Option pour installer des services supplémentaires de manière interactive

**Exemple d'utilisation:**
```
Nom d'utilisateur: john
Mot de passe: ********
Email: john@example.com
Quota (GB) [500]: 1000
Installer les services supplémentaires de manière interactive ? (o/N): o
```

### 1.2 Supprimer un utilisateur

Supprime un utilisateur et tous ses conteneurs Docker.

**Options:**
- Supprimer complètement (utilisateur + données)
- Conserver les données de l'utilisateur

**Confirmation requise:** Pour une suppression complète, vous devez taper "supprimer" pour confirmer.

### 1.3 Modifier le quota d'un utilisateur

Change le quota d'espace disque alloué à un utilisateur.

**Informations demandées:**
- Nom d'utilisateur
- Nouveau quota en GB

### 1.4 Ajouter un service à un utilisateur

Ajoute un service spécifique à un utilisateur existant.

**Services disponibles:**
- `sonarr` - Gestion des séries TV
- `radarr` - Gestion des films
- `readarr` - Gestion des livres
- `bazarr` - Gestion des sous-titres
- `prowlarr` - Gestion des indexeurs
- `overseerr` - Système de requêtes
- `calibre` - Bibliothèque d'ebooks

### 1.5 Lister les services d'un utilisateur

Affiche tous les services d'un utilisateur avec leur état (actif/arrêté) et leurs ports.

### 1.6 Afficher les quotas

Affiche l'utilisation des quotas pour tous les utilisateurs.

## 🔧 2. Gestion des Services Système

Ce sous-menu permet de gérer les services partagés de la seedbox.

### 2.1 Ajouter un service système

Installe un nouveau service système optionnel.

**Services disponibles:**

**Streaming:**
- `plex` - Serveur de streaming multimédia
- `jellyfin` - Alternative open-source à Plex (avec auto-configuration)

**Monitoring & Dashboards:**
- `scrutiny` - Monitoring des disques S.M.A.R.T.
- `uptime-kuma` - Monitoring de disponibilité
- `dashdot` - Dashboard de monitoring système
- `tautulli` - Statistiques pour Plex

**Gestion & Organisation:**
- `portainer` - Interface web de gestion Docker (avec auto-configuration)

**Maintenance:**
- `watchtower` - Mises à jour automatiques des conteneurs
- `duplicati` - Système de backup

> **Note:** Les services Portainer et Jellyfin créent automatiquement le compte administrateur pendant l'installation.

### 2.2 Supprimer un service système

Arrête et supprime un service système.

**Confirmation requise:** Vous devez confirmer la suppression (o/N).

### 2.3 Voir l'état des services

Affiche l'état de tous les services (système et utilisateurs) avec indication visuelle :
- 🟢 Service actif
- 🔴 Service arrêté

### 2.4 Voir les logs d'un service

Affiche les 50 dernières lignes de logs d'un service spécifique.

**Utilisation:** Entrez le nom exact du conteneur (ex: `portainer`, `qbittorrent-john`)

## 📊 3. Monitoring

Ce sous-menu fournit des informations sur l'état du système et des services.

### 3.1 État du système

Affiche les statistiques globales du système :
- **Docker:** Nombre de conteneurs actifs/arrêtés
- **Espace disque:** Utilisation de `/opt/seedbox`
- **Mémoire RAM:** Utilisation actuelle
- **CPU:** Charge moyenne (load average)

**Exemple de sortie:**
```
📊 État du Système

Docker:
  Conteneurs actifs: 15
  Conteneurs arrêtés: 2

Espace Disque:
  Utilisé: 450G / 2.0T (23%)

Mémoire RAM:
  Utilisée: 4.2G / 16G

Charge CPU:
  Load average: 0.45, 0.52, 0.48
```

### 3.2 État des services

Liste tous les services avec leur état :
- Services système (authelia, portainer, jellyfin, etc.)
- Services utilisateurs (groupés par utilisateur)

### 3.3 Liste des utilisateurs

Affiche tous les utilisateurs configurés avec :
- Nombre de services actifs/total
- Quota d'espace disque

**Exemple:**
```
Utilisateurs configurés:
  • john - Services: 7/10 actifs - Quota: 450G
  • alice - Services: 3/5 actifs - Quota: 200G
```

### 3.4 Quotas utilisateurs

Affiche les détails complets des quotas pour chaque utilisateur avec l'utilisation actuelle.

### 3.5 Logs d'un service

Identique à "2.4 Voir les logs d'un service" pour un accès rapide depuis le monitoring.

## 🛠️ 4. Maintenance

Ce sous-menu contient les opérations de maintenance du système.

### 4.1 Redémarrer les services

Trois options disponibles :

**1. Redémarrer tous les services**
- Redémarre tous les conteneurs Docker
- Peut prendre quelques minutes

**2. Redémarrer un service spécifique**
- Redémarre un seul conteneur
- Utile pour appliquer une configuration

**3. Redémarrer les services d'un utilisateur**
- Redémarre tous les conteneurs d'un utilisateur spécifique
- Utile après modification de configuration utilisateur

### 4.2 Mettre à jour les conteneurs

Met à jour tous les conteneurs vers les dernières versions disponibles.

**Processus:**
1. Téléchargement des nouvelles images Docker
2. Redémarrage des conteneurs avec les nouvelles versions

**Confirmation requise:** Cette opération redémarre tous les services.

### 4.3 Nettoyage Docker

Libère de l'espace disque en supprimant :
- Conteneurs arrêtés
- Images Docker non utilisées
- Volumes Docker non utilisés
- Réseaux Docker non utilisés

**⚠️ Attention:** Assurez-vous de ne pas avoir de conteneurs temporairement arrêtés que vous souhaitez conserver.

### 4.4 Créer une sauvegarde

Crée une archive compressée de la configuration.

**Éléments sauvegardés:**
- Configuration Authelia
- Fichier docker-compose.yml
- Scripts de gestion
- Configurations des services

**Éléments exclus:** (pour gagner de l'espace)
- Cache des applications
- Données utilisateurs (downloads, media)

**Emplacement:** `/var/backups/seedbox/seedbox-backup-YYYYMMDD-HHMMSS.tar.gz`

## 🎨 Interface Utilisateur

### Codes Couleur

Le menu utilise des codes couleur pour améliorer la lisibilité :

- 🟢 **Vert** : Messages de succès, logs normaux
- 🔴 **Rouge** : Erreurs
- 🟡 **Jaune** : Avertissements
- 🔵 **Bleu** : Informations
- 🟣 **Magenta** : Titres de sections
- 🔷 **Cyan** : En-têtes, labels

### Navigation

- **Choix numérique** : Entrez le numéro de l'option souhaitée
- **Option 0** : Retour au menu précédent ou quitter (depuis le menu principal)
- **Appuyez sur Entrée** : Pour continuer après une opération

## 🔒 Sécurité

### Vérifications Préalables

Le menu effectue plusieurs vérifications au démarrage :

1. **Privilèges root** : Le script doit être exécuté avec sudo
2. **Installation existante** : Vérifie que `/opt/seedbox` existe
3. **Scripts disponibles** : Vérifie que les scripts de gestion sont présents

### Confirmations

Certaines opérations critiques nécessitent une confirmation :

- **Suppression d'utilisateur** : Taper "supprimer" pour confirmer
- **Mises à jour** : Confirmer avec o/N
- **Nettoyage Docker** : Confirmer avec o/N
- **Sauvegarde** : Confirmer avec o/N

## 📝 Exemples de Workflows

### Workflow 1 : Ajouter un Nouvel Utilisateur Complet

1. Lancer le menu : `sudo ./menu.sh`
2. Choisir `1` (Gestion des utilisateurs)
3. Choisir `1` (Ajouter un utilisateur)
4. Entrer les informations
5. Répondre `o` pour installer les services interactivement
6. Sélectionner les services souhaités (sonarr, radarr, etc.)

### Workflow 2 : Monitoring Quotidien

1. Lancer le menu : `sudo ./menu.sh`
2. Choisir `3` (Monitoring)
3. Choisir `1` (État du système) pour voir les ressources
4. Choisir `2` (État des services) pour vérifier que tout tourne
5. Choisir `3` (Liste des utilisateurs) pour voir l'activité

### Workflow 3 : Maintenance Hebdomadaire

1. Lancer le menu : `sudo ./menu.sh`
2. Choisir `4` (Maintenance)
3. Choisir `2` (Mettre à jour les conteneurs)
4. Confirmer la mise à jour
5. Optionnel : Choisir `3` (Nettoyage Docker) pour libérer de l'espace

### Workflow 4 : Dépannage d'un Service

1. Lancer le menu : `sudo ./menu.sh`
2. Choisir `3` (Monitoring)
3. Choisir `5` (Logs d'un service)
4. Entrer le nom du service problématique
5. Analyser les logs
6. Si nécessaire, retour au menu et choisir `4` (Maintenance)
7. Choisir `1` (Redémarrer les services) puis `2` (un service spécifique)

## 🆘 Dépannage

### Le menu ne démarre pas

**Erreur : "Ce script doit être exécuté en tant que root"**
- Solution : Utilisez `sudo ./menu.sh`

**Erreur : "Installation non trouvée"**
- Solution : Vérifiez que `/opt/seedbox` existe et que l'installation est complète

### Les scripts ne sont pas trouvés

**Erreur : "Script non trouvé"**
- Solution : Vérifiez que les scripts sont présents dans `/opt/seedbox/scripts/`
- Vérifiez les permissions : `ls -la /opt/seedbox/scripts/`

### Docker ne répond pas

Si les commandes Docker échouent :
```bash
# Vérifier l'état de Docker
sudo systemctl status docker

# Redémarrer Docker si nécessaire
sudo systemctl restart docker
```

## 🔗 Scripts Sous-Jacents

Le menu appelle les scripts suivants (situés dans `/opt/seedbox/scripts/`) :

- `add_user.sh` - Ajout d'utilisateurs
- `remove_user.sh` - Suppression d'utilisateurs
- `update_quota.sh` - Modification des quotas
- `add_user_service.sh` - Ajout de services utilisateur
- `list_user_services.sh` - Liste des services utilisateur
- `add_service.sh` - Ajout de services système

Vous pouvez toujours utiliser ces scripts directement si vous préférez.

## 💡 Conseils

1. **Navigation rapide** : Notez les numéros des opérations fréquentes pour naviguer plus vite
2. **Monitoring régulier** : Consultez l'état du système régulièrement (option 3.1)
3. **Sauvegardes** : Créez une sauvegarde avant les opérations importantes
4. **Logs** : En cas de problème, consultez toujours les logs d'abord
5. **Mises à jour** : Mettez à jour les conteneurs régulièrement (hebdomadaire recommandé)

## 📊 Raccourcis Clavier

Pour une utilisation encore plus rapide, vous pouvez créer un alias :

```bash
# Ajouter dans ~/.bashrc ou ~/.zshrc
alias seedbox='cd /opt/seedbox && sudo ./menu.sh'

# Puis utiliser simplement :
seedbox
```

---

**Version:** 2.3
**Dernière mise à jour:** 2025-01-13
