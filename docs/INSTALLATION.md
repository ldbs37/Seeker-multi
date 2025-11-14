# Guide d'Installation - Seedbox Multi-Utilisateurs

## 📋 Vue d'ensemble

Ce guide vous accompagne dans l'installation complète de votre seedbox multi-utilisateurs avec authentification centralisée.

## Prérequis Système

### Matériel minimum
- **CPU:** 4 cœurs (recommandé: 6+)
- **RAM:** 8 GB (recommandé: 16 GB)
- **Stockage:**
  - 20 GB pour le système
  - Variable selon le nombre d'utilisateurs et quotas
- **Connexion:** 100 Mbps minimum

### Système d'exploitation supporté
- Ubuntu 22.04 LTS ✅ (recommandé)
- Debian 12 ✅
- Ubuntu 20.04 LTS ⚠️ (fonctionne mais non testé)

### Réseau
- Accès Internet requis
- Ports 80 et 443 recommandés (optionnel)
- Plage de ports 6000-10000 disponible

## 🚀 Installation

### Étape 1: Préparation du système

```bash
# Mise à jour du système
sudo apt update && sudo apt upgrade -y

# Redémarrage recommandé
sudo reboot
```

### Étape 2: Clonage du repository

```bash
# Installer git si nécessaire
sudo apt install git -y

# Cloner le projet
git clone https://github.com/votre-username/Seeker-multi.git
cd Seeker-multi
```

### Étape 3: Lancement de l'installation

```bash
# Rendre le script exécutable
chmod +x install.sh

# Lancer l'installation (mode interactif)
sudo ./install.sh
```

## 📝 Configuration Interactive

### 1. Configuration du domaine

```
Nom de domaine (ex: exemple.com): monserveur.com
Email administrateur: admin@monserveur.com
```

**Notes:**
- Le domaine est optionnel (vous pouvez utiliser une IP)
- L'email est utilisé pour les notifications Authelia

### 2. Utilisateur administrateur

```
Nom d'utilisateur admin [admin]: admin
Mot de passe admin (min 8 caractères): ********
Confirmez le mot de passe: ********
```

**Recommandations:**
- Utilisez un mot de passe fort (12+ caractères)
- Mélangez majuscules, minuscules, chiffres et symboles
- Ne réutilisez pas un mot de passe existant

### 3. Services optionnels

```
Installer Scrutiny (monitoring disques) ? (o/N): o
Installer Uptime Kuma (monitoring uptime) ? (o/N): o
Installer Watchtower (mises à jour auto) ? (o/N): n
Installer Duplicati (backups) ? (o/N): o
```

**Guide de sélection:**

| Service | Quand l'installer ? |
|---------|---------------------|
| **Scrutiny** | Recommandé si vous avez plusieurs disques ou voulez surveiller la santé des disques |
| **Uptime Kuma** | Utile pour surveiller la disponibilité de vos services |
| **Watchtower** | ⚠️ Attention: mises à jour automatiques, peut casser des services |
| **Duplicati** | Fortement recommandé pour sauvegarder vos configurations |

### 4. Utilisateurs initiaux

```
Ajouter un utilisateur ? (O/n): o
Nom d'utilisateur: john
Mot de passe: ********
Confirmez: ********
Email: john@example.com
Quota (GB) [500]: 750

Ajouter un utilisateur ? (O/n): n
```

**Notes:**
- Vous pouvez ajouter 0 ou plusieurs utilisateurs
- Les utilisateurs peuvent être ajoutés plus tard avec `add_user.sh`
- Le quota par défaut est de 500 GB

### 5. Récapitulatif et confirmation

```
=== Récapitulatif ===
Domaine: monserveur.com
Email: admin@monserveur.com
Admin: admin
Services optionnels:
  ✓ Scrutiny
  ✓ Uptime Kuma
  ✓ Duplicati
Utilisateurs: 1

Continuer l'installation ? (o/N): o
```

## ⏱️ Processus d'installation

L'installation se déroule en 10 étapes :

```
[##########          ] 50%
```

1. ✅ Vérification système
2. ✅ Installation des dépendances
3. ✅ Installation de Docker
4. ✅ Configuration système (UFW, fail2ban)
5. ✅ Configuration interactive
6. ✅ Création des dossiers
7. ✅ Configuration Authelia
8. ✅ Ajout des utilisateurs
9. ✅ Génération docker-compose.yml
10. ✅ Démarrage des services

**Temps estimé:** 10-15 minutes (selon connexion Internet)

## ✅ Vérification Post-Installation

### Vérifier que tous les services sont démarrés

```bash
cd /opt/seedbox
docker-compose ps
```

Vous devriez voir :
```
NAME              STATUS
authelia          Up
plex              Up
flaresolverr      Up
scrutiny          Up (si installé)
uptime-kuma       Up (si installé)
duplicati         Up (si installé)
```

### Tester l'accès aux services

```bash
# Authelia
curl http://localhost:9091

# Plex
curl http://localhost:32400/web
```

### Vérifier les logs

```bash
# Voir tous les logs
docker-compose logs

# Logs d'un service spécifique
docker logs authelia

# Suivre les logs en temps réel
docker-compose logs -f
```

## 🔧 Configuration Post-Installation

### 1. Configurer Authelia

Accédez à `http://votre-serveur:9091` et connectez-vous avec les identifiants admin.

**Première connexion:**
1. Entrez votre nom d'utilisateur et mot de passe
2. Configurez l'authentification à deux facteurs (recommandé)

### 2. Configurer Plex

Accédez à `http://votre-serveur:32400/web`

**Configuration initiale:**
1. Connectez-vous avec votre compte Plex
2. Donnez un nom à votre serveur
3. Ajoutez les bibliothèques:
   - Films: `/data/users/*/movies`
   - Séries: `/data/users/*/tv`
   - Livres: `/data/users/*/books`

### 3. Configurer les services optionnels

#### Scrutiny (si installé)
```bash
# Accès: http://votre-serveur:8080
# Aucune configuration requise, analyse automatique
```

#### Uptime Kuma (si installé)
```bash
# Accès: http://votre-serveur:3001
# Créez un compte admin lors de la première visite
```

#### Duplicati (si installé)
```bash
# Accès: http://votre-serveur:8200
# Configurez vos destinations de backup
```

## 👥 Ajouter des utilisateurs

### Avec le script add_user.sh

```bash
cd /opt/seedbox/scripts
sudo ./add_user.sh alice SecurePass789 alice@example.com 1000
```

Cela créera automatiquement:
- Utilisateur système (UID unique)
- 10 conteneurs Docker (tous les services)
- Structure de dossiers complète
- Authentification Authelia
- Quotas de stockage

### Ports attribués automatiquement

L'utilisateur Alice (UID 1001) obtiendra:
- qBittorrent: `8090`
- Sonarr: `8990`
- Radarr: `7879`
- Readarr: `8788`
- Bazarr: `6768`
- Prowlarr: `9697`
- Overseerr: `5056`
- Homarr: `7576`
- Calibre: `8084`
- Filebrowser: `8082`

## 🔐 Sécurité

### Pare-feu UFW

Le pare-feu est configuré automatiquement:

```bash
# Vérifier le statut
sudo ufw status

# Autoriser un port supplémentaire
sudo ufw allow 8090/tcp
```

### Fail2ban

Protection contre les attaques par force brute:

```bash
# Vérifier le statut
sudo fail2ban-client status

# Voir les IPs bannies
sudo fail2ban-client status ssh
```

### Quotas

Vérifier et gérer les quotas:

```bash
# Voir tous les quotas
sudo repquota -a

# Quota d'un utilisateur
sudo quota -v -u alice

# Modifier un quota
cd /opt/seedbox/scripts
sudo ./update_quota.sh alice 2000  # 2TB
```

## 📊 Monitoring

### Vérifier l'utilisation des ressources

```bash
# CPU et RAM
htop

# Espace disque
df -h

# Par utilisateur
du -sh /opt/seedbox/data/users/*
```

### Logs système

```bash
# Logs Docker
docker-compose logs -f --tail=100

# Logs système
sudo journalctl -xe

# Logs d'un conteneur
docker logs -f qbittorrent-alice
```

## 🛠️ Maintenance

### Mettre à jour les conteneurs

```bash
cd /opt/seedbox
docker-compose pull
docker-compose up -d
```

### Nettoyer Docker

```bash
# Supprimer les images inutilisées
docker system prune -a

# Voir l'espace utilisé
docker system df
```

### Sauvegarder la configuration

```bash
# Sauvegarde complète
sudo tar czf seedbox-backup-$(date +%Y%m%d).tar.gz /opt/seedbox

# Restauration
sudo tar xzf seedbox-backup-YYYYMMDD.tar.gz -C /
```

## ❌ Désinstallation

### Désinstallation complète

```bash
# Arrêter tous les services
cd /opt/seedbox
docker-compose down -v

# Supprimer les données (ATTENTION: IRRÉVERSIBLE)
sudo rm -rf /opt/seedbox

# Désinstaller Docker (optionnel)
sudo apt remove docker-ce docker-ce-cli containerd.io
```

### Conserver les données

```bash
# Arrêter les services
cd /opt/seedbox
docker-compose down

# Sauvegarder les données
sudo cp -r /opt/seedbox/data /backup/seedbox-data

# Supprimer le reste
sudo rm -rf /opt/seedbox/!(data)
```

## 🔄 Migration

### Depuis une installation existante

```bash
# 1. Sauvegarder les données
sudo cp -r /opt/seedbox/data /backup/

# 2. Arrêter l'ancien système
cd /opt/ancienne-seedbox
docker-compose down

# 3. Installer la nouvelle version
cd /tmp
git clone https://github.com/votre-username/Seeker-multi.git
cd Seeker-multi
sudo ./install.sh

# 4. Restaurer les données utilisateurs
sudo cp -r /backup/data/* /opt/seedbox/data/

# 5. Recréer les utilisateurs avec add_user.sh
```

## 📞 Support et Dépannage

### Problèmes courants

#### Les conteneurs ne démarrent pas

```bash
# Vérifier les logs
docker-compose logs

# Vérifier les ports
sudo netstat -tulpn | grep LISTEN

# Redémarrer
docker-compose restart
```

#### Erreur de permissions

```bash
# Corriger les permissions
sudo chown -R 1001:1001 /opt/seedbox/data/users/alice
```

#### Problème de quotas

```bash
# Vérifier que les quotas sont activés
sudo quotaon -ap

# Réactiver
sudo quotaon -av
```

### Obtenir de l'aide

1. **Documentation:** Consultez `README.md` et `/docs`
2. **Logs:** Vérifiez `docker-compose logs`
3. **Issues GitHub:** Ouvrez une issue avec les détails
4. **Forum:** Consultez les discussions existantes

## 📚 Ressources supplémentaires

- [Documentation Authelia](https://www.authelia.com/docs/)
- [Documentation Plex](https://support.plex.tv/)
- [Docker Compose reference](https://docs.docker.com/compose/)
- [Ubuntu server guide](https://ubuntu.com/server/docs)

---

**Bon déploiement ! 🚀**
