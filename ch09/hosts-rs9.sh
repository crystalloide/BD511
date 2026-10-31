#!/usr/bin/env bash
# hosts-rs9.sh - BD511 ch.9 : déclare les noms des membres de RS9 et de l'instance de test dans /etc/hosts
# (les conteneurs se résolvent entre eux par le DNS de Docker ; la VM, elle, passe par /etc/hosts).
# Le bloc est délimité par deux marqueurs : le script peut être relancé sans créer de doublons.
# Usage : sudo bash ~/BD511/ch09/hosts-rs9.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
DEBUT="# >>> BD511 replica set RS9 (généré par hosts-rs9.sh)"
FIN="# <<< BD511 replica set RS9"

cp /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d%H%M%S)"
sed -i "/^${DEBUT}\$/,/^${FIN}\$/d" /etc/hosts
cat >> /etc/hosts <<BLOC
$DEBUT
192.168.109.11	rs91
192.168.109.12	rs92
192.168.109.13	rs93
192.168.109.20	restau
$FIN
BLOC
sed -n "/^${DEBUT}\$/,/^${FIN}\$/p" /etc/hosts
