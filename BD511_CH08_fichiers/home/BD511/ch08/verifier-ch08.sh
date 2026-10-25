#!/usr/bin/env bash
# verifier-ch08.sh - BD511 ch.8 : contrôle final de l'instance mongod et de la chaîne de supervision
# Usage : bash ~/BD511/ch08/verifier-ch08.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
MONGOSH="$HOME/BD511/ch08/mongosh-bd511"
SUP="$HOME/BD511/supervision"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Instance mongod du chapitre 2"
systemctl is-active --quiet mongod; res $? "Service mongod actif"
reglages=$("$MONGOSH" --quiet --eval '
  const p = db.adminCommand({ getCmdLineOpts: 1 }).parsed, s = db.getProfilingStatus();
  print(p.systemLog.logRotate, p.operationProfiling?.mode, s.was, s.slowms)' 2>/dev/null)
[[ $reglages == "reopen off 0 100" ]]; res $? "Réglages (logRotate, profiler, niveau, seuil) : $reglages"
grep -q "kill --signal=SIGUSR1" /etc/logrotate.d/mongod 2>/dev/null; res $? "Rotation du journal par logrotate : /etc/logrotate.d/mongod"
# chaque compte se connecte avec son mot de passe et affiche ses propres rôles
comptes=$(for c in charge diag exporteur; do
  "$MONGOSH" --compte "$c" --quiet --eval '
    const a = db.runCommand({ connectionStatus: 1 }).authInfo;
    print(a.authenticatedUsers[0].user + ":" + a.authenticatedUserRoles.map(r => r.role).sort().join("+"))' 2>/dev/null
done | paste -sd ' ')
[[ $comptes == "charge:readWrite diag:clusterMonitor+dbAdminAnyDatabase+hostManager+readAnyDatabase exporteur:clusterMonitor+read" ]]
res $? "Comptes du TP : $comptes"
index=$("$MONGOSH" --quiet --eval '
  const i = db.ventes.getIndexes().find(x => x.name === "client_1_date_-1");
  print(db.ventes.estimatedDocumentCount() >= 1000000, i ? (i.hidden ? "masqué" : "visible") : "absent")' 2>/dev/null)
[[ $index == "true visible" ]]; res $? "bd511.ventes : au moins 1 000 000 ventes, index client_1_date_-1 $index"

echo "== Chaîne de supervision"
etats=$(cd "$SUP" && sudo docker compose ps --format '{{.Name}}:{{.State}}:{{.Health}}' | sort | tr '\n' ' ')
[[ $etats == "grafana:running:healthy mongodb-exporter:running: prometheus:running:healthy " ]]; res $? "Conteneurs : $etats"
up=$(curl -s http://127.0.0.1:9216/metrics | awk '/^mongodb_up/ {print $2 + 0}')
[[ $up == 1 ]]; res $? "Exporteur : mongodb_up = ${up:-?}"
cibles=$(curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '[.data.activeTargets[] | .labels.job + ":" + .health] | sort | join(" ")')
[[ $cibles == "mongodb:up prometheus:up" ]]; res $? "Prometheus, cibles : $cibles"
regles=$(curl -s http://127.0.0.1:9090/api/v1/rules | jq '[.data.groups[].rules[]] | length')
actives=$(curl -s http://127.0.0.1:9090/api/v1/alerts | jq '[.data.alerts[] | select(.state == "firing")] | length')
[[ $regles == 5 && $actives == 0 ]]; res $? "Prometheus : $regles règles d'alerte chargées, $actives alerte(s) déclenchée(s)"
grafana=$(curl -s -K - "http://127.0.0.1:3000/api/search?query=BD511" <<< "user = \"admin:$(< "$SUP/secrets/grafana_admin.pwd")\"" \
  | jq -r '.[] | select(.type == "dash-db") | .folderTitle + " / " + .title')
[[ $grafana == "BD511 / BD511 – Charge MongoDB" ]]; res $? "Grafana, tableau de bord : $grafana"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
