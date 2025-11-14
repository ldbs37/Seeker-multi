# Options d'Accès aux Services - URL et Routing

## 🎯 Question : Comment accéder aux services ? Besoin d'un nom de domaine ?

## 📊 Comparaison des Options

| Critère | Accès Direct (Actuel) | Avec Reverse Proxy |
|---------|----------------------|-------------------|
| **Domaine requis** | ❌ Non | ✅ Oui (avec wildcard DNS) |
| **URL** | `http://ip:port` | `http://user.domain.fr/service` |
| **SSL/HTTPS** | ❌ Manuel | ✅ Automatique (Let's Encrypt) |
| **Protection Authelia** | ❌ Non | ✅ Oui |
| **Complexité** | ⭐ Simple | ⭐⭐⭐ Complexe |
| **Convivialité** | ⭐⭐ Moyenne | ⭐⭐⭐⭐⭐ Excellente |
| **Maintenance** | ⭐⭐⭐⭐ Facile | ⭐⭐ Plus exigeante |

## 🚀 Option 1 : Accès Direct par Port (Configuration Actuelle)

### Comment ça fonctionne

Chaque service est accessible directement via son port :

```
http://votre-serveur:8080  → qBittorrent User1
http://votre-serveur:8090  → qBittorrent User2
http://votre-serveur:7576  → Homarr User1
http://votre-serveur:9000  → Portainer
http://votre-serveur:8096  → Jellyfin
```

### Avantages
- ✅ **Pas de domaine nécessaire** - fonctionne avec une IP
- ✅ **Configuration simple** - aucun DNS à configurer
- ✅ **Déploiement rapide** - prêt immédiatement après installation
- ✅ **Moins de points de défaillance** - pas de reverse proxy
- ✅ **Idéal pour usage local ou VPN**

### Inconvénients
- ❌ **URLs peu élégantes** - difficile à mémoriser
- ❌ **Pas de SSL automatique** - nécessite configuration manuelle
- ❌ **Authelia ne protège pas** - chaque service gère sa propre auth
- ❌ **Ports à mémoriser** - liste de ports différents

### Cas d'usage recommandés
- Seedbox personnelle / familiale
- Accès via VPN privé
- Environnement de développement/test
- Budget limité (pas besoin de domaine)

---

## 🌐 Option 2 : Routing par Sous-Domaine avec Reverse Proxy

### Architecture proposée

```
user1.domain.fr/qbittorrent  → qBittorrent User1
user2.domain.fr/qbittorrent  → qBittorrent User2
admin.domain.fr/portainer    → Portainer
media.domain.fr              → Jellyfin/Plex
auth.domain.fr               → Authelia
```

### Composants nécessaires

1. **Nom de domaine** : `domain.fr` (environ 10-15€/an)
2. **DNS Wildcard** : `*.domain.fr` pointant vers votre serveur
3. **Traefik** : Reverse proxy automatique
4. **Let's Encrypt** : Certificats SSL gratuits

### Configuration DNS requise

```dns
# Enregistrements DNS à créer :
A     domain.fr           → 1.2.3.4
A     *.domain.fr         → 1.2.3.4
```

### Avantages
- ✅ **URLs propres et mémorables**
- ✅ **HTTPS automatique** avec certificats Let's Encrypt
- ✅ **Protection Authelia** sur tous les services
- ✅ **Expérience professionnelle**
- ✅ **Facilite le partage** avec d'autres utilisateurs

### Inconvénients
- ❌ **Domaine requis** - coût annuel
- ❌ **Configuration DNS** - délai de propagation
- ❌ **Plus complexe** - Traefik + labels Docker
- ❌ **Point de défaillance** - si Traefik tombe, tout tombe

### Cas d'usage recommandés
- Seedbox partagée multi-utilisateurs
- Usage professionnel
- Accès depuis Internet
- Besoin de sécurité renforcée

---

## 🛠️ Implémentation Option 2 : Ajouter Traefik

Si vous voulez passer à des URLs avec domaine, voici les étapes :

### 1. Prérequis

```bash
# Variables à définir
DOMAIN="votre-domain.fr"
EMAIL="admin@votre-domain.fr"
```

### 2. Configuration Traefik

**Créer `/opt/seedbox/traefik/traefik.yml` :**

```yaml
api:
  dashboard: true

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@domain.fr
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
```

### 3. Ajouter Traefik au docker-compose.yml

```yaml
  traefik:
    image: traefik:v3.0
    container_name: traefik
    command:
      - "--configFile=/traefik.yml"
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"  # Dashboard Traefik
    volumes:
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/letsencrypt:/letsencrypt
      - /var/run/docker.sock:/var/run/docker.sock:ro
    restart: unless-stopped
```

### 4. Ajouter labels aux services

**Exemple pour Jellyfin :**

```yaml
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.jellyfin.rule=Host(`media.${DOMAIN}`)"
      - "traefik.http.routers.jellyfin.entrypoints=websecure"
      - "traefik.http.routers.jellyfin.tls.certresolver=letsencrypt"
      - "traefik.http.services.jellyfin.loadbalancer.server.port=8096"

      # Protection Authelia
      - "traefik.http.routers.jellyfin.middlewares=authelia@docker"
    # ... reste de la config
```

**Exemple pour services utilisateur (qBittorrent) :**

```yaml
  qbittorrent-user1:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent-user1
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.qbit-user1.rule=Host(`user1.${DOMAIN}`) && PathPrefix(`/qbittorrent`)"
      - "traefik.http.routers.qbit-user1.entrypoints=websecure"
      - "traefik.http.routers.qbit-user1.tls.certresolver=letsencrypt"
      - "traefik.http.services.qbit-user1.loadbalancer.server.port=8080"
      - "traefik.http.routers.qbit-user1.middlewares=authelia@docker"
    # ... reste de la config
```

### 5. Middleware Authelia

```yaml
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authelia.rule=Host(`auth.${DOMAIN}`)"
      - "traefik.http.routers.authelia.entrypoints=websecure"
      - "traefik.http.routers.authelia.tls.certresolver=letsencrypt"

      # Middleware Forward Auth
      - "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/verify?rd=https://auth.${DOMAIN}"
      - "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
```

---

## 🔄 Migration : Port → Domaine

### Étapes pour migrer

1. **Acheter un domaine** (OVH, Gandi, Namecheap, etc.)

2. **Configurer le DNS** :
   ```
   A     domain.fr    → IP_DU_SERVEUR
   A     *.domain.fr  → IP_DU_SERVEUR
   ```

3. **Ajouter Traefik** au docker-compose.yml

4. **Ajouter les labels** à tous les services

5. **Mettre à jour Authelia** avec les nouveaux domaines

6. **Redémarrer** :
   ```bash
   cd /opt/seedbox
   docker-compose up -d
   ```

7. **Tester** :
   ```bash
   curl https://auth.domain.fr
   curl https://user1.domain.fr/qbittorrent
   ```

### Compatibilité descendante

Vous pouvez **garder les deux** :
- Accès par port : `http://ip:8080`
- Accès par domaine : `https://user1.domain.fr/qbittorrent`

Il suffit de ne pas supprimer les ports exposés dans docker-compose.

---

## 💡 Recommandation

### Pour démarrer : **Rester en accès direct** (Option 1)
- Configuration actuelle est fonctionnelle
- Pas de coût supplémentaire
- Parfait pour tester et apprendre

### Pour production : **Migrer vers Traefik** (Option 2)
- Meilleure expérience utilisateur
- Sécurité renforcée avec Authelia + SSL
- URLs propres et professionnelles
- Nécessite investissement en temps et domaine

---

## 🎯 Décision

**Voulez-vous que je :**
1. ✅ **Garde l'architecture actuelle** (accès par port) - SIMPLE
2. 🔄 **Implémente Traefik** avec routing par domaine - AVANCÉ

Si vous choisissez l'option 2, j'intégrerai Traefik de manière optionnelle dans le script d'installation.
