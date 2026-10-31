// explain-resume.js - BD511 ch.4 : résumé lisible d'un plan d'exécution (explain "executionStats")
// Chargement dans mongosh : load(process.env.HOME + "/bd511/ch04/explain-resume.js")
// Usage : resume(db.collection.find(filtre).sort(tri).limit(n))   ou   resume(resultatDeExplain)

// Étapes d'un plan, de la feuille (lecture des données) à la racine (envoi au client)
function etapesDuPlan(plan) {
  const etapes = [];
  for (let e = plan; e; e = e.inputStage || (e.inputStages && e.inputStages[0])) etapes.unshift(e);
  return etapes;
}

function formatCle(cle) {
  return "{ " + Object.entries(cle).map(([champ, sens]) => `${champ}: ${sens}`).join(", ") + " }";
}

function resume(requete) {
  const exp = typeof requete.explain === "function" ? requete.explain("executionStats") : requete;
  const qp = exp.queryPlanner;
  const etapes = etapesDuPlan(qp.winningPlan.queryPlan || qp.winningPlan);
  const s = exp.executionStats;
  const scan = etapes.find(e => e.stage === "IXSCAN");
  const triMemoire = etapes.some(e => e.stage === "SORT");
  const ratio = s.nReturned > 0 ? Math.round(s.totalDocsExamined / s.nReturned) : s.totalDocsExamined;
  const rejetes = qp.rejectedPlans.map(p => {
    const ix = etapesDuPlan(p.queryPlan || p).find(e => e.indexName);
    return ix ? ix.indexName : "COLLSCAN";
  });

  print(`Plan d'exécution       : ${etapes.map(e => e.stage).join(" → ")}`);
  print(`Index utilisé          : ${scan ? scan.indexName + " " + formatCle(scan.keyPattern) : "aucun"}`);
  print(`Tri en mémoire (SORT)  : ${triMemoire ? "oui" : "non"}`);
  print(`Documents renvoyés     : ${s.nReturned}`);
  print(`Clés d'index examinées : ${s.totalKeysExamined}`);
  print(`Documents examinés     : ${s.totalDocsExamined}`);
  print(`Examinés / renvoyés    : ${ratio}`);
  print(`Durée côté serveur     : ${s.executionTimeMillis} ms`);
  print(`Plans rejetés          : ${rejetes.length ? rejetes.join(", ") : "aucun"}`);

  const diagnostic = [];
  if (etapes.some(e => e.stage === "COLLSCAN"))
    diagnostic.push("COLLSCAN : toute la collection est lue, aucun index n'est utilisé.");
  if (triMemoire)
    diagnostic.push("SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).");
  if (ratio > 10)
    diagnostic.push(`ratio ${ratio} : la plupart des documents lus sont écartés ensuite.`);
  if (s.totalDocsExamined === 0 && s.nReturned > 0)
    diagnostic.push("requête couverte : résultats lus dans l'index, aucun document chargé.");
  if (diagnostic.length === 0)
    diagnostic.push("plan efficace : chaque document lu est renvoyé, sans tri en mémoire.");
  for (const d of diagnostic) print(`Diagnostic             : ${d}`);
}
