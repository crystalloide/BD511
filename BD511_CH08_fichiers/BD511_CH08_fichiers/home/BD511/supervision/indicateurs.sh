#!/usr/bin/env bash
# indicateurs.sh - BD511 ch.8 : indicateurs clés de l'instance mongod, lus dans Prometheus
# Mêmes calculs que la première ligne du tableau de bord Grafana, sur la dernière minute, puis les alertes en cours.
# Usage : bash ~/BD511/supervision/indicateurs.sh
set -euo pipefail
PROM=http://127.0.0.1:9090
valeur() {   # résultat d'une requête PromQL, arrondi à $2 décimales (0 par défaut) ; « - » si aucune donnée
  curl -s --data-urlencode "query=$1" "$PROM/api/v1/query" \
    | jq -r --argjson d "${2:-0}" '.data.result[0].value[1] // "NaN"
        | if . == "NaN" then "-" else (tonumber * pow(10; $d) | round / pow(10; $d) | tostring) end'
}
OPS='legacy_op_type=~"query|insert|update|delete|getmore"'
echo "$(date +%T)  instance mongod-bd511, moyennes sur la dernière minute"
echo "  MongoDB joignable (mongodb_up)  : $(valeur 'mongodb_up{job="mongodb"}')"
echo "  Opérations/s                    : $(valeur "sum(rate(mongodb_ss_opcounters{$OPS}[1m]))" 1)"
echo "  Documents examinés par renvoyé  : $(valeur 'sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[1m]))
  / clamp_min(sum(rate(mongodb_ss_metrics_document{doc_op_type="returned"}[1m])), 1)')"
echo "  Latence des lectures (ms)       : $(valeur 'sum(rate(mongodb_ss_opLatencies_latency{op_type="reads"}[1m]))
  / clamp_min(sum(rate(mongodb_ss_opLatencies_ops{op_type="reads"}[1m])), 1) / 1000' 1)"
echo "  CPU de la VM (%)                : $(valeur '100 * (1 - sum(rate(mongodb_sys_cpu_idle_ms[1m]))
  / (1000 * max(mongodb_sys_cpu_num_logical_cores)))')"
alertes=$(curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | "\(.labels.alertname) (\(.state))"] | sort | join(", ")')
echo "  Alertes                         : ${alertes:-aucune}"
