// comparer.js - BD511 ch.4 : compare les plans possibles de la requête lente, un par index existant
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-tp4" ~/bd511/ch04/comparer.js
// Chaque variante est imposée avec hint() ; la durée est la médiane de 5 exécutions complètes.
const filtre = { formation_id: "BD511", type: "quiz", score: { $gte: 80 } };
const tri = { date: -1 };
const LIMITE = 10;
const ESSAIS = 5;

function etapesDuPlan(plan) {
  const etapes = [];
  for (let e = plan; e; e = e.inputStage || (e.inputStages && e.inputStages[0])) etapes.unshift(e);
  return etapes;
}

function mesurer(indication) {
  const requete = () => {
    const curseur = db.activites.find(filtre).sort(tri).limit(LIMITE);
    return indication ? curseur.hint(indication) : curseur;
  };
  const exp = requete().explain("executionStats");
  const etapes = etapesDuPlan(exp.queryPlanner.winningPlan.queryPlan || exp.queryPlanner.winningPlan);
  const durees = [];
  for (let i = 0; i < ESSAIS; i++) {
    const debut = Date.now();
    requete().toArray();
    durees.push(Date.now() - debut);
  }
  durees.sort((a, b) => a - b);
  const scan = etapes.find(e => e.indexName);
  return {
    plan: etapes.map(e => e.stage).join(" → "),
    index: scan ? scan.indexName : "aucun (COLLSCAN)",
    cles: exp.executionStats.totalKeysExamined,
    docs: exp.executionStats.totalDocsExamined,
    renvoyes: exp.executionStats.nReturned,
    triMemoire: etapes.some(e => e.stage === "SORT") ? "oui" : "non",
    duree: durees[Math.floor(ESSAIS / 2)],
  };
}

const variantes = [["Sans index ($natural)", { $natural: 1 }]];
const masques = [];
for (const ix of db.activites.getIndexes()) {
  if (ix.name === "_id_") continue;
  if (ix.hidden) masques.push(ix.name);
  else variantes.push([ix.name, ix.name]);
}
variantes.push(["Choix du planificateur", null]);

print("Requête : find(" + EJSON.stringify(filtre) + ").sort(" + EJSON.stringify(tri) + ").limit(" + LIMITE + ")");
print("");
print("Variante (hint)".padEnd(27) + "Plan d'exécution".padEnd(25) + "Clés lues".padStart(10) +
      "Docs lus".padStart(10) + "  Tri mémoire" + "Durée".padStart(9));
let choix;
for (const [nom, indication] of variantes) {
  const m = mesurer(indication);
  if (indication === null) choix = m.index;
  print(nom.padEnd(27) + m.plan.padEnd(25) + String(m.cles).padStart(10) + String(m.docs).padStart(10) +
        "  " + m.triMemoire.padEnd(11) + `${m.duree} ms`.padStart(9));
}
print("");
print(`Index retenu par le planificateur : ${choix}`);
if (masques.length) print(`Index masqués (non testés) : ${masques.join(", ")}`);
