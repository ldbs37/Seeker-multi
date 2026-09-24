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

## 2. Homarr 1.0 : intégrations (widgets)

Les tuiles sont créées automatiquement (`homarr_provision.sh`). Reste possible :
brancher les intégrations (qBittorrent, Sonarr, Radarr… : téléchargements en
cours, calendrier) avec les adresses internes (`http://sonarr-<user>:8989/sonarr`…)
et les clés d'API des *arr (lisibles dans leur config.xml).
