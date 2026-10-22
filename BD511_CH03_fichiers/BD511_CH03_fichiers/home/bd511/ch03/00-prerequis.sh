#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.3 : vérifie l'environnement avant le TP
# Usage : bash ~/bd511/ch03/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Serveur et outils MongoDB"
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "Serveur MongoDB $v"; else nok "Serveur MongoDB 8.3 attendu (trouvé : ${v:-absent})"; fi
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=bd511-prerequis" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1
then ok "Connexion à mongodb://127.0.0.1:27017"; else nok "Connexion impossible à mongodb://127.0.0.1:27017"; fi
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
v=$(dpkg-query -W -f='${Version}' mongodb-compass 2>/dev/null)
if [[ -n $v ]]; then ok "MongoDB Compass $v"; else nok "Compass absent (chapitre 2, partie 4)"; fi

echo "== Python"
v=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null
then ok "Python $v (PyMongo 4.19 exige 3.11 ou plus récent)"; else nok "Python 3.11 ou plus récent requis (trouvé : ${v:-absent})"; fi
if dpkg-query -W -f='${Status}' python3-venv 2>/dev/null | grep -q 'ok installed'
then ok "Paquet python3-venv installé"; else nok "python3-venv absent : sudo apt-get install -y python3-venv"; fi
if curl -sSf -m 10 -o /dev/null https://pypi.org/simple/pymongo/
then ok "Accès au dépôt PyPI"; else nok "PyPI injoignable : vérifiez l'accès Internet (proxy ?)"; fi

echo
if (( ko == 0 )); then echo "Résultat : environnement prêt pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
