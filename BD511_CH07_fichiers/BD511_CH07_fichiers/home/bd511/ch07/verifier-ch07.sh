#!/usr/bin/env bash
# verifier-ch07.sh - BD511 ch.7 : contrôle final du cluster shardé et des collections du TP
# Usage : bash ~/bd511/ch07/verifier-ch07.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
cd "$HOME/bd511/cluster"
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Conteneurs"
attendu="config1 config2 config3 mongos1 rs11 rs12 rs1arb rs21 rs22 rs2arb"
sains=$(sudo docker compose ps --format '{{.Name}} {{.Health}}' | awk '$2 == "healthy" {print $1}' | sort | tr '\n' ' ')
[[ $sains == "$attendu " ]]; res $? "10 conteneurs en bonne santé : $sains"

echo "== Cluster"
cfg=$("$MONGOSH" --cible RSCFG --quiet --eval '
  const s = rs.status(); print(s.set, db.hello().configsvr === 2 ? "configsvr" : "?", s.members.map(m => m.stateStr).sort().join(","))' 2>/dev/null)
[[ $cfg == "RSCFG configsvr PRIMARY,SECONDARY,SECONDARY" ]]; res $? "Serveurs de configuration : $cfg"
shards=$("$MONGOSH" --quiet --eval 'print(db.adminCommand({ listShards: 1 }).shards.map(s => s._id + "=" + s.host.split("/")[0]).join(" "))' 2>/dev/null)
[[ $shards == "RS1=RS1 RS2=RS2" ]]; res $? "Shards (nom=replica set) : $shards"
wc=$("$MONGOSH" --quiet --eval 'const r = db.adminCommand({ getDefaultRWConcern: 1 }); print(r.defaultWriteConcern.w, r.defaultWriteConcernSource)' 2>/dev/null)
[[ $wc == "majority global" ]]; res $? "Write concern par défaut du cluster : $wc"
comptes=$("$MONGOSH" --quiet --eval 'print(db.getSiblingDB("admin").getUsers().users.map(u => u.user + ":" + u.roles.map(r => r.role + "@" + r.db).join(",")).sort().join(" "))' 2>/dev/null)
[[ $comptes == "admin:root@admin appli:readWrite@bd511" ]]; res $? "Comptes du cluster : $comptes"
mongosh --quiet "mongodb://mongos1:27017/?appName=bd511-verif" --eval 'db.adminCommand({ listDatabases: 1 })' 2>&1 | grep -q "requires authentication"
res $? "Accès anonyme au routeur refusé"
[[ $("$MONGOSH" --quiet --eval 'print(sh.getBalancerState())' 2>/dev/null) == true ]]; res $? "Balancer actif"

echo "== Collections shardées de bd511"
while read -r coll cle; do
  r=$("$MONGOSH" --quiet --eval "
    const c = db.getSiblingDB('config').collections.findOne({ _id: 'bd511.$coll' });
    const shards = db.getSiblingDB('admin').aggregate([{ \$shardedDataDistribution: {} }, { \$match: { ns: 'bd511.$coll' } }])
      .toArray()[0].shards.filter(s => s.numOwnedDocuments > 0).length;
    print(EJSON.stringify(c.key), db.getCollection('$coll').countDocuments(), shards)" 2>/dev/null)
  [[ $r == "$cle 210000 2" ]]; res $? "$coll : clé, documents, shards occupés = $r"
done <<'LISTE'
ventes {"client":1}
ventes_date {"date":1}
ventes_hash {"client":"hashed"}
ventes_zone {"region":1,"client":1}
LISTE
zones=$("$MONGOSH" --quiet --eval '
  const e = db.ventes_zone.find({ region: "AM" }).explain().queryPlanner.winningPlan;
  print(db.getSiblingDB("config").shards.find().sort({ _id: 1 }).toArray().map(s => s._id + ":" + s.tags).join(" "), "AM->" + e.shards.map(s => s.shardName))' 2>/dev/null)
[[ $zones == "RS1:EUROPE RS2:AMERIQUES AM->RS2" ]]; res $? "Zones : $zones"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
