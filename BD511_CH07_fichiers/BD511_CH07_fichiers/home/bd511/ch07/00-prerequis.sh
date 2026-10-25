#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.7 : vérifie que la VM et le replica set RS1 du chapitre 6 sont prêts pour le sharding
# Usage : bash ~/bd511/ch07/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }
CLUSTER="$HOME/bd511/cluster"

echo "== Système"
total=$(awk '/^MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 2560 )); then ok "Mémoire disponible : ${dispo} Mo sur ${total} Mo (2 560 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo sur ${total} Mo (2 560 Mo requis) ; passez la VM à 6 Go de RAM (partie 0.1)"; fi
if mountpoint -q /srv/bd511; then
  libre=$(df -BM --output=avail /srv/bd511 | tail -n 1 | tr -dc '0-9')
  if (( libre >= 2048 )); then ok "Volume /srv/bd511 monté : ${libre} Mo libres (2 048 Mo requis)"
  else nok "Volume /srv/bd511 : ${libre} Mo libres (2 048 Mo requis)"; fi
else nok "Volume /srv/bd511 non monté (chapitre 6, partie 2.2) : sudo mount /srv/bd511"; fi
for outil in mongosh mongoimport python3 jq; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done

echo "== Cluster Docker du chapitre 6"
if sudo docker info >/dev/null 2>&1; then ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}') actif"; else nok "Docker inactif : sudo systemctl start docker"; fi
manquants=""
for f in docker-compose.yml conf/mongod.conf secrets/keyfile secrets/admin.pwd secrets/appli.pwd; do
  sudo test -s "$CLUSTER/$f" || manquants+=" $f"
done
if [[ -z $manquants ]]; then ok "Fichiers du cluster présents dans ~/bd511/cluster"; else nok "Fichiers absents de ~/bd511/cluster :$manquants"; fi
noms=$(getent hosts config1 rs21 mongos1 | wc -l)
if (( noms == 3 )); then ok "Noms des membres déclarés dans /etc/hosts"; else nok "Noms absents de /etc/hosts : relancez 03-hosts.sh (chapitre 6, partie 2.3)"; fi
etat=$("$HOME/bd511/ch06/mongosh-rs1" --quiet --eval 'print(rs.status().members.map(m => m.stateStr).sort().join(" "))' 2>/dev/null)
if [[ $etat == "ARBITER PRIMARY SECONDARY" ]]; then ok "Replica set RS1 : un primaire, un secondaire, un arbitre"
else nok "Replica set RS1 indisponible ou dégradé (${etat:-aucune réponse}) : cd ~/bd511/cluster && sudo docker compose up -d --wait"; fi
if [[ -n $(sudo docker ps -aq --filter name='^(config[123]|rs2[12]|rs2arb|mongos1)$') ]]; then
  nok "Des conteneurs du chapitre 7 existent déjà : voir l'annexe C pour repartir de zéro"
else ok "Aucun conteneur du chapitre 7 créé"; fi

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
