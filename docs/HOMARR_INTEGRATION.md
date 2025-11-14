# Intégration Homarr - Gestion des Services Utilisateur

Ce document explique comment permettre aux utilisateurs d'ajouter des services depuis leur dashboard Homarr de manière sécurisée.

## 🎯 Objectif

Permettre aux utilisateurs de gérer leurs propres services (Sonarr, Radarr, etc.) depuis Homarr sans accès SSH ou sudo.

## 🔒 Sécurité

L'approche utilise :
- **API REST sécurisée** avec authentification JWT
- **Whitelist de services** autorisés
- **Isolation utilisateur** - chaque utilisateur ne peut gérer que ses services
- **Sudo limité** - l'API a uniquement accès au script `add_user_service.sh`
- **Validation côté serveur** de toutes les requêtes

## 📦 Installation de l'API

### 1. Ajouter l'API au docker-compose

Ajoutez ce service dans `/opt/seedbox/docker-compose.yml` :

```yaml
  user-service-api:
    build: ./api
    container_name: user-service-api
    ports:
      - "5000:5000"
    volumes:
      - ./api:/app:ro
      - ./scripts:/opt/seedbox/scripts:ro
      - ./authelia/users_database.yml:/opt/seedbox/authelia/users_database.yml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    environment:
      - API_SECRET_KEY=${API_SECRET_KEY}
    restart: unless-stopped
```

### 2. Générer une clé secrète

```bash
# Générer une clé aléatoire sécurisée
export API_SECRET_KEY=$(openssl rand -hex 32)

# L'ajouter au .env ou à docker-compose.yml
echo "API_SECRET_KEY=$API_SECRET_KEY" >> /opt/seedbox/.env
```

### 3. Construire et démarrer l'API

```bash
cd /opt/seedbox
docker-compose build user-service-api
docker-compose up -d user-service-api
```

### 4. Vérifier que l'API fonctionne

```bash
curl http://localhost:5000/api/health
# Devrait retourner: {"status":"ok"}
```

## 🖥️ Intégration avec Homarr

### Option 1 : Widget iFrame (Simple)

Créez une page HTML simple que les utilisateurs peuvent ajouter en widget iFrame dans Homarr :

**Créer `/opt/seedbox/api/static/service-manager.html` :**

```html
<!DOCTYPE html>
<html lang="fr">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Gestionnaire de Services</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background: #1a1a2e;
            color: #eee;
            padding: 20px;
        }

        .container {
            max-width: 800px;
            margin: 0 auto;
        }

        .login-form, .services-list {
            background: #16213e;
            padding: 20px;
            border-radius: 10px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.3);
        }

        h2 {
            margin-bottom: 20px;
            color: #4ecca3;
        }

        input, button {
            width: 100%;
            padding: 12px;
            margin: 8px 0;
            border: 1px solid #4ecca3;
            border-radius: 5px;
            background: #0f3460;
            color: #eee;
            font-size: 14px;
        }

        button {
            background: #4ecca3;
            color: #0f3460;
            font-weight: bold;
            cursor: pointer;
            transition: all 0.3s;
        }

        button:hover {
            background: #3dba8a;
            transform: translateY(-2px);
        }

        button:disabled {
            background: #555;
            cursor: not-allowed;
        }

        .service-card {
            background: #0f3460;
            padding: 15px;
            margin: 10px 0;
            border-radius: 5px;
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .service-card h3 {
            color: #4ecca3;
            font-size: 16px;
        }

        .service-card p {
            color: #aaa;
            font-size: 12px;
            margin: 5px 0;
        }

        .service-card button {
            width: auto;
            padding: 8px 16px;
        }

        .hidden {
            display: none;
        }

        .alert {
            padding: 12px;
            margin: 10px 0;
            border-radius: 5px;
        }

        .alert-success {
            background: #4ecca3;
            color: #0f3460;
        }

        .alert-error {
            background: #e74c3c;
            color: white;
        }

        .loading {
            text-align: center;
            padding: 20px;
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- Formulaire de connexion -->
        <div id="loginSection" class="login-form">
            <h2>🔐 Connexion</h2>
            <input type="text" id="username" placeholder="Nom d'utilisateur" />
            <input type="password" id="password" placeholder="Mot de passe" />
            <button onclick="login()">Se connecter</button>
            <div id="loginAlert"></div>
        </div>

        <!-- Liste des services -->
        <div id="servicesSection" class="services-list hidden">
            <h2>📦 Gestion des Services</h2>
            <p style="color: #aaa; margin-bottom: 20px;">Utilisateur: <span id="currentUser"></span></p>

            <div id="servicesAlert"></div>

            <h3 style="margin-top: 20px;">Services disponibles</h3>
            <div id="availableServices"></div>

            <h3 style="margin-top: 30px;">Services installés</h3>
            <div id="installedServices"></div>

            <button onclick="logout()" style="margin-top: 20px; background: #e74c3c;">Déconnexion</button>
        </div>
    </div>

    <script>
        const API_URL = 'http://localhost:5000/api';
        let authToken = localStorage.getItem('authToken');
        let currentUsername = localStorage.getItem('username');

        // Services avec descriptions
        const serviceDescriptions = {
            'sonarr': 'Gestion des séries TV',
            'radarr': 'Gestion des films',
            'readarr': 'Gestion des livres',
            'bazarr': 'Sous-titres automatiques',
            'prowlarr': 'Gestion des indexeurs',
            'overseerr': 'Système de requêtes',
            'calibre': 'Bibliothèque d\'ebooks',
            'homarr': 'Dashboard personnel',
            'filebrowser': 'Gestionnaire de fichiers'
        };

        // Icônes des services
        const serviceIcons = {
            'sonarr': '📺',
            'radarr': '🎬',
            'readarr': '📚',
            'bazarr': '💬',
            'prowlarr': '🔍',
            'overseerr': '📝',
            'calibre': '📖',
            'homarr': '🖥️',
            'filebrowser': '📂'
        };

        // Vérifier si déjà connecté
        if (authToken && currentUsername) {
            showServices();
            loadServices();
        }

        async function login() {
            const username = document.getElementById('username').value;
            const password = document.getElementById('password').value;

            if (!username || !password) {
                showAlert('loginAlert', 'Veuillez remplir tous les champs', 'error');
                return;
            }

            try {
                const response = await fetch(`${API_URL}/login`, {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ username, password })
                });

                const data = await response.json();

                if (response.ok) {
                    authToken = data.token;
                    currentUsername = data.username;
                    localStorage.setItem('authToken', authToken);
                    localStorage.setItem('username', currentUsername);
                    showServices();
                    loadServices();
                } else {
                    showAlert('loginAlert', data.error || 'Erreur de connexion', 'error');
                }
            } catch (error) {
                showAlert('loginAlert', 'Erreur de connexion au serveur', 'error');
            }
        }

        function logout() {
            authToken = null;
            currentUsername = null;
            localStorage.removeItem('authToken');
            localStorage.removeItem('username');
            showLogin();
        }

        function showLogin() {
            document.getElementById('loginSection').classList.remove('hidden');
            document.getElementById('servicesSection').classList.add('hidden');
        }

        function showServices() {
            document.getElementById('loginSection').classList.add('hidden');
            document.getElementById('servicesSection').classList.remove('hidden');
            document.getElementById('currentUser').textContent = currentUsername;
        }

        async function loadServices() {
            try {
                const response = await fetch(`${API_URL}/services/available`, {
                    headers: {
                        'Authorization': `Bearer ${authToken}`
                    }
                });

                if (!response.ok) {
                    if (response.status === 401) {
                        logout();
                        return;
                    }
                    throw new Error('Erreur de chargement');
                }

                const data = await response.json();

                // Afficher les services disponibles
                const availableDiv = document.getElementById('availableServices');
                if (data.available.length === 0) {
                    availableDiv.innerHTML = '<p style="color: #aaa;">Tous les services sont déjà installés</p>';
                } else {
                    availableDiv.innerHTML = data.available.map(service => `
                        <div class="service-card">
                            <div>
                                <h3>${serviceIcons[service] || '📦'} ${service}</h3>
                                <p>${serviceDescriptions[service] || 'Service applicatif'}</p>
                            </div>
                            <button onclick="installService('${service}')">Installer</button>
                        </div>
                    `).join('');
                }

                // Afficher les services installés
                const installedDiv = document.getElementById('installedServices');
                if (data.installed.length === 0) {
                    installedDiv.innerHTML = '<p style="color: #aaa;">Aucun service installé</p>';
                } else {
                    installedDiv.innerHTML = data.installed.map(service => `
                        <div class="service-card">
                            <div>
                                <h3>${serviceIcons[service] || '📦'} ${service}</h3>
                                <p>${serviceDescriptions[service] || 'Service applicatif'}</p>
                            </div>
                            <span style="color: #4ecca3;">✓ Installé</span>
                        </div>
                    `).join('');
                }
            } catch (error) {
                showAlert('servicesAlert', 'Erreur de chargement des services', 'error');
            }
        }

        async function installService(service) {
            if (!confirm(`Voulez-vous vraiment installer ${service} ?`)) {
                return;
            }

            showAlert('servicesAlert', `Installation de ${service} en cours...`, 'success');

            try {
                const response = await fetch(`${API_URL}/services/add`, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${authToken}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ service })
                });

                const data = await response.json();

                if (response.ok && data.success) {
                    showAlert('servicesAlert', `✓ ${service} installé avec succès !`, 'success');
                    setTimeout(() => loadServices(), 2000);
                } else {
                    showAlert('servicesAlert', data.error || 'Erreur d\'installation', 'error');
                }
            } catch (error) {
                showAlert('servicesAlert', 'Erreur de connexion au serveur', 'error');
            }
        }

        function showAlert(elementId, message, type) {
            const alertDiv = document.getElementById(elementId);
            alertDiv.innerHTML = `<div class="alert alert-${type}">${message}</div>`;
            setTimeout(() => {
                alertDiv.innerHTML = '';
            }, 5000);
        }
    </script>
</body>
</html>
```

### Option 2 : Boutons Custom dans Homarr

Dans Homarr, ajoutez des "Custom Buttons" (boutons personnalisés) qui appellent l'API via JavaScript :

1. **Ajouter un widget "iFrame"** dans Homarr
2. **URL**: `http://localhost:5000/static/service-manager.html`
3. **Taille**: Ajuster selon besoin

### Option 3 : Intégration via Homarr API

Homarr supporte les scripts personnalisés via son système de widgets. Vous pouvez créer un widget qui appelle directement l'API.

## 🔐 Configuration sudo pour l'API

L'API a besoin d'exécuter `add_user_service.sh` avec sudo. Configuration requise :

```bash
# Créer un fichier sudoers pour l'API
sudo visudo -f /etc/sudoers.d/seedbox-api

# Ajouter cette ligne (adapter l'UID si nécessaire)
apiuser ALL=(ALL) NOPASSWD: /opt/seedbox/scripts/add_user_service.sh
```

## 📝 Utilisation de l'API

### 1. Authentification

```bash
# Obtenir un token
curl -X POST http://localhost:5000/api/login \
  -H "Content-Type: application/json" \
  -d '{"username":"john","password":"mypassword"}'

# Réponse:
# {"token":"eyJ...","username":"john"}
```

### 2. Lister les services disponibles

```bash
curl -X GET http://localhost:5000/api/services/available \
  -H "Authorization: Bearer eyJ..."

# Réponse:
# {
#   "available": ["sonarr", "radarr", "bazarr"],
#   "installed": ["qbittorrent", "homarr"]
# }
```

### 3. Ajouter un service

```bash
curl -X POST http://localhost:5000/api/services/add \
  -H "Authorization: Bearer eyJ..." \
  -H "Content-Type: application/json" \
  -d '{"service":"sonarr"}'

# Réponse:
# {
#   "success": true,
#   "message": "Service sonarr ajouté avec succès",
#   "output": "..."
# }
```

## 🛡️ Sécurité

### Points forts

1. **Authentification**: JWT avec expiration (24h)
2. **Autorisation**: Chaque utilisateur ne peut gérer que ses services
3. **Whitelist**: Seuls les services autorisés peuvent être installés
4. **Validation**: Toutes les entrées sont validées
5. **Sudo limité**: L'API n'a accès qu'au script add_user_service.sh
6. **Isolation**: Conteneur Docker séparé

### Recommandations de production

1. **HTTPS**: Utiliser un reverse proxy avec SSL (Nginx, Traefik)
2. **Rate limiting**: Limiter le nombre de requêtes par utilisateur
3. **Logs**: Logger toutes les actions pour audit
4. **Secrets**: Utiliser Docker secrets pour API_SECRET_KEY
5. **Firewall**: Restreindre l'accès à l'API au réseau local uniquement

## 🔧 Dépannage

### L'API ne démarre pas

```bash
# Vérifier les logs
docker logs user-service-api

# Vérifier que le port 5000 est libre
sudo lsof -i :5000
```

### Erreur "Token invalide"

- Vérifier que la clé API_SECRET_KEY est la même entre les services
- Vérifier que le token n'a pas expiré (24h)
- Regénérer un token avec `/api/login`

### Erreur "Permission denied" lors de l'ajout de service

```bash
# Vérifier la configuration sudo
sudo cat /etc/sudoers.d/seedbox-api

# Vérifier que l'utilisateur API existe
id apiuser
```

## 📚 Ressources

- [Flask Documentation](https://flask.palletsprojects.com/)
- [JWT.io](https://jwt.io/)
- [Homarr Documentation](https://homarr.dev/)

---

**Version:** 1.0
**Dernière mise à jour:** 2025-01-13
**Status:** Production Ready avec les précautions de sécurité
