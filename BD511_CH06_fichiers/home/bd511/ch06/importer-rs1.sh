#!/usr/bin/env bash
# importer-rs1.sh - BD511 ch.6 : importe le jeu de données du chapitre 3 dans le replica set RS1
# Compte applicatif « appli » ; le mot de passe passe par un fichier de configuration temporaire
# (mode 600, supprimé à la fin), jamais par la ligne de commande.
# Usage : bash ~/bd511/ch06/importer-rs1.sh
set -euo pipefail
DONNEES="$HOME/bd511/ch06/donnees"
URI="mongodb://appli@rs11:27011,rs12:27012/?replicaSet=RS1&authSource=admin&appName=bd511-import"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers de données différents de la référence (partie 3.5)." >&2; exit 1; }

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
printf 'password: "%s"\n' "$(< "$HOME/bd511/cluster/secrets/appli.pwd")" > "$conf"

# Écriture confirmée par la majorité des membres porteurs de données, arrêt à la première erreur.
commun=(--config "$conf" --uri "$URI" --db bd511 --drop --writeConcern '{w: "majority"}' --stopOnError --quiet)
mongoimport "${commun[@]}" --collection formations --jsonArray --file formations.json
mongoimport "${commun[@]}" --collection inscriptions --file inscriptions.json
tail -n +2 stagiaires.csv | mongoimport "${commun[@]}" --collection stagiaires --type csv \
  --columnsHaveTypes --fieldFile stagiaires.fields --ignoreBlanks --parseGrace stop

"$HOME/bd511/ch06/mongosh-rs1" --compte appli --quiet --eval '
  for (const nom of ["formations", "inscriptions", "stagiaires"]) {
    print(nom.padEnd(13) + ": " + db.getCollection(nom).countDocuments() + " documents");
  }'
