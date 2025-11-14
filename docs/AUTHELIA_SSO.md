# Authelia SSO - Protection Unifiée de TOUS les Services

## 🎯 Objectif

Protéger **tous les services** (y compris qBittorrent et Filebrowser) avec Authelia, sans avoir à gérer des mots de passe séparés pour chaque service.

## 📊 Comparaison des Architectures

### Architecture Actuelle : Accès Direct

```
┌──────────┐     Port 8080      ┌─────────────┐
│Utilisateur│ ─────────────────▶ │ qBittorrent │ (Auth propre)
└──────────┘                     └─────────────┘
                                         ❌ Authelia ne peut pas protéger
```

**Limitations :**
- Chaque service a son propre système d'authentification
- Pas de Single Sign-On (SSO)
- Gestion des mots de passe complexe
- Authelia protège uniquement lui-même

### Architecture avec Traefik : SSO Complet

```
┌──────────┐   HTTPS    ┌────────┐   Forward   ┌─────────┐   Proxy   ┌─────────────┐
│Utilisateur│ ─────────▶ │Traefik │ ───────────▶│Authelia │ ─────────▶│ qBittorrent │
└──────────┘            └────────┘      Auth    └─────────┘           └─────────────┘
                             │                                                ✅
                             │                                           (Auth désactivée)
                             └──────────────────────────────────────────▶
                                         Tous les services protégés
```

**Avantages :**
- ✅ **Single Sign-On** : Un seul login pour tous les services
- ✅ **Un seul mot de passe** : Celui d'Authelia
- ✅ **SSL automatique** : Let's Encrypt via Traefik
- ✅ **URLs propres** : `user.domain.fr/service`
- ✅ **Protection complète** : Filebrowser, qBittorrent, *arr, etc.

---

## 🛠️ Implémentation : Traefik + Authelia SSO

### Prérequis

1. **Nom de domaine** : `votre-domain.fr`
2. **DNS Wildcard** : `*.votre-domain.fr` → IP serveur
3. **Port 80/443** : Ouverts dans le firewall

### 1. Configuration Traefik

**Créer `/opt/seedbox/traefik/traefik.yml` :**

```yaml
api:
  dashboard: true
  insecure: true  # Pour accès dashboard local

entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
          scheme: https
          permanent: true

  websecure:
    address: ":443"
    http:
      tls:
        certResolver: letsencrypt

certificatesResolvers:
  letsencrypt:
    acme:
      email: admin@votre-domain.fr
      storage: /letsencrypt/acme.json
      httpChallenge:
        entryPoint: web

providers:
  docker:
    endpoint: "unix:///var/run/docker.sock"
    exposedByDefault: false
    network: traefik_proxy

log:
  level: INFO
```

### 2. Ajouter Traefik au docker-compose.yml

```yaml
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    security_opt:
      - no-new-privileges:true
    networks:
      - traefik_proxy
    ports:
      - "80:80"
      - "443:443"
      - "8080:8080"  # Dashboard
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/traefik.yml:ro
      - ./traefik/letsencrypt:/letsencrypt
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.dashboard.rule=Host(`traefik.${DOMAIN}`)"
      - "traefik.http.routers.dashboard.entrypoints=websecure"
      - "traefik.http.routers.dashboard.tls.certresolver=letsencrypt"
      - "traefik.http.routers.dashboard.service=api@internal"
      - "traefik.http.routers.dashboard.middlewares=authelia@docker"
    environment:
      - TZ=Europe/Paris
```

### 3. Configurer Authelia avec Traefik

**Modifier `/opt/seedbox/authelia/configuration.yml` :**

```yaml
server:
  host: 0.0.0.0
  port: 9091

log:
  level: info

authentication_backend:
  file:
    path: /config/users_database.yml

access_control:
  default_policy: deny
  rules:
    # Services système - Admin seulement
    - domain:
        - "portainer.votre-domain.fr"
        - "scrutiny.votre-domain.fr"
        - "traefik.votre-domain.fr"
      policy: one_factor
      subject:
        - "group:admins"

    # Services utilisateur - Tous les utilisateurs authentifiés
    - domain:
        - "*.votre-domain.fr"
      policy: one_factor

session:
  name: authelia_session
  secret: ${SESSION_SECRET}
  expiration: 3600
  inactivity: 300
  domain: votre-domain.fr  # Important : domaine racine

storage:
  local:
    path: /config/db.sqlite3
  encryption_key: ${ENCRYPTION_KEY}

notifier:
  filesystem:
    filename: /config/notification.txt
```

**Ajouter labels Authelia au docker-compose.yml :**

```yaml
  authelia:
    image: authelia/authelia:latest
    container_name: authelia
    restart: unless-stopped
    networks:
      - traefik_proxy
    volumes:
      - ./authelia:/config
    environment:
      - TZ=Europe/Paris
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.authelia.rule=Host(`auth.${DOMAIN}`)"
      - "traefik.http.routers.authelia.entrypoints=websecure"
      - "traefik.http.routers.authelia.tls.certresolver=letsencrypt"
      - "traefik.http.services.authelia.loadbalancer.server.port=9091"

      # Middleware Forward Auth pour tous les services
      - "traefik.http.middlewares.authelia.forwardauth.address=http://authelia:9091/api/verify?rd=https://auth.${DOMAIN}"
      - "traefik.http.middlewares.authelia.forwardauth.trustForwardHeader=true"
      - "traefik.http.middlewares.authelia.forwardauth.authResponseHeaders=Remote-User,Remote-Groups,Remote-Name,Remote-Email"
```

### 4. Protéger qBittorrent avec Authelia

**Ajouter labels à qBittorrent dans docker-compose.yml :**

```yaml
  qbittorrent-user1:
    image: linuxserver/qbittorrent:latest
    container_name: qbittorrent-user1
    networks:
      - traefik_proxy
    environment:
      - PUID=1001
      - PGID=1001
      - TZ=Europe/Paris
      - WEBUI_PORT=8080
    volumes:
      - /opt/seedbox/data/users/user1:/data
      - /opt/seedbox/data/users/user1/config/qBittorrent:/config
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.qbit-user1.rule=Host(`user1.${DOMAIN}`) && PathPrefix(`/qbittorrent`)"
      - "traefik.http.routers.qbit-user1.entrypoints=websecure"
      - "traefik.http.routers.qbit-user1.tls.certresolver=letsencrypt"
      - "traefik.http.services.qbit-user1.loadbalancer.server.port=8080"

      # Protection Authelia
      - "traefik.http.routers.qbit-user1.middlewares=authelia@docker"
    restart: unless-stopped
    # Ne plus exposer le port directement
    # ports:
    #   - "8090:8080"
```

**Désactiver l'authentification qBittorrent :**

```bash
# Éditer le fichier de configuration
nano /opt/seedbox/data/users/user1/config/qBittorrent/qBittorrent.conf

# Chercher et modifier :
[Preferences]
WebUI\AuthSubnetWhitelistEnabled=true
WebUI\AuthSubnetWhitelist=0.0.0.0/0
# Ou simplement supprimer la ligne WebUI\Password_PBKDF2
```

### 5. Protéger Filebrowser avec Authelia

```yaml
  filebrowser-user1:
    image: filebrowser/filebrowser:latest
    container_name: filebrowser-user1
    networks:
      - traefik_proxy
    environment:
      - PUID=1001
      - PGID=1001
      - TZ=Europe/Paris
    volumes:
      - /opt/seedbox/data/users/user1:/srv
      - /opt/seedbox/filebrowser/user1:/database
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.fb-user1.rule=Host(`user1.${DOMAIN}`) && PathPrefix(`/files`)"
      - "traefik.http.routers.fb-user1.entrypoints=websecure"
      - "traefik.http.routers.fb-user1.tls.certresolver=letsencrypt"
      - "traefik.http.services.fb-user1.loadbalancer.server.port=80"

      # Protection Authelia
      - "traefik.http.routers.fb-user1.middlewares=authelia@docker"
    restart: unless-stopped
```

**Désactiver l'authentification Filebrowser :**

```bash
# Commande dans le conteneur
docker exec filebrowser-user1 filebrowser config set --auth.method=noauth
```

### 6. Protéger Services *arr avec Authelia

Exemple pour Sonarr :

```yaml
  sonarr-user1:
    image: linuxserver/sonarr:latest
    container_name: sonarr-user1
    networks:
      - traefik_proxy
    environment:
      - PUID=1001
      - PGID=1001
      - TZ=Europe/Paris
    volumes:
      - /opt/seedbox/sonarr/user1:/config
      - /opt/seedbox/data/users/user1:/data
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.sonarr-user1.rule=Host(`user1.${DOMAIN}`) && PathPrefix(`/sonarr`)"
      - "traefik.http.routers.sonarr-user1.entrypoints=websecure"
      - "traefik.http.routers.sonarr-user1.tls.certresolver=letsencrypt"
      - "traefik.http.services.sonarr-user1.loadbalancer.server.port=8989"

      # Protection Authelia
      - "traefik.http.routers.sonarr-user1.middlewares=authelia@docker"
    restart: unless-stopped
```

**Désactiver l'auth Sonarr :**

```bash
sudo ./scripts/disable_arr_auth.sh user1 sonarr
```

---

## 🌐 Réseau Docker

**Ajouter le réseau traefik_proxy à tous les services :**

```yaml
networks:
  traefik_proxy:
    external: true

# Créer le réseau :
docker network create traefik_proxy
```

---

## 🚀 Migration : Port Direct → SSO Authelia

### Étapes de Migration

1. **Sauvegarder la configuration actuelle** :
   ```bash
   cp /opt/seedbox/docker-compose.yml /opt/seedbox/docker-compose.yml.backup
   ```

2. **Ajouter Traefik** au docker-compose.yml

3. **Ajouter labels Authelia** à tous les services

4. **Créer le réseau** :
   ```bash
   docker network create traefik_proxy
   ```

5. **Désactiver auth interne** de chaque service

6. **Redémarrer** :
   ```bash
   cd /opt/seedbox
   docker-compose down
   docker-compose up -d
   ```

7. **Tester** :
   ```bash
   curl https://auth.votre-domain.fr
   curl https://user1.votre-domain.fr/qbittorrent
   ```

---

## ✅ Résultat Final

### Une seule authentification pour TOUT

```
Connexion à https://auth.votre-domain.fr
 ↓
 ✅ Login avec Authelia (1 seul mot de passe)
 ↓
Accès automatique à TOUS les services :
 • https://user1.votre-domain.fr/qbittorrent  → qBittorrent sans login
 • https://user1.votre-domain.fr/files        → Filebrowser sans login
 • https://user1.votre-domain.fr/sonarr       → Sonarr sans login
 • https://user1.votre-domain.fr/radarr       → Radarr sans login
 • etc.
```

### Avantages :
- ✅ **Plus de mots de passe multiples**
- ✅ **SSO complet** : un login = accès à tout
- ✅ **Sécurité renforcée** : SSL + Authelia 2FA (optionnel)
- ✅ **URLs professionnelles**
- ✅ **Gestion centralisée** : Un seul endroit pour gérer les users

---

## 🔒 Sécurité Renforcée (Optionnel)

### Activer 2FA (TOTP)

**Dans Authelia configuration.yml :**

```yaml
authentication_backend:
  file:
    path: /config/users_database.yml
    password:
      algorithm: argon2id

# Activer TOTP
totp:
  issuer: votre-domain.fr
  period: 30
  skew: 1
```

Chaque utilisateur peut ensuite activer 2FA dans son profil Authelia.

---

## 📝 Avez-vous besoin que j'implémente cette architecture ?

**Je peux :**
1. ✅ Créer un script d'installation Traefik optionnel dans `install.sh`
2. ✅ Générer automatiquement les labels Docker
3. ✅ Créer un script de migration port → domaine
4. ✅ Intégrer tout ça dans le menu interactif

**Dites-moi si vous voulez que je l'implémente !** 🚀
