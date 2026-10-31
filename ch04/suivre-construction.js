// suivre-construction.js - BD511 ch.4 : suit les constructions d'index en cours ($currentOp)
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/admin?appName=bd511-tp4" ~/bd511/ch04/suivre-construction.js
// Affiche la phase et l'avancement toutes les 0,5 s, jusqu'à la fin de la construction (2 minutes au plus).
let dejaVu = false;
let dernier = "";
for (let i = 0; i < 240; i++) {
  const ops = db.getSiblingDB("admin").aggregate([
    { $currentOp: {} },
    { $match: { desc: /^IndexBuildsCoordinator/, "command.createIndexes": { $exists: true } } },
  ]).toArray();
  if (ops.length === 0) {
    if (dejaVu) { print("Construction terminée."); break; }
    if (i === 10) { print("Aucune construction d'index en cours (déjà terminée ?)."); break; }
  }
  for (const op of ops) {
    dejaVu = true;
    const phase = (op.msg || "").split(" Index Build:")[0];   // msg répète la phase avec l'avancement
    const avancement = op.progress ? `${Math.floor(100 * op.progress.done / op.progress.total)} %` : "";
    const ligne = `${op.ns}  ${op.command.indexes.map(ix => ix.name).join(",")}  ${phase}  ${avancement}`;
    if (ligne !== dernier) print(`${new Date().toTimeString().slice(0, 8)}  ${ligne}`);
    dernier = ligne;
  }
  sleep(500);
}
