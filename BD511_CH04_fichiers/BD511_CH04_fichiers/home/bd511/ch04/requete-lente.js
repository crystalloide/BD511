// requete-lente.js - BD511 ch.4 : requête de la page « Derniers quiz réussis » de la plate-forme
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/bd511?appName=bd511-appli" ~/bd511/ch04/requete-lente.js
// appName identifie l'application dans le journal de mongod et dans db.currentOp().
// La page est affichée 3 fois de suite : la durée de chaque requête est mesurée côté client.
const formation = "BD511";
const requete = () => db.activites
  .find({ formation_id: formation, type: "quiz", score: { $gte: 80 } })
  .sort({ date: -1 })
  .limit(10)
  .toArray();

const durees = [];
let quiz = [];
for (let i = 0; i < 3; i++) {
  const debut = Date.now();
  quiz = requete();
  durees.push(Date.now() - debut);
}

print(`Derniers quiz réussis (score >= 80) - formation ${formation}`);
for (const q of quiz) {
  const date = q.date.toISOString().slice(0, 16).replace("T", " ");
  print(`  ${date}  ${q.stagiaire_id}  ${String(q.score).padStart(3)}  ${q.appareil}`);
}
print(`${quiz.length} quiz ; durée des 3 affichages : ${durees.join(" ms, ")} ms`);
