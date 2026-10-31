// analyse-profil.js - BD511 ch.8 : synthèse des opérations lentes enregistrées par le profiler de la base bd511
// Regroupe les entrées de system.profile par forme de requête (queryShapeHash) : nombre, durée moyenne,
// documents examinés et renvoyés, plan d'exécution, puis affiche un exemple de la forme la plus coûteuse.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/analyse-profil.js
const formes = db.system.profile.aggregate([
  { $match: { ns: { $ne: "bd511.system.profile" } } },
  { $group: {
      _id: { $ifNull: ["$queryShapeHash", "$op"] },
      op: { $first: "$op" }, ns: { $first: "$ns" }, plan: { $first: "$planSummary" },
      nombre: { $sum: 1 }, dureeMoy: { $avg: "$millis" }, dureeTotale: { $sum: "$millis" },
      examines: { $avg: "$docsExamined" }, renvoyes: { $avg: "$nreturned" }, exemple: { $first: "$command" } } },
  { $sort: { dureeTotale: -1 } },
]).toArray();
const total = db.system.profile.countDocuments({ ns: { $ne: "bd511.system.profile" } });
print(`${total} opérations lentes profilées (seuil ${db.getProfilingStatus().slowms} ms), ${formes.length} forme(s) de requête`);
for (const f of formes) {
  print(`  ${String(f.nombre).padStart(4)} × ${f.op.padEnd(8)} ${f.ns.padEnd(13)} ${(f.plan ?? "-").padEnd(9)} ` +
        `durée moy. ${Math.round(f.dureeMoy)} ms, documents examinés ${Math.round(f.examines).toLocaleString("fr-FR")}, renvoyés ${Math.round(f.renvoyes)}`);
}
if (formes.length) {
  const { lsid, $db, ...commande } = formes[0].exemple;
  print("Forme la plus coûteuse, exemple :");
  print("  " + EJSON.stringify(commande));
}
