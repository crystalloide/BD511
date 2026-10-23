#!/usr/bin/env bash
# BD511 – TP chapitre 5 – Annexe B : remise de l'instance dans l'état « avant TP »
#  - configuration de référence SANS authentification ;
#  - suppression des comptes et rôles créés par le TP, puis de la base boutique.
# Les autres comptes éventuels de l'instance ne sont pas touchés.
# Usage : bash ~/tp05-securite/scripts/zz_reinitialiser_tp05.sh   (sudo sera demandé)
set -euo pipefail
DIR_TP="$(cd "$(dirname "$0")/.." && pwd)"

sudo install -o root -g root -m 644 "$DIR_TP/conf/mongod.conf.0-reference" /etc/mongod.conf
sudo systemctl restart mongod
for _ in $(seq 1 60); do
  mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1 && break
  sleep 1
done

mongosh --quiet "mongodb://127.0.0.1:27017/admin" --eval '
  const admin = db.getSiblingDB("admin");
  for (const u of ["admin_secu", "dba", "supervision"]) {
    if (admin.getUser(u) !== null) { admin.dropUser(u); print("compte supprimé : " + u + "@admin"); }
  }
  if (admin.getRole("supervisionLegere") !== null) { admin.dropRole("supervisionLegere"); print("rôle supprimé : supervisionLegere@admin"); }
  const boutique = db.getSiblingDB("boutique");
  print("comptes supprimés dans boutique : " + boutique.runCommand({ dropAllUsersFromDatabase: 1 }).n);
  print("rôles supprimés dans boutique   : " + boutique.runCommand({ dropAllRolesFromDatabase: 1 }).n);
  boutique.dropDatabase();
  print("base boutique supprimée");
  const restants = admin.runCommand({ usersInfo: { forAllDBs: true } }).users.length;
  print(restants === 0
    ? "Aucun compte restant : l\u2019exception localhost sera disponible au TP1."
    : restants + " compte(s) d\u2019autres TP subsiste(nt) : l\u2019exception localhost ne sera PAS disponible.");
'
echo "Réinitialisation terminée : reprendre le TP à l'étape 0.5."
