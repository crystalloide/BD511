#!/usr/bin/env bash
# comptes.sh - BD511 ch.8 : crée ou met à jour les trois comptes du TP sur l'instance mongod du chapitre 2
#   diag      : exploitation (diagnostic, opérations en cours, profiler, index)
#   charge    : application simulée (lecture et écriture dans la base bd511)
#   exporteur : collecte des métriques pour Prometheus (clusterMonitor et lecture de la base local)
# Les mots de passe sont générés dans ~/BD511/ch08/secrets (mode 600) et ne passent jamais en ligne de commande.
# Le script s'adapte au contrôle d'accès de l'instance : désactivé (configuration du chapitre 2) ou activé
# (chapitre 5) ; dans ce cas, il demande un compte administrateur existant (rôle root ou userAdminAnyDatabase).
# Usage : bash ~/BD511/ch08/comptes.sh
set -euo pipefail
SECRETS="$HOME/BD511/ch08/secrets"
URI="mongodb://127.0.0.1:27017/admin?appName=bd511-ch08-comptes"

mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
for compte in diag charge exporteur; do
  if [[ ! -s $SECRETS/$compte.pwd ]]; then
    ( umask 077; openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS/$compte.pwd" )
  fi
done
# Fichiers de configuration des Database Tools (option --config de mongostat, mongotop, mongoimport)
for compte in diag charge; do
  ( umask 077; printf 'password: "%s"\n' "$(< "$SECRETS/$compte.pwd")" > "$SECRETS/$compte.yaml" )
done

if ! mongosh --quiet "$URI" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
  echo "mongod ne répond pas sur 127.0.0.1:27017 : sudo systemctl start mongod" >&2; exit 1
fi
if mongosh --quiet "$URI" --eval 'db.adminCommand({ listDatabases: 1 }).ok' >/dev/null 2>&1; then
  echo "Contrôle d'accès : désactivé (configuration du chapitre 2)"
  connexion=""
else
  echo "Contrôle d'accès : activé (chapitre 5)"
  read -r -p "Compte administrateur existant [admin] : " adm
  read -r -s -p "Mot de passe de ${adm:=admin} : " mdp; echo
  # Nom et mot de passe convertis en chaînes JSON, transmis à mongosh par l'entrée standard
  connexion="db.getSiblingDB('admin').auth($(printf '%s' "$adm" | jq -Rs .), $(printf '%s' "$mdp" | jq -Rs .));"
fi

mongosh --quiet "$URI" --file /dev/stdin <<FIN
$connexion
const admin = db.getSiblingDB("admin");
const comptes = {
  diag:      { roles: ["clusterMonitor", "hostManager", "dbAdminAnyDatabase", "readAnyDatabase"], mdp: "$(< "$SECRETS/diag.pwd")" },
  charge:    { roles: [{ role: "readWrite", db: "bd511" }], mdp: "$(< "$SECRETS/charge.pwd")" },
  exporteur: { roles: ["clusterMonitor", { role: "read", db: "local" }], mdp: "$(< "$SECRETS/exporteur.pwd")" },
};
for (const [nom, c] of Object.entries(comptes)) {
  if (admin.getUser(nom)) admin.updateUser(nom, { pwd: c.mdp, roles: c.roles });
  else admin.createUser({ user: nom, pwd: c.mdp, roles: c.roles });
}
for (const u of admin.getUsers({ filter: { user: { \$in: Object.keys(comptes) } } }).users.sort((a, b) => a.user.localeCompare(b.user)))
  print(u.user.padEnd(10), u.roles.map(r => r.role + "@" + r.db).sort().join(", "));
FIN
