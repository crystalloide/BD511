#!/usr/bin/env bash
# verifier-ch04.sh - BD511 ch.4 : contrôle de l'état final de bd511.activites (index et plans)
# Usage : bash ~/bd511/ch04/verifier-ch04.sh
set -u
mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-verif" --eval '
let ok = 0, ko = 0;
function res(cond, libelle, detail) {
  print(`  [${cond ? "OK" : "KO"}] ${libelle}${detail === undefined ? "" : " : " + detail}`);
  cond ? ok++ : ko++;
}
function etapes(exp) {
  const liste = [];
  for (let e = exp.queryPlanner.winningPlan; e; e = e.inputStage) liste.unshift(e);
  return liste;
}
const index = Object.fromEntries(db.activites.getIndexes().map(ix => [ix.name, ix]));
const cle = nom => index[nom] ? EJSON.stringify(index[nom].key) : "absent";

print("== Collection bd511.activites");
res(db.activites.countDocuments() === 1000000, "1 000 000 activités", db.activites.countDocuments());
res(cle("formation_type_date_score") === EJSON.stringify({ formation_id: 1, type: 1, date: -1, score: 1 }),
    "Index ESR formation_type_date_score", cle("formation_type_date_score"));
res(cle("stagiaire_date") === EJSON.stringify({ stagiaire_id: 1, date: -1 }), "Index stagiaire_date", cle("stagiaire_date"));
res(!index.formation && !index.formation_type_score_date, "Index redondants supprimés (formation, formation_type_score_date)");
res(Object.values(index).every(ix => !ix.hidden), "Aucun index masqué");
res(db.getCollectionNames().every(n => !n.startsWith("essai_")), "Aucune collection de test essai_*");

print("== Plans d'\''exécution");
let e = db.activites.find({ formation_id: "BD511", type: "quiz", score: { $gte: 80 } }).sort({ date: -1 }).limit(10).explain("executionStats");
let plan = etapes(e).map(x => x.stage).join(" → ");
res(plan === "IXSCAN → FETCH → LIMIT" && e.executionStats.totalDocsExamined === 10,
    "Page « Derniers quiz réussis » sans tri en mémoire", `${plan}, ${e.executionStats.totalKeysExamined} clés, ${e.executionStats.totalDocsExamined} documents`);
e = db.activites.find({ stagiaire_id: "STG0042" }).sort({ date: -1 }).limit(20).explain("executionStats");
plan = etapes(e).map(x => x.stage).join(" → ");
res(plan === "IXSCAN → FETCH → LIMIT" && e.executionStats.totalDocsExamined === 20,
    "Page « Mon activité » sans tri en mémoire", `${plan}, ${e.executionStats.totalKeysExamined} clés, ${e.executionStats.totalDocsExamined} documents`);

print("");
print(`Bilan : ${ok} OK, ${ko} KO`);
if (ko > 0) quit(1);
'
