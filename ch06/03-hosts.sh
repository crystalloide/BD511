#!/usr/bin/env bash
# 03-hosts.sh - BD511 ch.6 : déclare les noms des membres du cluster dans /etc/hosts de la VM
# (les conteneurs se résolvent entre eux par le DNS de Docker ; la VM, elle, passe par /etc/hosts).
# Le bloc est délimité par deux marqueurs : le script peut être relancé sans créer de doublons.
# Usage : sudo bash ~/bd511/ch06/03-hosts.sh ~/bd511/cluster/architecture.tsv
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
ARCHI=${1:?"chemin de architecture.tsv attendu"}
DEBUT="# >>> BD511 cluster Docker (généré par 03-hosts.sh)"
FIN="# <<< BD511 cluster Docker"

cp /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d%H%M%S)"
sed -i "/^${DEBUT}\$/,/^${FIN}\$/d" /etc/hosts
{
  echo "$DEBUT"
  awk -F'\t' 'NR > 1 { printf "%s\t%s\n", $1, $7 }' "$ARCHI"
  echo "$FIN"
} >> /etc/hosts
sed -n "/^${DEBUT}\$/,/^${FIN}\$/p" /etc/hosts
