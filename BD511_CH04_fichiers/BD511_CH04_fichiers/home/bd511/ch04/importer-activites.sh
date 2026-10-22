#!/usr/bin/env bash
# importer-activites.sh - BD511 ch.4 : (re)crée la collection bd511.activites dans son état initial
#   1 000 000 documents, aucun index secondaire (seulement l'index _id_).
#   Si activites.json est absent ou altéré, le décompresse depuis activites.json.gz (archive du TP)
#   ou, à défaut, le régénère ; puis l'importe. Durée : environ 1 minute.
# Usage : bash ~/bd511/ch04/importer-activites.sh
set -euo pipefail
cd "$HOME/bd511/ch04/donnees"

if ! sha256sum --quiet --check SHA256SUMS >/dev/null 2>&1; then
  if [[ -f activites.json.gz ]]; then
    echo "== Décompression de activites.json.gz (jeu de données fourni avec le TP)"
    gunzip -c activites.json.gz > activites.json
  else
    echo "== Génération de activites.json"
    python3 ../generer_activites.py
  fi
  sha256sum --check SHA256SUMS
fi

echo "== Import dans bd511.activites (la collection est d'abord supprimée, index compris)"
mongoimport --uri "mongodb://127.0.0.1:27017/?appName=bd511-import" \
  --db bd511 --collection activites --drop \
  --writeConcern '{w: "majority"}' --numInsertionWorkers 2 \
  --file activites.json

echo "== Contrôle"
mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-import" --eval '
  const n = db.activites.countDocuments();
  const index = db.activites.getIndexes().map(i => i.name).join(", ");
  print(`bd511.activites : ${n} documents ; index : ${index}`);'
