FROM python:3.11-slim

WORKDIR /app

# Installer les dépendances système
RUN apt-get update && \
    apt-get install -y sudo && \
    rm -rf /var/lib/apt/lists/*

# Copier les requirements
COPY requirements.txt .

# Installer les dépendances Python
RUN pip install --no-cache-dir -r requirements.txt

# Copier l'application
COPY user-service-api.py .

# Créer un utilisateur non-root
RUN useradd -m -u 1000 apiuser && \
    echo "apiuser ALL=(ALL) NOPASSWD: /opt/seedbox/scripts/add_user_service.sh" >> /etc/sudoers

USER apiuser

# Exposer le port
EXPOSE 5000

# Lancer l'application avec gunicorn
CMD ["gunicorn", "-w", "4", "-b", "0.0.0.0:5000", "user-service-api:app"]
