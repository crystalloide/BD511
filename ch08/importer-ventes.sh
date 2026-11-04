#!/usr/bin/env bash
# importer-ventes.sh - BD511 ch.8 : (ré)importe le million de ventes dans bd511.ventes, avec le compte « charge »
# La collection est recréée à chaque import (--drop) : elle ne porte alors que l'index obligatoire sur _id.
# Le mot de passe passe par le fichier de configuration ~/BD511/ch08/secrets/charge.yaml (option --config).
# Usage : bash ~/BD511/ch08/importer-ventes.sh
set -euo pipefail
CH08="$HOME/BD511/ch08"
cd "$CH08/donnees"
sha256sum --quiet --check SHA256SUMS || { echo "ventes.json différent de la référence (partie 0.4)." >&2; exit 1; }
debut=$SECONDS
mongoimport --uri "mongodb://charge@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-import" \
  --config "$CH08/secrets/charge.yaml" --db bd511 --collection ventes --drop --file ventes.json \
  --numInsertionWorkers 2 --quiet
"$CH08/mongosh-bd511" --compte charge --quiet --eval '
  print(`bd511.ventes : ${db.ventes.countDocuments()} documents, index : ${db.ventes.getIndexes().map(i => i.name).join(", ")}`)'
echo "Import terminé en $((SECONDS - debut)) s"
