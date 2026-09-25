# Jellyfin : configuration automatique

Aucune manipulation dans Jellyfin : comptes, bibliothèques privées et
connexion via Authelia sont préparés par les scripts (`scripts/lib_jellyfin.sh`,
vérifié sur Jellyfin 10.11.11 et le plugin SSO 4.0.0.4).

## Ce qui est fait

| Élément | Détail |
|---------|--------|
| Assistant de démarrage | Terminé automatiquement, dans la langue de la seedbox |
| Administrateur | Le premier administrateur seedbox (même nom, même mot de passe à l'installation) |
| Compte de chaque utilisateur | Même nom et même mot de passe que la seedbox |
| Bibliothèques | Pour chacun : *Séries TV*, *Films*, *Livres*, *Musique* dans son dossier (`data/users/<user>/tv`…) |
| Cloisonnement | Chacun ne voit que SES bibliothèques ; les administrateurs voient tout |
| Connexion web (mode Traefik) | Bouton **« Se connecter avec Authelia »** sur https://jellyfin.votre-domaine.com |
| Applis TV / mobile | Mot de passe seedbox, ou **Quick Connect** |
| Clé d'API | Clé « seedbox » (`/opt/seedbox/.jellyfin_api`), pour les scripts et Homarr |

## Quand

- **Installation** (`install.sh`, Jellyfin coché) : administrateur = premier
  utilisateur, comptes des utilisateurs initiaux, connexion Authelia.
- **Ajout d'un utilisateur** (`add_user.sh`) : son compte et ses bibliothèques.
- **Changement de mot de passe** (`update_password.sh`) : mis à jour dans
  Jellyfin ; compte créé s'il manquait.
- **Suppression** (`remove_user.sh`) : compte et bibliothèques retirés (les
  fichiers restent).
- **Installation existante / ajout de Jellyfin** (`generate_traefik_labels.sh`,
  `add_service.sh jellyfin`) : assistant terminé si besoin, comptes manquants
  créés (mot de passe aléatoire), connexion Authelia.

Un compte créé sans mot de passe connu se connecte via Authelia ; pour le mot
de passe des applis : `sudo /opt/seedbox/scripts/update_password.sh <utilisateur>`
(même mot de passe partout).

## Connexion via Authelia (mode Traefik)

Plugin communautaire [SSO Authentication](https://github.com/9p4/jellyfin-plugin-sso)
(installé et configuré par les scripts) et client OIDC `jellyfin` dans
Authelia (secret `JELLYFIN_OIDC_SECRET` du `.env`). À chaque connexion, les
droits suivent les groupes Authelia :

- `users` : seul groupe autorisé à se connecter ;
- `u-<user>` : ses bibliothèques ;
- `admins` : administrateur Jellyfin, toutes les bibliothèques.

Les comptes existants sont retrouvés par leur nom (le mot de passe reste
valable pour les applis). Un administrateur voit une bibliothèque ajoutée
depuis sa dernière connexion via Authelia à la connexion suivante.

### Quick Connect (TV, applis)

Dans l'appli : *Quick Connect* affiche un code ; dans Jellyfin (navigateur,
connecté via Authelia) : *Paramètres → Quick Connect*, saisir le code.

## Réparer un compte

```bash
sudo /opt/seedbox/scripts/configure_jellyfin_user.sh <utilisateur> [mot_de_passe]
```

Recrée ce qui manque (compte, bibliothèques, droits) sans doublon.

## Sécurité

- Clé d'API créée par l'API quand le mot de passe administrateur est connu ;
  sinon écrite dans la base de Jellyfin **Jellyfin arrêté** (quelques
  secondes, une fois) : écrire dans la base d'un Jellyfin en marche peut
  l'endommager.
- Jellyfin reste joignable sans Authelia (applis TV/mobile) : sa propre
  authentification s'applique.
