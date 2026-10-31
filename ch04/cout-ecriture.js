// cout-ecriture.js - BD511 ch.4 : mesure le coût des index secondaires sur les insertions
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-tp4" ~/bd511/ch04/cout-ecriture.js
// Copie 200 000 activités dans deux collections de test : l'une avec le seul index _id_,
// l'autre avec les mêmes index secondaires que bd511.activites. Chaque mesure est répétée 3 fois
// et la meilleure est retenue (la moins perturbée) ; les collections de test sont supprimées à la fin.
const NOMBRE = 200000;
const ESSAIS = 3;
const indexSecondaires = db.activites.getIndexes().filter(ix => ix.name !== "_id_");

function chronometrer(nom, index) {
  const cible = db.getCollection(nom);
  cible.drop();
  db.createCollection(nom);
  for (const ix of index) cible.createIndex(ix.key, { name: ix.name });
  const debut = Date.now();
  db.activites.aggregate([
    { $limit: NOMBRE },
    { $merge: { into: nom, whenMatched: "fail", whenNotMatched: "insert" } },
  ]);
  const duree = Date.now() - debut;
  cible.drop();
  return duree;
}

const mesuresSans = [], mesuresAvec = [];
for (let i = 0; i < ESSAIS; i++) {
  mesuresSans.push(chronometrer("essai_sans_index", []));
  mesuresAvec.push(chronometrer("essai_avec_index", indexSecondaires));
}
const sans = Math.min(...mesuresSans);
const avec = Math.min(...mesuresAvec);
const noms = indexSecondaires.map(ix => ix.name).join(", ") || "aucun";
print(`Insertion de ${NOMBRE} activités, meilleur de ${ESSAIS} essais`);
print(`Index secondaires de bd511.activites : ${noms}`);
print("  index _id_ seul".padEnd(42) + `: ${String(sans).padStart(6)} ms`);
print(`  _id_ + ${indexSecondaires.length} index secondaire(s)`.padEnd(42) + `: ${String(avec).padStart(6)} ms`);
print("Surcoût dû aux index secondaires".padEnd(42) + `: x ${(avec / sans).toFixed(1)}`);
