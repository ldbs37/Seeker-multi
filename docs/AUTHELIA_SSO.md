# Authelia SSO - Protection Unifiée de TOUS les Services

## 🎯 Objectif

Protéger **tous les services** (y compris qBittorrent et la gestion de fichiers) avec Authelia, sans avoir à gérer des mots de passe séparés pour chaque service.

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
- ✅ **Protection complète** : fichiers, qBittorrent, *arr, etc.

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
    image: traefik:v3.7.13
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

### 4. Connexion unique des services utilisateur

**Automatique** (installation, `add_user.sh`, `add_user_service.sh`,
`generate_traefik_labels.sh` → `arr_setup.sh`). Ne pas désactiver leur
authentification à la main : c'est l'isolement réseau ci-dessous qui la rend
inutile, et il est vérifié avant.

| Service | Connexion |
|---------|-----------|
| Sonarr, Radarr, Prowlarr | Mode « External » : aucune page de connexion (l'API exige toujours sa clé) |
| qBittorrent | Seule l'adresse fixe de Traefik, sur le réseau interne `seedbox_sso`, est dispensée de mot de passe |
| FileBrowser Quantum, Calibre-web | En-tête au nom secret posé par Traefik après Authelia (nom de l'utilisateur) |
| Seerr | Session du propriétaire présentée par Traefik (connexion automatique) |

Liens de partage publics FileBrowser Quantum : `…/drive/public/`.

### 5. Outils d'administration (groupe `admins`)

| Outil | Connexion après Authelia |
|-------|--------------------------|
| Duplicati | Aucune : Traefik présente un jeton (`webservice-pre-auth-tokens`, `DUPLICATI_PREAUTH_TOKEN` du `.env`) ; le mot de passe ne sert plus qu'en accès direct (tunnel SSH) |
| Uptime Kuma | Aucune : réglage « disableAuth » (base SQLite) |
| Portainer | Bouton « Login with OAuth » : un clic, rien à saisir (client OIDC `portainer` d'Authelia, réservé au groupe `admins` ; session de 7 jours). Portainer CE ne permet ni de masquer le formulaire classique ni la redirection automatique |

Automatique à l'installation et avec `add_service.sh`. Installation
existante : `generate_traefik_labels.sh` (Duplicati, Uptime Kuma), puis une
fois `sudo scripts/portainer_sso.sh` (demande le mot de passe Portainer).

## 🌐 Réseaux Docker

- `traefik_proxy` : Traefik, Authelia, Homarr, services système, Seerr.
- `seedbox_u_<user>` (un par utilisateur) : **tous** ses services
  (qBittorrent, fichiers, Sonarr, Radarr, Prowlarr et son FlareSolverr,
  Calibre-web, Seerr). Traefik et Homarr y sont raccordés ; les services d'un
  autre utilisateur n'y sont pas, donc ne peuvent pas les joindre.
- `seedbox_sso` (interne) : Traefik ↔ qBittorrent, adresse fixe de Traefik.

Créés et tenus à jour par les scripts (`compose_sync_user_nets`,
`lib_traefik.sh`) ; Traefik et Homarr sont recréés (quelques secondes) quand
un utilisateur est ajouté ou supprimé.

> Radarr 6 et Prowlarr 2 refusent l'authentification « Basic » (que Traefik
> aurait pu ajouter) : d'où le mode « External » limité au réseau privé.

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

5. **Connexion unique des applis** : faite par `generate_traefik_labels.sh`
   (réseaux privés, `arr_setup.sh`)

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
 • https://user1.votre-domain.fr/drive        → FileBrowser Quantum sans login
 • https://user1.votre-domain.fr/sonarr       → Sonarr sans login
 • https://user1.votre-domain.fr/radarr       → Radarr sans login
 • https://user1.votre-domain.fr/prowlarr     → Prowlarr sans login
 • https://user1.votre-domain.fr/calibre      → Calibre-web sans login
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
