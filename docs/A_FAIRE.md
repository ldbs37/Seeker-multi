# À faire plus tard

## 1. Activer les quotas disque (Dedibox, racine ext4 `/dev/sda3`)

Les quotas projet ext4 demandent les fonctionnalités `project` et `quota`, qui
ne s'activent que **disque démonté** → passage par le **mode rescue**.

0. Sauvegarde :
   ```bash
   sudo /opt/seedbox/scripts/backup.sh --label avant-quotas
   ```
1. Console Scaleway / Online → serveur → **Rescue** (image Ubuntu). Noter les
   identifiants temporaires affichés.
2. Dans le rescue (`ssh` avec ces identifiants, puis `sudo -i`) :
   ```bash
   lsblk -f                                  # repérer la partition ext4 de 1,8 To (sda3 ?) — elle ne doit PAS être montée
   e2fsck -f /dev/sda3
   tune2fs -O project,quota -Q prjquota /dev/sda3
   ```
3. Console → sortir du rescue (retour au démarrage normal).
4. Sur le serveur :
   ```bash
   sudo /opt/seedbox/scripts/enable_quotas.sh          # → « Quotas projet ext4 actifs »
   sudo /opt/seedbox/scripts/update_quota.sh louis 500 # Go, pour chaque utilisateur
   sudo /opt/seedbox/scripts/healthcheck.sh --quiet
   ```

`enable_quotas.sh` revérifie tout avant d'agir : si l'étape rescue n'a pas été
faite, il réaffiche la procédure sans modifier `/etc/fstab`.

## 2. Homarr 1.0 : tableaux de bord automatiques par utilisateur

Homarr partagé (https://ldbs.ovh) + connexion unique Authelia en place. Reste
à créer automatiquement le tableau de bord de chaque utilisateur (tuiles de
ses services) via l'API REST de Homarr (`POST /api/apps`, `/api/boards`,
`/api/boards/items`) : nécessite une clé d'API créée une fois par l'admin
(Homarr → Gestion → Clés d'API), format des appels à valider sur l'instance.
