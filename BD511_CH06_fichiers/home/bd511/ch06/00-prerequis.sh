#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.6 : vérifie la VM avant de déployer le replica set sous Docker
# Usage : bash ~/bd511/ch06/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Système (partagé par l'hôte et tous les conteneurs)"
. /etc/os-release
if [[ $VERSION_ID == 24.04 ]]; then ok "$PRETTY_NAME"; else nok "Ubuntu 24.04 attendu (trouvé : $PRETTY_NAME)"; fi
if grep -qw avx /proc/cpuinfo; then ok "Processeur avec AVX (exigé par MongoDB 5.0 et plus)"; else nok "AVX absent : activez-le dans l'hyperviseur"; fi
thp=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)
defrag=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/defrag)
if [[ $thp == always && $defrag == defer+madvise ]]; then ok "THP : enabled=$thp, defrag=$defrag (chapitre 2)"
else nok "THP : enabled=$thp, defrag=$defrag ; refaites la partie 2.2 du chapitre 2"; fi
ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
if [[ $ntp == yes ]]; then ok "Horloge synchronisée (NTP)"; else nok "Horloge non synchronisée : sudo timedatectl set-ntp true"; fi
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"; else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; fermez des applications"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 7 )); then ok "Espace libre sur / : ${libre} Go (7 Go requis)"; else nok "Espace libre sur / : ${libre} Go (7 Go requis) ; agrandissez le disque (annexe A)"; fi
route=$(ip -4 route show 192.168.100.0/24)
if [[ -z $route || $route == *"dev bd511 "* ]]; then ok "Plage réseau 192.168.100.0/24 libre pour Docker"
else nok "Plage 192.168.100.0/24 déjà utilisée : $route"; fi

echo "== Outils clients installés au chapitre 2"
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
for outil in openssl jq curl; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent : sudo apt-get install -y $outil"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
