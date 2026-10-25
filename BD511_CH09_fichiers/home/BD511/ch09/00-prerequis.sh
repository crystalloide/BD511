#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.9 : vérifie la VM avant le TP de sauvegarde et de restauration
# (Docker et image mongo:8.3.13 du chapitre 6, Database Tools, mémoire, disque, réseau et noms libres)
# Usage : bash ~/BD511/ch09/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Docker (chapitre 6)"
if sudo docker info >/dev/null 2>&1; then
  ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}'), Compose $(sudo docker compose version --short)"
else nok "Docker inactif ou absent : sudo systemctl start docker"; fi
if sudo docker image inspect mongo:8.3.13 >/dev/null 2>&1; then ok "Image mongo:8.3.13 présente"
else nok "Image mongo:8.3.13 absente : sudo docker pull mongo:8.3.13"; fi
actifs=$(sudo docker ps --format '{{.Names}}' | grep -cE '^(rs1[12]|rs1arb|rs2[12]|rs2arb|config[123]|mongos[12]|grafana|prometheus|mongodb-exporter)$')
if (( actifs == 0 )); then ok "Cluster du chapitre 7 et supervision du chapitre 8 arrêtés"
else nok "${actifs} conteneur(s) des chapitres 7 et 8 encore actif(s) : partie 0.1"; fi

echo "== Outils"
for outil in mongosh mongodump mongorestore bsondump mongoimport jq python3 openssl; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done
v=$(mongodump --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == 100.* ]]; then ok "Database Tools $v"; else nok "Database Tools 100.x attendues (trouvé : ${v:-aucune})"; fi

echo "== Ressources de la VM"
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; voir l'annexe A"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 5 )); then ok "Espace libre sur / : ${libre} Go (5 Go requis : volume de 3 Go et sauvegardes)"
else nok "Espace libre sur / : ${libre} Go (5 Go requis : volume de 3 Go et sauvegardes)"; fi

echo "== Réseau et noms"
if ip -4 route | grep -q '^192\.168\.109\.' && ! sudo docker network inspect bd511-rs9 >/dev/null 2>&1; then
  nok "Le réseau 192.168.109.0/24 est déjà utilisé sur la VM"
else ok "Réseau 192.168.109.0/24 disponible pour RS9"; fi
for nom in rs91 rs92 rs93 restau; do
  adresse=$(getent hosts "$nom" | awk '{print $1}')
  if [[ -z $adresse || $adresse == 192.168.109.* ]]; then ok "Nom $nom libre ou déjà réservé à RS9"
  else nok "Le nom $nom désigne déjà $adresse"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
