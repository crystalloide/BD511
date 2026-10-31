#!/usr/bin/env bash
# init-restau.sh - BD511 ch.9 : démarre l'instance isolée de test des restaurations (conteneur restau)
# et y crée, par l'exception localhost, les comptes admin et restauration : mêmes rôles et mêmes mots de passe
# que sur RS9, pour que les comptes contenus dans les sauvegardes restent utilisables après une restauration.
# Usage : bash ~/BD511/ch09/init-restau.sh      (demande le mot de passe sudo pour docker compose)
set -euo pipefail
cd "$HOME/BD511/rs9"
sudo docker compose --profile test up -d --wait restau
sudo docker compose exec -T restau mongosh --port 27099 --quiet --norc --file /dev/stdin <<JS
const admin = db.getSiblingDB("admin");
try {
  admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: ["root"] });
} catch (e) { print("restau est déjà initialisée : rien à faire."); quit(0); }
admin.auth("admin", "$(cat secrets/admin.pwd)");
admin.createRole({ role: "rejeuOplog", privileges: [{ resource: { anyResource: true }, actions: ["anyAction"] }], roles: [] });
admin.createUser({ user: "restauration", pwd: "$(cat secrets/restauration.pwd)", roles: ["restore", "rejeuOplog"] });
print("restau : comptes", admin.getUsers().users.map(u => u.user).sort().join(", "), "; bases :",
      admin.runCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name).sort().join(", "));
JS
