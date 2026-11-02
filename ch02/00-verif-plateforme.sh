#!/usr/bin/env bash
# 00-verif-plateforme.sh - BD511 ch.2 : prérequis plate-forme pour MongoDB 8.3
# Plates-formes supportées : Ubuntu 22.04 (Jammy) et Ubuntu 24.04 (Noble)
# Usage : bash ~/bd511/ch02/00-verif-plateforme.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

# Règle appliquée par mongod 8.3.x au démarrage : noyaux 6.19.0 à 7.0.13 refusés.
noyau_compatible() {
  [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
  local v=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} ))
  (( v < 6019000 || v > 7000013 ))
}

echo "== Système"
. /etc/os-release
case "${ID:-}:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04)
    ok "$PRETTY_NAME" ;;
  *)
    nok "Ubuntu 22.04 ou 24.04 attendu (trouvé : ${PRETTY_NAME:-inconnu})" ;;
esac

case $(uname -m) in
  x86_64)
    if grep -qw avx /proc/cpuinfo; then ok "Processeur x86_64 avec AVX"
    else nok "Processeur x86_64 SANS AVX : mongod ne pourra pas démarrer (voir annexe A)"; fi ;;
  aarch64)
    ok "Processeur aarch64 (ARMv8.2-A minimum ; Compass n'existe pas pour Linux ARM64)" ;;
  *)
    nok "Architecture non supportée : $(uname -m)" ;;
esac

mem_mo=$(awk '/^MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo)
if (( mem_mo >= 3500 )); then ok "Mémoire : ${mem_mo} Mo"; else nok "Mémoire : ${mem_mo} Mo (4 Go recommandés)"; fi

libre_go=$(df --output=avail -BG /var/lib | tail -n 1 | tr -dc '0-9')
if (( libre_go >= 12 )); then ok "Espace libre sous /var/lib : ${libre_go} Go"
else nok "Espace libre sous /var/lib : ${libre_go} Go (12 Go recommandés)"; fi

echo "== Noyau"
courant=$(uname -r)
if noyau_compatible "$courant"; then ok "Noyau en cours d'exécution : $courant"
else nok "Noyau en cours d'exécution : $courant (incompatible avec MongoDB 8.3.13)"; fi

for image in /boot/vmlinuz-*; do
  [[ -e $image ]] || continue
  version=${image#/boot/vmlinuz-}
  noyau_compatible "$version" || nok "Noyau installé incompatible : $version"
done

# Pile HWE : sur 24.04, elle suit les noyaux des versions suivantes d'Ubuntu (6.19 et plus) ;
# sur 22.04, elle s'arrête à la série 6.8 et reste donc compatible.
if [[ ${VERSION_ID:-} == 24.04 ]] \
   && dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-*-hwe-24.04' 2>/dev/null | grep -q '^ii'; then
  nok "Pile noyau HWE 24.04 installée : elle installera des noyaux 6.19 ou plus récents"
fi

echo
if (( ko == 0 )); then
  echo "Résultat : plate-forme conforme, passez à la partie 1."
else
  echo "Résultat : ${ko} point(s) à corriger (voir la partie 0.4 pour le noyau)."
fi
exit $(( ko > 0 ))
