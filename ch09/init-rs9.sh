#!/usr/bin/env bash
# init-rs9.sh - BD511 ch.9 : initialise le replica set RS9 et crée ses comptes
# Exécuté dans le conteneur rs91 grâce à l'exception localhost (aucun compte n'existe encore).
# Les mots de passe sont lus dans ~/BD511/rs9/secrets et transmis à mongosh par l'entrée standard.
#   admin        : root                         administration
#   appli        : readWrite sur bd511          application de la boutique
#   sauvegarde   : backup                       mongodump (données, comptes et oplog)
#   restauration : restore + rejeuOplog         mongorestore, y compris le rejeu de l'oplog (--oplogReplay)
# Usage : bash ~/BD511/ch09/init-rs9.sh      (demande le mot de passe sudo pour docker compose)
set -euo pipefail
cd "$HOME/BD511/rs9"
mdp() { cat "secrets/$1.pwd"; }

sudo docker compose exec -T rs91 mongosh --port 27091 --quiet --norc --file /dev/stdin <<JS
if (db.hello().setName) { print("RS9 est déjà initialisé : rien à faire."); quit(1); }
const r = rs.initiate({ _id: "RS9", members: [
  { _id: 0, host: "rs91:27091", priority: 2 },     // primaire préféré
  { _id: 1, host: "rs92:27092", priority: 1 },
  { _id: 2, host: "rs93:27093", priority: 1 } ] });
print("rs.initiate :", r.ok === 1 ? "ok" : EJSON.stringify(r));
for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
print("rs91 primaire :", db.hello().isWritablePrimary);

const admin = db.getSiblingDB("admin"), wc = { w: "majority", wtimeout: 30000 };
admin.createUser({ user: "admin", pwd: "$(mdp admin)", roles: ["root"] }, wc);
admin.auth("admin", "$(mdp admin)");
// Rejouer l'oplog (mongorestore --oplogReplay) exige l'action anyAction sur anyResource :
// rôle réservé au compte de restauration, comme le recommande la documentation de mongorestore.
admin.createRole({ role: "rejeuOplog", privileges: [{ resource: { anyResource: true }, actions: ["anyAction"] }], roles: [] }, wc);
admin.createUser({ user: "appli", pwd: "$(mdp appli)", roles: [{ role: "readWrite", db: "bd511" }] }, wc);
admin.createUser({ user: "sauvegarde", pwd: "$(mdp sauvegarde)", roles: ["backup"] }, wc);
admin.createUser({ user: "restauration", pwd: "$(mdp restauration)", roles: ["restore", "rejeuOplog"] }, wc);
for (const u of admin.getUsers().users.sort((a, b) => a.user.localeCompare(b.user)))
  print(u.user.padEnd(13), u.roles.map(x => x.role + "@" + x.db).sort().join(", "));
JS
