// operations-longues.js - BD511 ch.8 : opérations actives depuis plus de SEUIL_MS millisecondes (500 par défaut),
// les plus longues d'abord, avec leur identifiant (opid), leur durée, leur plan et l'application qui les a lancées.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/operations-longues.js
const seuil = Number(process.env.SEUIL_MS || 500);
const operations = db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, idleConnections: false } },
  { $match: { active: true, op: { $ne: "none" }, microsecs_running: { $gte: seuil * 1000 },
              "command.hello": { $exists: false } } },          // attentes de surveillance des clients, sans intérêt ici
  { $sort: { microsecs_running: -1 } },
]).toArray();
print(`${operations.length} opération(s) active(s) depuis plus de ${seuil} ms`);
for (const o of operations) {
  print(`  opid ${String(o.opid).padEnd(7)} ${(o.microsecs_running / 1e6).toFixed(1).padStart(6)} s  ${o.op.padEnd(8)} ` +
        `${(o.ns ?? "").padEnd(13)} ${(o.planSummary ?? "-").padEnd(9)} ${o.appName ?? ""}`);
}
