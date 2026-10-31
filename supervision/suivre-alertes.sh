#!/usr/bin/env bash
# suivre-alertes.sh - BD511 ch.8 : affiche les alertes de Prometheus toutes les 15 s, jusqu'à la situation attendue
#   declenchee <alerte> : jusqu'à ce que cette alerte soit déclenchée (état firing)
#   aucune              : jusqu'à ce qu'il n'y ait plus aucune alerte
# Abandon au bout de 5 minutes.
# Usage : bash ~/BD511/supervision/suivre-alertes.sh declenchee MongoDBBalayagesExcessifs
#         bash ~/BD511/supervision/suivre-alertes.sh aucune
set -euo pipefail
attendu=${1:?"Usage : $0 declenchee <alerte> | aucune"}
for i in $(seq 1 20); do
  alertes=$(curl -s http://127.0.0.1:9090/api/v1/alerts | jq -r '[.data.alerts[] | "\(.labels.alertname) (\(.state))"] | sort | join(", ")')
  echo "$(date +%T)  ${alertes:-aucune alerte}"
  case $attendu in
    declenchee) [[ $alertes == *"$2 (firing)"* ]] && exit 0 ;;
    aucune)     [[ -z $alertes ]] && exit 0 ;;
  esac
  sleep 15
done
echo "Situation attendue non atteinte au bout de 5 minutes" >&2
exit 1
