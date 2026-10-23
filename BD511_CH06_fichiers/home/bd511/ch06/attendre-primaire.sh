#!/usr/bin/env bash
# attendre-primaire.sh - BD511 ch.6 : attend qu'un primaire soit élu dans RS1 (90 s au plus) et l'affiche
# Usage : bash ~/bd511/ch06/attendre-primaire.sh [membre]   ex. : attendre-primaire.sh rs11:27011
# Avec un membre en argument, attend que ce membre précis soit le primaire.
cible=${1:-}
for i in $(seq 1 45); do
  p=$("$HOME/bd511/ch06/mongosh-rs1" --quiet --eval 'print(db.hello().primary || "")' 2>/dev/null)
  if [[ -n $p && ( -z $cible || $p == "$cible" ) ]]; then echo "$(date +%T)  primaire : $p"; exit 0; fi
  sleep 2
done
echo "$(date +%T)  pas de primaire${cible:+ $cible} après 90 s" >&2
exit 1
