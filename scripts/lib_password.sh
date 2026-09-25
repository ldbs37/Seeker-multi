#!/bin/bash
#######################
# lib_password.sh — Règle de mot de passe des comptes seedbox (source unique)
#
# Utilisée par install.sh, add_user.sh, update_password.sh et menu.sh.
# Le même mot de passe sert à Linux, Authelia, qBittorrent, Filebrowser et
# Jellyfin. Minimum distinct possible pour les administrateurs (accès
# Portainer/Traefik) : aujourd'hui identique.
#######################

PASSWORD_MIN_LEN=12         # utilisateurs
PASSWORD_MIN_LEN_ADMIN=12   # administrateurs (groupe "admins" d'Authelia)

# Règle en clair. $1 = true pour un administrateur
password_policy() {
    local min=$PASSWORD_MIN_LEN
    [ "${1:-false}" = true ] && min=$PASSWORD_MIN_LEN_ADMIN
    echo "$min caractères minimum, dont 1 majuscule et 1 caractère spécial"
}

# Vérifie un mot de passe. $1 = mot de passe, $2 = true pour un administrateur.
# Retour 0 si conforme ; sinon 1 et la raison sur stdout.
password_check() {
    local p="$1" min=$PASSWORD_MIN_LEN
    [ "${2:-false}" = true ] && min=$PASSWORD_MIN_LEN_ADMIN
    if [ ${#p} -lt "$min" ]; then
        echo "au moins $min caractères requis"; return 1
    fi
    # Classes POSIX (indépendantes de la locale, contrairement à [A-Z])
    if ! [[ "$p" =~ [[:upper:]] ]]; then
        echo "au moins 1 majuscule requise"; return 1
    fi
    if ! [[ "$p" =~ [[:punct:]] ]]; then
        echo "au moins 1 caractère spécial requis (ex. ! ? @ # - _ .)"; return 1
    fi
    return 0
}

# L'utilisateur est-il administrateur (groupe "admins" dans Authelia) ?
# $1 = utilisateur, $2 = users_database.yml
password_user_is_admin() {
    awk -v u="  $1:" '
        $0 == u            { inuser = 1; next }
        /^  [^ ]/          { inuser = 0 }
        inuser && /- *"?admins"?[[:space:]]*$/ { found = 1 }
        END { exit !found }
    ' "$2" 2>/dev/null
}
