#!/usr/bin/env python3
"""
API Web Sécurisée pour Ajouter des Services Utilisateur
Permet aux utilisateurs d'ajouter des services depuis Homarr de manière sécurisée
"""

from flask import Flask, request, jsonify
from functools import wraps
import subprocess
import os
import jwt
import datetime
from werkzeug.security import check_password_hash
import yaml

app = Flask(__name__)
app.config['SECRET_KEY'] = os.environ.get('API_SECRET_KEY', 'CHANGE_ME_IN_PRODUCTION')

# Configuration
INSTALL_DIR = "/opt/seedbox"
ADD_SERVICE_SCRIPT = f"{INSTALL_DIR}/scripts/add_user_service.sh"
AUTHELIA_USERS_FILE = f"{INSTALL_DIR}/authelia/users_database.yml"

# Services autorisés (whitelist)
ALLOWED_SERVICES = [
    'sonarr',
    'radarr',
    'readarr',
    'bazarr',
    'prowlarr',
    'overseerr',
    'calibre',
    'homarr',
    'filebrowser'
]

# Fonction de décorateur pour l'authentification JWT
def token_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        token = request.headers.get('Authorization')

        if not token:
            return jsonify({'error': 'Token manquant'}), 401

        try:
            # Supprimer le préfixe 'Bearer ' si présent
            if token.startswith('Bearer '):
                token = token[7:]

            data = jwt.decode(token, app.config['SECRET_KEY'], algorithms=['HS256'])
            current_user = data['username']
        except Exception as e:
            return jsonify({'error': f'Token invalide: {str(e)}'}), 401

        return f(current_user, *args, **kwargs)

    return decorated

# Chargement des utilisateurs Authelia
def load_authelia_users():
    """Charge les utilisateurs depuis le fichier Authelia"""
    try:
        with open(AUTHELIA_USERS_FILE, 'r') as f:
            data = yaml.safe_load(f)
            return data.get('users', {})
    except Exception as e:
        print(f"Erreur de chargement des utilisateurs: {e}")
        return {}

# Endpoint de connexion
@app.route('/api/login', methods=['POST'])
def login():
    """Génère un token JWT pour l'utilisateur"""
    data = request.get_json()

    username = data.get('username')
    password = data.get('password')

    if not username or not password:
        return jsonify({'error': 'Username et password requis'}), 400

    # Charger les utilisateurs Authelia
    users = load_authelia_users()

    if username not in users:
        return jsonify({'error': 'Utilisateur non trouvé'}), 401

    user = users[username]

    # Vérifier le mot de passe avec Authelia (hash Argon2)
    # Note: Pour une vraie vérification Argon2, utiliser argon2-cffi
    # Ici on simplifie avec une commande docker pour hash
    try:
        result = subprocess.run(
            ['docker', 'run', '--rm', 'authelia/authelia:latest',
             'authelia', 'crypto', 'hash', 'validate', 'argon2',
             '--password', password, '--hash', user['password']],
            capture_output=True,
            text=True,
            timeout=5
        )

        if result.returncode != 0:
            return jsonify({'error': 'Mot de passe incorrect'}), 401
    except Exception as e:
        return jsonify({'error': f'Erreur de vérification: {str(e)}'}), 500

    # Générer le token JWT
    token = jwt.encode({
        'username': username,
        'exp': datetime.datetime.utcnow() + datetime.datetime.timedelta(hours=24)
    }, app.config['SECRET_KEY'], algorithm='HS256')

    return jsonify({'token': token, 'username': username})

# Endpoint pour lister les services disponibles
@app.route('/api/services/available', methods=['GET'])
@token_required
def list_available_services(current_user):
    """Liste les services qu'un utilisateur peut installer"""

    # Récupérer les services déjà installés
    try:
        result = subprocess.run(
            [f"{INSTALL_DIR}/scripts/list_user_services.sh", current_user],
            capture_output=True,
            text=True,
            timeout=10
        )

        # Parser la sortie pour extraire les services installés
        # (Simplifié - améliorer le parsing en production)
        installed = []
        for line in result.stdout.split('\n'):
            for service in ALLOWED_SERVICES:
                if service in line.lower() and ('running' in line.lower() or 'stopped' in line.lower()):
                    installed.append(service)

        # Services disponibles = tous - installés
        available = [s for s in ALLOWED_SERVICES if s not in installed]

        return jsonify({
            'available': available,
            'installed': installed
        })

    except Exception as e:
        return jsonify({'error': str(e)}), 500

# Endpoint pour ajouter un service
@app.route('/api/services/add', methods=['POST'])
@token_required
def add_service(current_user):
    """Ajoute un service pour l'utilisateur authentifié"""

    data = request.get_json()
    service = data.get('service')

    # Validation
    if not service:
        return jsonify({'error': 'Service non spécifié'}), 400

    if service not in ALLOWED_SERVICES:
        return jsonify({'error': f'Service non autorisé. Services autorisés: {", ".join(ALLOWED_SERVICES)}'}), 403

    # Sécurité: vérifier que l'utilisateur existe
    users = load_authelia_users()
    if current_user not in users:
        return jsonify({'error': 'Utilisateur non valide'}), 403

    # Exécuter le script d'ajout de service
    try:
        result = subprocess.run(
            ['sudo', ADD_SERVICE_SCRIPT, current_user, service],
            capture_output=True,
            text=True,
            timeout=60  # Timeout de 60 secondes
        )

        if result.returncode == 0:
            return jsonify({
                'success': True,
                'message': f'Service {service} ajouté avec succès',
                'output': result.stdout
            })
        else:
            return jsonify({
                'success': False,
                'error': f'Erreur lors de l\'ajout du service',
                'output': result.stderr
            }), 500

    except subprocess.TimeoutExpired:
        return jsonify({'error': 'Timeout lors de l\'ajout du service'}), 504
    except Exception as e:
        return jsonify({'error': str(e)}), 500

# Endpoint de santé
@app.route('/api/health', methods=['GET'])
def health():
    """Vérifie que l'API est opérationnelle"""
    return jsonify({'status': 'ok'})

# Documentation de l'API
@app.route('/api/docs', methods=['GET'])
def docs():
    """Documentation de l'API"""
    return jsonify({
        'endpoints': {
            'POST /api/login': {
                'description': 'Authentification et génération de token JWT',
                'body': {
                    'username': 'string',
                    'password': 'string'
                },
                'response': {
                    'token': 'JWT token',
                    'username': 'string'
                }
            },
            'GET /api/services/available': {
                'description': 'Liste des services disponibles et installés',
                'headers': {
                    'Authorization': 'Bearer <token>'
                },
                'response': {
                    'available': ['service1', 'service2'],
                    'installed': ['service3']
                }
            },
            'POST /api/services/add': {
                'description': 'Ajouter un service',
                'headers': {
                    'Authorization': 'Bearer <token>'
                },
                'body': {
                    'service': 'string'
                },
                'response': {
                    'success': True,
                    'message': 'string',
                    'output': 'string'
                }
            }
        }
    })

if __name__ == '__main__':
    # En production, utiliser un serveur WSGI comme gunicorn
    # gunicorn -w 4 -b 0.0.0.0:5000 user-service-api:app
    app.run(host='0.0.0.0', port=5000, debug=False)
