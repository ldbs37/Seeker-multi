# Authentification commune (SSO) pour Jellyfin via Authelia OIDC

Ce guide explique comment donner à Jellyfin une **authentification commune** avec
les autres services, en utilisant **Authelia comme fournisseur OpenID Connect
(OIDC)** et le plugin **SSO-Auth** de Jellyfin.

> ⚠️ **À lire avant de commencer**
>
> - Cette procédure est **manuelle** : le plugin Jellyfin ne peut pas être
>   installé proprement via `docker-compose`, il s'installe depuis l'interface
>   Jellyfin.
> - **N'appliquez PAS** le middleware `authelia@docker` (forward-auth) sur
>   Jellyfin : il casse **toutes les applications natives** (Android TV, iOS,
>   Kodi, box opérateur…). L'installeur laisse volontairement Jellyfin **sans**
>   ce middleware.
> - Le SSO OIDC fonctionne surtout sur le **client web** de Jellyfin. Les
>   applications natives continuent d'utiliser le login classique ou
>   **Quick Connect** (support OIDC partiel selon l'application).
> - Authelia (backend fichier) et Jellyfin restent **deux annuaires séparés** :
>   à la première connexion OIDC, le compte Jellyfin est créé automatiquement.
> - Testé conceptuellement avec **Authelia 4.39.x** (version épinglée par
>   l'installeur). Adaptez si vous changez de version : le format de config OIDC
>   d'Authelia a évolué en 4.38+.

Dans tout ce guide, remplacez `example.com` par votre domaine et
`auth.example.com` / `jellyfin.example.com` par vos sous-domaines réels.

---

## Prérequis

- Installation en **mode Traefik + SSL** (`USE_TRAEFIK=true`), avec Authelia
  accessible sur `https://auth.example.com` et Jellyfin sur
  `https://jellyfin.example.com`.
- Accès `root`/`sudo` au serveur.
- Le binaire `authelia` disponible dans le conteneur (`docker exec authelia
  authelia ...`) pour générer les secrets.

---

## Étape 1 — Générer les secrets nécessaires

Authelia OIDC a besoin de trois éléments :

1. un **secret HMAC** ;
2. une **paire de clés RSA** (JWKS, pour signer les jetons) ;
3. un **secret client** pour Jellyfin (stocké **haché** côté Authelia, en
   **clair** côté Jellyfin).

Générez-les via le conteneur Authelia :

```bash
# 1. Secret HMAC
docker exec authelia authelia crypto rand --length 72 --charset alphanumeric

# 2. Paire de clés RSA (crée private.pem / public.pem dans /config)
docker exec -w /config authelia authelia crypto pair rsa generate

# 3. Secret client Jellyfin : générer un secret ALÉATOIRE puis son HASH
#    -> Notez la valeur en clair (pour Jellyfin) ET le hash (pour Authelia)
docker exec authelia authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72
```

La dernière commande affiche à la fois le mot de passe **en clair** (`Random
Password:`) et son **hash** (`Digest:` commençant par `$pbkdf2-sha512$...`).

- Le **clair** → à saisir dans le plugin Jellyfin (Client Secret).
- Le **hash** → à mettre dans la config Authelia (`client_secret`).

Récupérez le contenu de la clé privée RSA :

```bash
docker exec authelia cat /config/private.pem
```

---

## Étape 2 — Configurer Authelia en fournisseur OIDC

Éditez `/opt/seedbox/authelia/configuration.yml` et **ajoutez** le bloc
`identity_providers` (au même niveau que `authentication_backend`,
`access_control`, `session`, etc.) :

```yaml
identity_providers:
  oidc:
    hmac_secret: 'COLLEZ_LE_SECRET_HMAC_ICI'
    jwks:
      - key_id: 'main'
        algorithm: 'RS256'
        use: 'sig'
        key: |
          -----BEGIN RSA PRIVATE KEY-----
          COLLEZ_LE_CONTENU_DE_private.pem_ICI
          -----END RSA PRIVATE KEY-----
    clients:
      - client_id: 'jellyfin'
        client_name: 'Jellyfin'
        client_secret: 'COLLEZ_LE_HASH_$pbkdf2-sha512$...'
        public: false
        authorization_policy: 'one_factor'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
          - 'https://jellyfin.example.com/sso/OID/redirect/authelia'
        scopes:
          - 'openid'
          - 'profile'
          - 'groups'
          - 'email'
        userinfo_signed_response_alg: 'none'
        token_endpoint_auth_method: 'client_secret_post'
```

> - `client_secret` = le **hash** `$pbkdf2-sha512$...` (jamais le clair).
> - L'`redirect_uris` doit correspondre **exactement** à l'URL de callback du
>   plugin (voir Étape 4). Ici le nom du provider est `authelia`.

### Autoriser Jellyfin dans `access_control`

Jellyfin gère lui-même l'accès une fois connecté ; une politique `one_factor`
suffit. Si vous voulez restreindre l'accès OIDC à un groupe, ajoutez une règle,
sinon la politique du client (`one_factor` ci-dessus) s'applique.

Redémarrez Authelia :

```bash
cd /opt/seedbox && docker compose restart authelia
# Vérifiez les logs
docker compose logs --tail=50 authelia
```

Vérifiez que la découverte OIDC répond :

```bash
curl -s https://auth.example.com/.well-known/openid-configuration | head
```

---

## Étape 3 — Installer le plugin SSO-Auth dans Jellyfin

Le plugin utilisé est **`jellyfin-plugin-sso`** (auteur : *9p4*).

1. Ouvrez Jellyfin : `https://jellyfin.example.com` → connectez-vous en **admin**.
2. **Tableau de bord → Plugins → Dépôts (Repositories)** → **Ajouter** :
   - **Nom** : `SSO`
   - **URL** :
     `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`
3. **Catalogue (Catalog)** → cherchez **SSO Authentication** → **Installer**.
4. **Redémarrez** Jellyfin :
   ```bash
   cd /opt/seedbox && docker compose restart jellyfin
   ```

---

## Étape 4 — Configurer le plugin SSO-Auth

**Tableau de bord → Plugins → SSO-Auth**, puis créez un provider avec ces valeurs :

| Champ | Valeur |
|-------|--------|
| **Name of OID Provider** | `authelia` (⚠️ doit correspondre au segment de l'`redirect_uris`) |
| **OID Endpoint** | `https://auth.example.com` |
| **OpenID Client ID** | `jellyfin` |
| **OID Secret** | le **secret client en clair** (Étape 1.3) |
| **Enabled** | ✅ |
| **Enable Authorization by Plugin** | ✅ |
| **Enable All Folders** | ✅ (ou sélectionnez les bibliothèques) |
| **Roles / Admin Roles** | laissez vide, ou mappez via le scope `groups` (voir plus bas) |
| **Scopes** | `openid`, `profile`, `groups`, `email` |
| **Set default provider** | optionnel |

L'**URL de callback** attendue par le plugin est :

```
https://jellyfin.example.com/sso/OID/redirect/authelia
```

C'est **exactement** la valeur mise dans `redirect_uris` d'Authelia (Étape 2).
Le bouton de connexion SSO est accessible sur :

```
https://jellyfin.example.com/sso/OID/start/authelia
```

Enregistrez.

---

## Étape 5 — Tester

1. Ouvrez une **fenêtre de navigation privée**.
2. Allez sur `https://jellyfin.example.com/sso/OID/start/authelia`.
3. Vous êtes redirigé vers Authelia → connectez-vous avec un compte Authelia.
4. Retour sur Jellyfin : le compte est créé/connecté automatiquement.

### (Optionnel) Bouton « Se connecter avec Authelia » sur la page de login

Le plugin fournit un extrait à coller dans **Tableau de bord → Général →
Custom CSS** ou via l'option *branding*. Voir la documentation du plugin
(section *Adding a login button*) :
`https://github.com/9p4/jellyfin-plugin-sso`

---

## Restrictions d'accès par groupe (optionnel)

Pour n'autoriser que certains groupes Authelia (ex. `media`) :

- Dans le plugin : renseignez **Roles** = `media` et cochez **Enable
  Authorization by Plugin**.
- Assurez-vous qu'Authelia envoie bien le scope `groups` (déjà dans la config
  du client ci-dessus). Les groupes proviennent de
  `/opt/seedbox/authelia/users_database.yml`.

---

## Limites connues (rappel)

- **Applications natives** (Android/Android TV, iOS, Kodi, box opérateur) :
  support OIDC partiel ou absent → elles utilisent le **login classique** ou
  **Quick Connect**. Gardez donc au moins un mot de passe Jellyfin, ou activez
  Quick Connect (**Tableau de bord → Général → Quick Connect**).
- **Ne mettez jamais** le forward-auth Authelia (`authelia@docker`) devant
  Jellyfin : cela bloquerait aussi les API utilisées par les applis.
- Après une montée de version d'Authelia, revérifiez le format du bloc
  `identity_providers.oidc` (il a changé en 4.38+).

---

## Dépannage

| Symptôme | Piste |
|----------|-------|
| `invalid_client` | Le hash `client_secret` (Authelia) ne correspond pas au clair (Jellyfin), ou mauvais `client_id`. |
| `redirect_uri did not match` | L'`redirect_uris` d'Authelia ≠ URL de callback du plugin (nom du provider différent). |
| Page blanche après login | Vérifiez `docker compose logs authelia` et que `OID Endpoint` est en **https** joignable depuis le conteneur Jellyfin. |
| `/.well-known/openid-configuration` en 404 | Le bloc `identity_providers.oidc` n'est pas chargé : erreur YAML → voir les logs Authelia. |
