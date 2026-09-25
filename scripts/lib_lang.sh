#!/bin/bash
#######################
# lib_lang.sh — Langue par défaut des interfaces (choisie à l'installation)
#
# SEEDBOX_LANG du .env (défaut : fr), appliquée à qBittorrent, VueTorrent,
# FileBrowser Quantum, Homarr et Jellyfin. Chacun peut ensuite changer la
# sienne dans les réglages de l'appli.
#######################

# shellcheck disable=SC2034  # lue par les bibliothèques sourcées
SEEDBOX_LANGS="fr en de es it"

# Langue en vigueur : variable SEEDBOX_LANG, sinon .env, sinon fr
seedbox_lang() {
    local l="${SEEDBOX_LANG:-}"
    [ -n "$l" ] || l=$(grep '^SEEDBOX_LANG=' "${INSTALL_DIR:-/opt/seedbox}/.env" 2>/dev/null | cut -d= -f2)
    case " $SEEDBOX_LANGS " in *" $l "*) echo "$l" ;; *) echo fr ;; esac
}

lang_label() {
    case "$1" in
        fr) echo "Français" ;; en) echo "English" ;; de) echo "Deutsch" ;;
        es) echo "Español" ;;  it) echo "Italiano" ;; *) echo "$1" ;;
    esac
}

# Culture Jellyfin et pays des métadonnées : « fr-FR FR »
lang_jellyfin() {
    case "$1" in
        en) echo "en-US US" ;; de) echo "de-DE DE" ;; es) echo "es-ES ES" ;;
        it) echo "it-IT IT" ;; *) echo "fr-FR FR" ;;
    esac
}
