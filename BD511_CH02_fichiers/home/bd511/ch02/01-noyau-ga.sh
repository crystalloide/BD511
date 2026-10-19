#!/usr/bin/env bash
# 01-noyau-ga.sh - BD511 ch.2 : remplace la pile noyau HWE par le noyau GA 6.8 d'Ubuntu 24.04
# Usage : sudo bash ~/bd511/ch02/01-noyau-ga.sh   puis   sudo reboot
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
. /etc/os-release
[[ ${VERSION_CODENAME:-} == noble ]] || { echo "Script prévu pour Ubuntu 24.04 (noble)." >&2; exit 1; }

# Mode non interactif : autorise la suppression du noyau en cours d'exécution
# (le noyau GA est installé avant, et la VM redémarre juste après).
export DEBIAN_FRONTEND=noninteractive

echo "1/4 Installation du noyau GA (paquet linux-generic)..."
apt-get update -qq
apt-get install -y linux-generic

noyau_ga=$(find /boot -maxdepth 1 -name 'vmlinuz-6.8.0-*-generic' -printf '%f\n' | sort -V | tail -n 1)
[[ -n $noyau_ga ]] || { echo "Noyau GA 6.8 introuvable dans /boot : arrêt sans rien supprimer." >&2; exit 1; }
echo "    Noyau GA installé : ${noyau_ga#vmlinuz-}"

echo "2/4 Recherche des paquets de la pile HWE..."
mapfile -t paquets < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*' 2>/dev/null |
    awk '$1 ~ /^ii/ {print $2}' |
    grep -E -- '-hwe-24\.04$|^linux-hwe-|-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(-[a-z0-9]+)?$' |
    grep -v -E -- '-6\.8\.0-[0-9]+(-[a-z0-9]+)?$' || true
)

if (( ${#paquets[@]} == 0 )); then
  echo "    Aucun paquet HWE installé."
else
  printf '    %s\n' "${paquets[@]}"
  echo "3/4 Suppression de la pile HWE..."
  apt-get purge -y "${paquets[@]}"
fi

echo "4/4 Mise à jour de la configuration GRUB..."
update-grub

echo
echo "Terminé. Redémarrez la VM maintenant : sudo reboot"
