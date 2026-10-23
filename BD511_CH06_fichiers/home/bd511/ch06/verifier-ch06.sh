#!/usr/bin/env bash
# verifier-ch06.sh - BD511 ch.6 : contrôle final du replica set RS1 déployé sous Docker
# Usage : bash ~/bd511/ch06/verifier-ch06.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
cd "$HOME/bd511/cluster"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Docker et système"
etats=$(sudo docker compose ps --format '{{.Name}}:{{.Health}}' | sort | tr '\n' ' ')
[[ $etats == "rs11:healthy rs12:healthy rs1arb:healthy " ]]; res $? "Conteneurs RS1 en bonne santé : $etats"
[[ $(sudo docker info --format '{{.LiveRestoreEnabled}}') == true ]]; res $? "Démon Docker : live-restore actif"
[[ $(sudo docker inspect rs11 --format '{{.HostConfig.LogConfig.Config}}') == *"max-size:50m"* ]]; res $? "Rotation des journaux Docker (max-size 50m)"
findmnt -n -t xfs -O noatime /srv/bd511 >/dev/null; res $? "Données sur volume XFS monté en noatime : /srv/bd511"
[[ $(stat -c '%a %u' secrets/keyfile) == "400 999" ]]; res $? "Fichier de clé : mode 400, propriétaire uid 999"

echo "== Replica set RS1"
etat=$("$HOME/bd511/ch06/mongosh-rs1" --quiet --eval '
  const s = rs.status(), c = rs.conf();
  print(s.members.map(m => `${m.name}=${m.stateStr}/${c.members.find(x => x.host === m.name).priority}`).join(" "))' 2>/dev/null)
[[ $etat == "rs11:27011=PRIMARY/2 rs12:27012=SECONDARY/1 rs1arb:27013=ARBITER/0" ]]; res $? "Membres et priorités : $etat"
mongosh --quiet "mongodb://rs11:27011/?directConnection=true&appName=bd511-verif" --eval 'db.adminCommand({ listDatabases: 1 })' 2>&1 | grep -q "requires authentication"
res $? "Accès anonyme refusé (contrôle d'accès actif)"
comptes=$("$HOME/bd511/ch06/mongosh-rs1" --quiet --eval 'print(db.getSiblingDB("admin").getUsers().users.map(u => u.user + ":" + u.roles.map(r => r.role + "@" + r.db).join(",")).sort().join(" "))' 2>/dev/null)
[[ $comptes == "admin:root@admin appli:readWrite@bd511" ]]; res $? "Comptes : $comptes"
n=$("$HOME/bd511/ch06/mongosh-rs1" --compte appli --quiet --eval '
  db.getMongo().setReadPref("secondary");
  print(["formations", "inscriptions", "stagiaires"].map(c => db.getCollection(c).countDocuments()).join("/"))' 2>/dev/null)
[[ $n == "24/1202/300" ]]; res $? "Données répliquées, lues sur le secondaire : $n"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
