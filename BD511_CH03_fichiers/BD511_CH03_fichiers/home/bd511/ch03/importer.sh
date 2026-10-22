#!/usr/bin/env bash
# importer.sh - BD511 ch.3 : (ré)importe le jeu de données du TP dans la base bd511
# Usage : bash ~/bd511/ch03/importer.sh
set -euo pipefail

DONNEES="$HOME/bd511/ch03/donnees"
URI="mongodb://127.0.0.1:27017/?appName=bd511-import"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers de données différents de la référence : relancez la partie 1.1." >&2; exit 1; }

# Options communes : écriture confirmée par la majorité, arrêt à la première erreur, collection vidée avant import.
commun=(--uri "$URI" --db bd511 --drop --writeConcern '{w: "majority"}' --stopOnError --quiet)

mongoimport "${commun[@]}" --collection formations --jsonArray --file formations.json
mongoimport "${commun[@]}" --collection inscriptions --file inscriptions.json
mongoimport "${commun[@]}" --collection stagiaires_brut --type csv --headerline --file stagiaires.csv
tail -n +2 stagiaires.csv | mongoimport "${commun[@]}" --collection stagiaires --type csv \
  --columnsHaveTypes --fieldFile stagiaires.fields --ignoreBlanks --parseGrace stop

mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-import" --eval '
  for (const nom of ["formations", "inscriptions", "stagiaires", "stagiaires_brut"]) {
    print(nom.padEnd(16) + ": " + db.getCollection(nom).countDocuments() + " documents");
  }'
