// plan-fiche-client.js - BD511 ch.8 : plan d'exécution résumé de la « fiche client » de l'application
// (les 10 dernières ventes du client C01234) : étapes du plan gagnant, documents et clés examinés, durée.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/plan-fiche-client.js
const e = db.ventes.find({ client: "C01234" }).sort({ date: -1 }).limit(10).explain("executionStats");
const etapes = [];
for (let s = e.queryPlanner.winningPlan.queryPlan ?? e.queryPlanner.winningPlan; s; s = s.inputStage) etapes.push(s.stage + (s.indexName ? ` (${s.indexName})` : ""));
const x = e.executionStats;
print(`plan : ${etapes.join(" <- ")}`);
print(`renvoyés : ${x.nReturned}, documents examinés : ${x.totalDocsExamined}, clés examinées : ${x.totalKeysExamined}, durée : ${x.executionTimeMillis} ms`);
