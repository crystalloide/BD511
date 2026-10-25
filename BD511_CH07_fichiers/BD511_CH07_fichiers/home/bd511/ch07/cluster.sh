#!/usr/bin/env bash
# cluster.sh - BD511 ch.7 : démarre ou arrête le cluster shardé dans l'ordre recommandé, ou affiche son état
#   demarrer : serveurs de configuration, puis shards, puis routeur ; réactive le balancer
#   arreter  : désactive le balancer, puis arrête le routeur, les shards et enfin les serveurs de configuration
# Usage : bash ~/bd511/ch07/cluster.sh demarrer|arreter|etat
set -euo pipefail
CONFIG=(config1 config2 config3)
SHARDS=(rs11 rs12 rs1arb rs21 rs22 rs2arb)
ROUTEURS=(mongos1)
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"
cd "$HOME/bd511/cluster"

case ${1:-} in
  demarrer)
    sudo docker compose up -d --wait "${CONFIG[@]}"
    sudo docker compose up -d --wait "${SHARDS[@]}"
    sudo docker compose up -d --wait "${ROUTEURS[@]}"
    "$MONGOSH" --quiet --eval 'sh.startBalancer(); print("balancer actif :", sh.getBalancerState())' ;;
  arreter)
    "$MONGOSH" --quiet --eval 'sh.stopBalancer(); print("balancer actif :", sh.getBalancerState())'
    sudo docker compose stop "${ROUTEURS[@]}"
    sudo docker compose stop "${SHARDS[@]}"
    sudo docker compose stop "${CONFIG[@]}" ;;
  etat)
    sudo docker compose ps -a --format 'table {{.Name}}\t{{.Status}}' "${CONFIG[@]}" "${SHARDS[@]}" "${ROUTEURS[@]}" ;;
  *)
    echo "Usage : $0 demarrer|arreter|etat" >&2; exit 1 ;;
esac
