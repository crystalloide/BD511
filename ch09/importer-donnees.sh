#!/usr/bin/env bash
# importer-donnees.sh - BD511 ch.9 : (ré)importe le catalogue et les commandes dans la base bd511 de RS9
# Compte appli (mot de passe dans ~/BD511/rs9/secrets/appli.yaml), écritures confirmées par la majorité des membres.
# Les collections sont recréées (--drop), puis l'index de la « fiche client » est créé sur les commandes.
# Usage : bash ~/BD511/ch09/importer-donnees.sh
set -euo pipefail
CH09="$HOME/BD511/ch09"
cd "$CH09/donnees"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers différents de la référence (partie 2.1)." >&2; exit 1; }
debut=$SECONDS
for collection in articles commandes; do
  mongoimport --uri "mongodb://appli@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&appName=bd511-ch09-import" \
    --config "$HOME/BD511/rs9/secrets/appli.yaml" --db bd511 --collection "$collection" --drop --file "$collection.json" \
    --writeConcern '{ w: "majority" }' --numInsertionWorkers 2 --quiet
done
"$CH09/mongosh-rs9" --quiet --eval '
  db.commandes.createIndex({ client: 1, date: -1 });
  for (const c of ["articles", "commandes"])
    print(`bd511.${c} : ${db[c].countDocuments()} documents, index : ${db[c].getIndexes().map(i => i.name).join(", ")}`)'
echo "Import terminé en $((SECONDS - debut)) s"
