#!/usr/bin/env bash
# importer-ventes.sh - BD511 ch.7 : importe le jeu de données des ventes dans une collection de la base bd511,
# par le routeur mongos1, avec le compte applicatif « appli ». La collection doit être vide ou inexistante.
# Le mot de passe passe par un fichier de configuration temporaire (mode 600, supprimé à la fin).
# Usage : bash ~/bd511/ch07/importer-ventes.sh <collection>        ex. : importer-ventes.sh ventes
set -euo pipefail
coll=${1:?"Usage : importer-ventes.sh <collection>"}
DONNEES="$HOME/bd511/ch07/donnees"
URI="mongodb://appli@mongos1:27017/?authSource=admin&appName=bd511-import"
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "ventes.json différent de la référence (partie 2.1)." >&2; exit 1; }
if [[ $("$MONGOSH" --compte appli --quiet --eval "print(db.getCollection('$coll').countDocuments({}, { limit: 1 }))") != 0 ]]; then
  echo "bd511.$coll contient déjà des documents : import annulé." >&2; exit 1
fi

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
printf 'password: "%s"\n' "$(< "$HOME/bd511/cluster/secrets/appli.pwd")" > "$conf"

# Écriture confirmée par la majorité des membres porteurs de données de chaque shard, arrêt à la première erreur.
debut=$SECONDS
mongoimport --config "$conf" --uri "$URI" --db bd511 --collection "$coll" --file ventes.json \
  --writeConcern '{w: "majority"}' --stopOnError --quiet
n=$("$MONGOSH" --compte appli --quiet --eval "print(db.getCollection('$coll').countDocuments())")
echo "bd511.$coll : $n documents importés en $((SECONDS - debut)) s"
