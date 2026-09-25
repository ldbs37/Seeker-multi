#!/bin/bash
#######################
# disable_arr_auth.sh — Ancien nom : la connexion unique des *arr est
# désormais appliquée par arr_setup.sh (mode « External », sûr seulement sur
# le réseau privé de l'utilisateur, ce que arr_setup.sh vérifie).
# Usage: ./disable_arr_auth.sh <username> [service]
#######################
[ $# -ge 1 ] || { echo "Usage: $0 <username> [service]"; exit 1; }
exec "$(cd "$(dirname "$0")" && pwd)/arr_setup.sh" "$1"
