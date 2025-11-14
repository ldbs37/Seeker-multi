# Guide de Configuration DNS pour Traefik

Ce guide explique comment configurer le DNS pour utiliser Traefik avec SSL automatique (Let's Encrypt) et SSO (Authelia).

## Table des matières

1. [Prérequis](#prérequis)
2. [Choix du Provider DNS](#choix-du-provider-dns)
3. [Configuration Automatique](#configuration-automatique)
4. [Configuration Manuelle](#configuration-manuelle)
5. [Vérification DNS](#vérification-dns)
6. [Dépannage](#dépannage)

---

## Prérequis

Pour utiliser Traefik avec SSL automatique, vous devez :

- ✅ Un nom de domaine pointant vers votre serveur
- ✅ Un wildcard DNS (`*.domain.com`) configuré
- ✅ Ports 80 et 443 ouverts dans votre firewall
- ✅ Un serveur avec IP publique fixe ou dynamique

**Concept Wildcard DNS :**
```
domain.com           → IP_SERVEUR
*.domain.com         → IP_SERVEUR
user1.domain.com     → IP_SERVEUR (via wildcard)
user2.domain.com     → IP_SERVEUR (via wildcard)
```

---

## Choix du Provider DNS

### Tableau Comparatif

| Provider | Coût | Wildcard | API | Automatisation | Recommandé pour |
|----------|------|----------|-----|----------------|-----------------|
| **DuckDNS** | 🟢 Gratuit | ✅ Auto | ✅ Oui | ✅ Script fourni | Pas de budget / IP dynamique |
| **Cloudflare** | 🟢 Gratuit* | ✅ Oui | ✅ Oui | ✅ Script fourni | Production / Performance |
| **OVH** | 🟡 Payant | ✅ Oui | ✅ Oui | ⚠️ Manuel | Europe / Support FR |
| **Gandi** | 🟡 Payant | ✅ Oui | ✅ Oui | ⚠️ Manuel | Privacy / Éthique |
| **Namecheap** | 🟡 Payant | ✅ Oui | ✅ Oui | ⚠️ Manuel | Budget / Simplicité |

*Cloudflare : Gratuit pour DNS, mais domaine à acheter (~10-15€/an)

### Recommandations

#### 🏆 Option 1 : DuckDNS (Le plus simple)
- ✅ **100% gratuit** (inclut le domaine)
- ✅ **Configuration automatique** avec notre script
- ✅ **Wildcard automatique** pour tous les sous-domaines
- ✅ **IP dynamique supportée** (mise à jour auto)
- ⚠️ Sous-domaine uniquement (`*.monseedbox.duckdns.org`)

**Idéal pour :**
- Débutants
- Tests et développement
- Pas de budget
- IP dynamique (connexion résidentielle)

#### 🏆 Option 2 : Cloudflare (Le plus performant)
- ✅ **DNS ultra-rapide** (réseau mondial)
- ✅ **CDN gratuit** inclus
- ✅ **Protection DDoS** automatique
- ✅ **API puissante** (automatisation complète)
- ✅ **Dashboard professionnel**
- ⚠️ Nécessite un domaine (~10-15€/an)

**Idéal pour :**
- Production
- Trafic important
- Besoin de performance
- Domaine personnalisé

---

## Configuration Automatique

### Option A : DuckDNS (Recommandé sans domaine)

#### 1. Créer un compte DuckDNS

1. Allez sur **https://www.duckdns.org/**
2. Connectez-vous avec GitHub, Google, Reddit ou Twitter
3. Notez votre **token** en haut de la page

#### 2. Lancer le script automatique

```bash
sudo ./scripts/setup_duckdns.sh
```

Le script va :
- ✅ Créer votre sous-domaine DuckDNS
- ✅ Configurer le wildcard automatique
- ✅ Installer un cron job pour IP dynamique
- ✅ Sauvegarder la config dans `.env`

**Résultat :**
```
Domaine: monseedbox.duckdns.org
Wildcard: *.monseedbox.duckdns.org
Mise à jour IP: Automatique (toutes les 5 minutes)
```

#### 3. Installer Traefik

```bash
sudo ./scripts/setup_traefik.sh monseedbox.duckdns.org
```

---

### Option B : Cloudflare (Recommandé avec domaine)

#### 1. Prérequis

- Avoir un domaine (acheté chez n'importe quel registrar)
- Créer un compte Cloudflare gratuit
- Transférer la gestion DNS vers Cloudflare

**Transférer DNS vers Cloudflare :**

1. Allez sur **https://dash.cloudflare.com/**
2. Cliquez sur **"Add a Site"**
3. Entrez votre domaine (ex: `monseedbox.com`)
4. Choisissez le plan **Free**
5. Cloudflare vous donnera 2 nameservers (ex: `ns1.cloudflare.com`)
6. Allez chez votre registrar (OVH, Gandi, etc.)
7. Changez les nameservers pour ceux de Cloudflare
8. Attendez 24-48h pour la propagation

#### 2. Créer un API Token

1. Allez sur **https://dash.cloudflare.com/profile/api-tokens**
2. Cliquez sur **"Create Token"**
3. Utilisez le template **"Edit zone DNS"**
4. **Permissions** :
   - Zone - DNS - Edit
   - Zone - Zone - Read
5. **Zone Resources** :
   - Include - Specific zone - `votre-domaine.com`
6. Cliquez sur **"Continue to summary"**
7. Cliquez sur **"Create Token"**
8. **Copiez le token** (vous ne pourrez plus le voir)

#### 3. Lancer le script automatique

```bash
sudo ./scripts/setup_cloudflare.sh
```

Le script va vous demander :
- Votre API Token Cloudflare
- Votre nom de domaine

Puis il va automatiquement :
- ✅ Valider le token
- ✅ Récupérer le Zone ID
- ✅ Créer l'enregistrement A pour `domain.com`
- ✅ Créer l'enregistrement A pour `*.domain.com`
- ✅ Vérifier la configuration DNS

**Résultat :**
```
Enregistrements créés:
  domain.com → IP_SERVEUR
  *.domain.com → IP_SERVEUR
```

#### 4. Installer Traefik

```bash
sudo ./scripts/setup_traefik.sh monseedbox.com
```

---

## Configuration Manuelle

Si vous ne souhaitez pas utiliser les scripts automatiques ou que vous utilisez un autre provider DNS.

### Enregistrements à créer

Vous devez créer **2 enregistrements DNS de type A** :

| Type | Nom | Valeur | TTL |
|------|-----|--------|-----|
| A | `@` (ou domaine.com) | `IP_DU_SERVEUR` | 300 |
| A | `*` (ou *.domaine.com) | `IP_DU_SERVEUR` | 300 |

**Exemple avec `monseedbox.com` et IP `203.0.113.42` :**

```
monseedbox.com     A    203.0.113.42    300
*.monseedbox.com   A    203.0.113.42    300
```

### Configuration par Provider

#### OVH

1. Allez sur https://www.ovh.com/manager/
2. **Web Cloud** → **Domaines** → Cliquez sur votre domaine
3. Onglet **"Zone DNS"**
4. Cliquez sur **"Ajouter une entrée"**

**Enregistrement 1 - Domaine principal :**
- Type : `A`
- Sous-domaine : (laissez vide)
- Cible : `IP_DU_SERVEUR`
- TTL : `300`

**Enregistrement 2 - Wildcard :**
- Type : `A`
- Sous-domaine : `*`
- Cible : `IP_DU_SERVEUR`
- TTL : `300`

5. Cliquez sur **"Suivant"** puis **"Valider"**
6. Attendez 5-10 minutes pour la propagation

#### Gandi

1. Allez sur https://admin.gandi.net/
2. **Domaines** → Cliquez sur votre domaine
3. Onglet **"Enregistrements DNS"**
4. Cliquez sur **"Ajouter"**

**Enregistrement 1 - Domaine principal :**
- Type : `A`
- Nom : `@`
- Valeur : `IP_DU_SERVEUR`
- TTL : `300`

**Enregistrement 2 - Wildcard :**
- Type : `A`
- Nom : `*`
- Valeur : `IP_DU_SERVEUR`
- TTL : `300`

5. Cliquez sur **"Créer"**
6. Attendez 5-10 minutes pour la propagation

#### Namecheap

1. Allez sur https://ap.www.namecheap.com/
2. **Domain List** → Cliquez sur **"Manage"** à côté de votre domaine
3. Section **"Advanced DNS"**
4. Cliquez sur **"Add New Record"**

**Enregistrement 1 - Domaine principal :**
- Type : `A Record`
- Host : `@`
- Value : `IP_DU_SERVEUR`
- TTL : `Automatic`

**Enregistrement 2 - Wildcard :**
- Type : `A Record`
- Host : `*`
- Value : `IP_DU_SERVEUR`
- TTL : `Automatic`

5. Cliquez sur **"Save Changes"**
6. Attendez 30 minutes pour la propagation

---

## Vérification DNS

### Script de vérification automatique

```bash
./scripts/check_dns.sh monseedbox.com
```

Ce script vérifie :
- ✅ Résolution du domaine principal
- ✅ Résolution du wildcard
- ✅ Accessibilité des ports 80 et 443
- ✅ Propagation DNS globale

**Exemple de sortie :**
```
[✓] monseedbox.com résout correctement vers 203.0.113.42
[✓] test.monseedbox.com résout correctement vers 203.0.113.42
[✓] Port 80 accessible
[✓] Port 443 accessible
[✓] Propagation DNS complète sur tous les serveurs testés

Configuration DNS complète et fonctionnelle !
```

### Vérification manuelle

#### Test avec dig

```bash
# Tester le domaine principal
dig monseedbox.com +short
# Devrait retourner: 203.0.113.42

# Tester le wildcard
dig test.monseedbox.com +short
# Devrait retourner: 203.0.113.42

# Tester un autre sous-domaine
dig user1.monseedbox.com +short
# Devrait retourner: 203.0.113.42
```

#### Test avec nslookup

```bash
# Tester le domaine
nslookup monseedbox.com
# Devrait retourner votre IP

# Tester le wildcard
nslookup user1.monseedbox.com
# Devrait retourner votre IP
```

#### Test avec ping

```bash
# Tester la connectivité
ping monseedbox.com
ping user1.monseedbox.com
```

---

## Dépannage

### Problème 1 : DNS ne résout pas

**Symptôme :** `dig monseedbox.com` ne retourne aucune IP

**Solutions :**

1. **Vérifiez que les enregistrements DNS sont créés**
   - Connectez-vous à votre provider DNS
   - Vérifiez la présence des enregistrements A

2. **Attendez la propagation DNS**
   - Propagation normale : 5-30 minutes
   - Propagation maximale : 24-48 heures
   - Utilisez https://www.whatsmydns.net/ pour suivre la propagation

3. **Vérifiez le TTL**
   - Un TTL élevé (3600+) ralentit les changements
   - Réduisez le TTL à 300 secondes

4. **Flush le cache DNS local**
   ```bash
   # Linux
   sudo systemd-resolve --flush-caches

   # macOS
   sudo dscacheutil -flushcache

   # Windows
   ipconfig /flushdns
   ```

### Problème 2 : Wildcard ne fonctionne pas

**Symptôme :** `monseedbox.com` fonctionne mais pas `user1.monseedbox.com`

**Solutions :**

1. **Vérifiez l'enregistrement wildcard**
   ```bash
   dig *.monseedbox.com +short
   ```

2. **Certains providers ont des syntaxes différentes**
   - OVH : `*`
   - Gandi : `*`
   - Cloudflare : `*`
   - Namecheap : `*`

3. **Créez un enregistrement explicite pour tester**
   ```
   test.monseedbox.com  A  IP_DU_SERVEUR
   ```

### Problème 3 : Ports 80/443 inaccessibles

**Symptôme :** DNS fonctionne mais ports fermés

**Solutions :**

1. **Vérifiez le firewall serveur**
   ```bash
   # UFW
   sudo ufw allow 80/tcp
   sudo ufw allow 443/tcp

   # iptables
   sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
   sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT
   ```

2. **Vérifiez le firewall cloud**
   - OVH : Security Groups
   - AWS : Security Groups
   - Azure : Network Security Groups
   - GCP : Firewall Rules

3. **Vérifiez qu'aucun service n'utilise déjà les ports**
   ```bash
   sudo netstat -tulpn | grep -E ':80|:443'
   ```

### Problème 4 : Cloudflare API ne fonctionne pas

**Symptôme :** Erreur lors de l'exécution de `setup_cloudflare.sh`

**Solutions :**

1. **Vérifiez le token API**
   - Le token doit avoir les permissions "Edit zone DNS"
   - Le token ne doit pas être expiré

2. **Vérifiez la zone**
   - Le domaine doit être configuré sur Cloudflare
   - Les nameservers doivent pointer vers Cloudflare

3. **Testez manuellement l'API**
   ```bash
   curl -X GET "https://api.cloudflare.com/v4/user/tokens/verify" \
     -H "Authorization: Bearer VOTRE_TOKEN" \
     -H "Content-Type: application/json"
   ```

### Problème 5 : DuckDNS ne se met pas à jour

**Symptôme :** IP ne correspond pas à l'IP actuelle du serveur

**Solutions :**

1. **Vérifiez le cron job**
   ```bash
   crontab -l | grep duckdns
   ```

2. **Testez le script de mise à jour**
   ```bash
   sudo /opt/seedbox/scripts/duckdns_update.sh
   ```

3. **Vérifiez le token DuckDNS**
   - Connectez-vous sur https://www.duckdns.org/
   - Vérifiez que le token est correct

4. **Forcez une mise à jour manuelle**
   ```bash
   curl "https://www.duckdns.org/update?domains=SUBDOMAIN&token=TOKEN&ip="
   ```

---

## FAQ

### Puis-je utiliser un sous-domaine au lieu du domaine principal ?

Oui ! Vous pouvez utiliser un sous-domaine :

**Exemple avec `seedbox.monseedbox.com` :**

1. Créez les enregistrements :
   ```
   seedbox.monseedbox.com    A    IP_SERVEUR
   *.seedbox.monseedbox.com  A    IP_SERVEUR
   ```

2. Installez Traefik avec :
   ```bash
   sudo ./scripts/setup_traefik.sh seedbox.monseedbox.com
   ```

3. Vos utilisateurs seront accessibles sur :
   ```
   user1.seedbox.monseedbox.com
   user2.seedbox.monseedbox.com
   ```

### Dois-je utiliser un proxy Cloudflare ?

**Non, désactivez le proxy (nuage gris) pour :**
- Éviter les limitations de débit
- Avoir l'IP réelle dans les logs
- Éviter les problèmes WebSocket

**Oui, activez le proxy (nuage orange) si :**
- Vous voulez masquer l'IP du serveur
- Vous avez besoin de protection DDoS
- Vous voulez utiliser le CDN

### Mon FAI bloque les ports 80/443, que faire ?

**Solutions :**

1. **Utiliser un VPS**
   - Louer un petit VPS (5€/mois)
   - Faire un reverse proxy vers votre serveur local

2. **Utiliser Cloudflare Tunnel (gratuit)**
   - Ne nécessite pas de ports 80/443 ouverts
   - Documentation : https://developers.cloudflare.com/cloudflare-one/connections/connect-apps/

3. **Utiliser un port alternatif**
   - Traefik peut écouter sur d'autres ports
   - Nécessite de spécifier le port dans l'URL

### Combien de temps prend la propagation DNS ?

- **DuckDNS** : 1-5 minutes
- **Cloudflare** : 1-5 minutes
- **OVH** : 5-30 minutes
- **Gandi** : 5-30 minutes
- **Namecheap** : 30 minutes - 2 heures

**Propagation mondiale complète** : 24-48 heures maximum

---

## Support et Aide

### Documentation officielle

- **Traefik** : https://doc.traefik.io/traefik/
- **Let's Encrypt** : https://letsencrypt.org/docs/
- **Cloudflare** : https://developers.cloudflare.com/dns/
- **DuckDNS** : https://www.duckdns.org/spec.jsp

### Scripts fournis

```bash
# Vérification DNS
./scripts/check_dns.sh <domain>

# Configuration Cloudflare automatique
sudo ./scripts/setup_cloudflare.sh

# Configuration DuckDNS automatique
sudo ./scripts/setup_duckdns.sh

# Installation Traefik
sudo ./scripts/setup_traefik.sh <domain>
```

### Tests rapides

```bash
# Test DNS complet
./scripts/check_dns.sh monseedbox.com

# Test manuel du wildcard
dig test.monseedbox.com +short

# Test des ports
nc -zv IP_SERVEUR 80
nc -zv IP_SERVEUR 443

# Propagation DNS mondiale
curl "https://www.whatsmydns.net/api/details?server=google&type=A&query=monseedbox.com"
```

---

## Conclusion

Vous avez maintenant toutes les informations pour configurer votre DNS correctement.

**Récapitulatif :**

1. ✅ Choisissez votre provider (DuckDNS ou Cloudflare recommandés)
2. ✅ Utilisez les scripts automatiques fournis
3. ✅ Vérifiez avec `check_dns.sh`
4. ✅ Installez Traefik avec `setup_traefik.sh`
5. ✅ Créez vos utilisateurs et profitez du SSL automatique !

**Besoin d'aide ?**
- Consultez la section [Dépannage](#dépannage)
- Vérifiez les logs : `docker logs traefik`
- Ouvrez une issue sur GitHub
