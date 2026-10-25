#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.8 : vérifie la VM avant le TP de supervision
# (instance mongod du chapitre 2, outils clients, Docker du chapitre 6, mémoire, disque et ports libres)
# Usage : bash ~/BD511/ch08/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Instance mongod du chapitre 2"
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "mongod $v"; else nok "mongod 8.3 attendu (trouvé : ${v:-aucun})"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=bd511-ch08-prerequis" --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null | grep -qx 1
then ok "mongod répond sur 127.0.0.1:27017"; else nok "mongod ne répond pas sur 127.0.0.1:27017"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=bd511-ch08-prerequis" --eval 'db.adminCommand({ listDatabases: 1 }).ok' >/dev/null 2>&1
then ok "Contrôle d'accès désactivé (chapitre 2) : comptes du TP créés sans authentification"
else ok "Contrôle d'accès activé (chapitre 5) : un compte administrateur sera demandé en partie 0.2"; fi
libre=$(df -BM --output=avail /var/lib/mongodb | tail -n 1 | tr -dc '0-9')
if (( libre >= 1024 )); then ok "Espace libre pour les données (/var/lib/mongodb) : ${libre} Mo (1 024 Mo requis)"
else nok "Espace libre pour les données (/var/lib/mongodb) : ${libre} Mo (1 024 Mo requis)"; fi

echo "== Outils"
for outil in mongosh mongoimport mongostat mongotop jq python3 logrotate; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done
if sudo docker info >/dev/null 2>&1; then
  ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}'), Compose $(sudo docker compose version --short)"
else nok "Docker inactif ou absent (chapitre 6, partie 1)"; fi

echo "== Ressources de la VM"
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; arrêtez le cluster du chapitre 7 (annexe A)"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 3 )); then ok "Espace libre sur / : ${libre} Go (3 Go requis pour les images Docker)"
else nok "Espace libre sur / : ${libre} Go (3 Go requis pour les images Docker)"; fi
for port in 9216 9090 3000; do
  if ss -Hltn "sport = :$port" | grep -q .; then nok "Port $port déjà utilisé"; else ok "Port $port libre"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
