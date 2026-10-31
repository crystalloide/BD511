#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.4 : vérifie l'environnement avant le TP
# Usage : bash ~/bd511/ch04/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }
URI="mongodb://127.0.0.1:27017/?appName=bd511-prerequis"

echo "== Serveur et outils MongoDB"
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "Serveur MongoDB $v"; else nok "Serveur MongoDB 8.3 attendu (trouvé : ${v:-absent})"; fi
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
if mongosh --quiet "$URI" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1
then ok "Connexion à mongodb://127.0.0.1:27017"; else nok "Connexion impossible à mongodb://127.0.0.1:27017"; fi
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
v=$(dpkg-query -W -f='${Version}' mongodb-compass 2>/dev/null)
if [[ -n $v ]]; then ok "MongoDB Compass $v"; else nok "Compass absent (chapitre 2, partie 4)"; fi

echo "== Outils et ressources"
v=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
if [[ -n $v ]]; then ok "Python $v (générateur du jeu de données)"; else nok "python3 absent : sudo apt-get install -y python3"; fi
v=$(jq --version 2>/dev/null)
if [[ -n $v ]]; then ok "$v (lecture du journal JSON de mongod)"; else nok "jq absent : sudo apt-get install -y jq"; fi
libre=$(df -BG --output=avail "$HOME" | tail -n 1 | tr -dc '0-9')
if (( libre >= 1 )); then ok "Espace libre dans $HOME : ${libre} Go (1 Go requis)"; else nok "Espace libre dans $HOME : ${libre} Go (1 Go requis)"; fi
libre=$(df -BG --output=avail /var/lib/mongodb | tail -n 1 | tr -dc '0-9')
if (( libre >= 1 )); then ok "Espace libre sur /var/lib/mongodb : ${libre} Go (1 Go requis)"; else nok "Espace libre sur /var/lib/mongodb : ${libre} Go (1 Go requis)"; fi
v=$(mongosh --quiet "$URI" --eval 'const p = db.getSiblingDB("bd511").getProfilingStatus(); print(p.was + " " + p.slowms)' 2>/dev/null)
if [[ $v == "0 100" ]]; then ok "Profiler désactivé, seuil des requêtes lentes slowms = 100 ms (valeurs par défaut)"
else nok "Profiler/slowms modifiés (was slowms = ${v:-?}) : redémarrez mongod (sudo systemctl restart mongod)"; fi

echo
if (( ko == 0 )); then echo "Résultat : environnement prêt pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
