# Jellyfin : configuration automatique

Aucune manipulation dans Jellyfin : comptes, bibliothèques privées et
connexion via Authelia sont préparés par les scripts (`scripts/lib_jellyfin.sh`,
vérifié sur Jellyfin 12.1 (et 10.11) avec le plugin SSO 4.0.0.4).

## Ce qui est fait

| Élément | Détail |
|---------|--------|
| Assistant de démarrage | Terminé automatiquement, dans la langue de la seedbox |
| Administrateur | Le premier administrateur seedbox (même nom, même mot de passe à l'installation) |
| Compte de chaque utilisateur | Même nom et même mot de passe que la seedbox |
| Bibliothèques | Pour chacun : *Séries TV* et *Films* dans son dossier (`data/users/<user>/tv`, `movies`) ; les anciennes bibliothèques *Livres* / *Musique* sont retirées (fichiers conservés) |
| Cloisonnement | Chacun ne voit que SES bibliothèques ; les administrateurs voient tout |
| Connexion web | Bouton **« Se connecter avec Authelia »** sur https://jellyfin.votre-domaine.com |
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

## Connexion via Authelia

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

## Seerr (demandes)

Le Seerr de chaque utilisateur (`https://seerr-<user>.votre-domaine.com`)
est configuré par `arr_setup.sh` (`lib_seerr.sh`) :

- relié à Jellyfin par un **jeton au nom de l'utilisateur** (Quick Connect,
  autorisé par la clé d'API seedbox) : il ne voit que ses bibliothèques, et
  la clé administrateur de Jellyfin n'est jamais confiée à Seerr (chacun
  est administrateur de son Seerr et pourrait la lire). Adresse interne
  `http://jellyfin:8096`. Jeton révoqué (ancienne version) : renouvelé par
  `arr_setup.sh` ;
- son administrateur = le compte Jellyfin de l'utilisateur ;
- **connexion automatique** après Authelia : Seerr n'ayant ni OIDC ni
  authentification par en-tête, la seedbox fixe son secret de signature et
  crée une session pour son propriétaire, que Traefik présente à chaque
  requête (secrets dans `/opt/seedbox/secrets/seerr-<user>.env`, session
  prolongée chaque jour par le timer `seedbox-seerr-sessions`) ; le bouton
  « Déconnexion » de Seerr déconnecte d'Authelia ;
- adresse : `https://seerr-<user>.votre-domaine.com` (Seerr ne gère pas de
  sous-chemin) ;
- ses Sonarr / Radarr (profil « Seedbox optimisé », `/data/tv`, `/data/movies`) ; leurs
  profils sont en français (Radarr : langue « French » ; Sonarr : format
  personnalisé « VF » exigé). Les MULTi comptent comme françaises si
  l'indexeur l'indique (réglage « Multi Languages »).
- nommage pour Jellyfin (Sonarr / Radarr, appliqué une fois, médias déjà
  présents compris) : `Titre (Année) [tmdbid-…]/Titre (Année) [tmdbid-…] -
  Qualité.mkv` pour les films, `Série (Année) [tvdbid-…]/Season 01/Série
  (Année) - S01E01 - Titre Qualité.mkv` pour les séries. Jellyfin lit
  l'identifiant et ne devine plus. Les fichiers sont liés (pas copiés) à ceux
  de qBittorrent : le partage continue.

Profil « Seedbox optimisé » (Sonarr / Radarr, créé une fois, attribué aux
médias existants et utilisé par Seerr) :

- qualités : 720p minimum, 1080p, 4K (préférée si elle respecte la taille) ;
  ni Remux, ni BR-DISK ;
- taille : au plus 4 Go par film (Radarr), 2 Go par heure d'épisode (Sonarr,
  packs de saison compris) : une 4K n'est prise que « légère » ;
- meilleur rapport qualité / place : taille préférée réduite (film 1080p de
  2 h : environ 2,4 Go) et formats personnalisés (liste `ARR_BONUS` de
  `lib_arr.sh`, complétée dans un profil existant) :

  | Format | Score |
  |---|---|
  | HEVC (x265, H.265), AV1, 10 bits | +20 |
  | HDR / HDR10 / HDR10+, EAC3 (DD+), Atmos | +15 |
  | IMAX, 5.1 / 7.1, VFF (TRUEFRENCH) | +10 |
  | VFQ (doublage québécois) | -10 |
  | 3D, upscale (fausse 4K) ; Radarr : plus de 4 Go | refusé |

- mises à niveau automatiques jusqu'à la 4K ; toujours en français.

Un torrent ajouté à la main dans qBittorrent reste dans `downloads/` (hors
bibliothèques). Pour qu'il arrive rangé dans Jellyfin : ajouter le film ou la
série dans Radarr / Sonarr (ou le demander dans Seerr), puis donner au
torrent la catégorie `radarr` ou `tv-sonarr` ; déjà téléchargé : Activité →
« Import manuel ».
- pas de connexion locale (mot de passe Seerr), pas d'inscription d'autres
  comptes Jellyfin ;
- l'utilisateur est administrateur de son Seerr : ses demandes sont
  **validées automatiquement** et envoyées à Sonarr / Radarr ;
- pays de diffusion et région de découverte : ceux de la langue de la
  seedbox (France pour le français), sauf s'ils ont déjà été choisis.

Un Seerr déjà configuré à la main n'est pas modifié (seuls un Sonarr ou un
Radarr manquants sont ajoutés). Quick Connect doit rester activé dans
Jellyfin (réglage par défaut).

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
