// inserer-ventes.js - BD511 ch.7 : simule l'activité d'octobre 2026 (10 000 nouvelles ventes, numérotées
// à partir de 200 001) dans une collection, puis indique sur quel shard ces nouvelles ventes ont été écrites.
// Relançable : les ventes d'une exécution précédente sont d'abord supprimées.
// Usage : COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
const nom = process.env.COLL || "ventes";
const coll = db.getCollection(nom);
const NB = 10000, PREMIER = 200001, DEBUT = Date.parse("2026-10-01T00:00:00Z");
coll.deleteMany({ _id: { $gte: PREMIER } });

// Clients existants, avec leur région et leur pays ; tirage pseudo-aléatoire reproductible (générateur de Park et Miller)
const clients = coll.aggregate([
  { $match: { _id: { $lt: PREMIER } } },
  { $group: { _id: "$client", region: { $first: "$region" }, pays: { $first: "$pays" } } },
  { $sort: { _id: 1 } },
]).toArray();
let graine = 511;
const alea = () => (graine = (graine * 16807) % 2147483647) / 2147483647;

const t0 = Date.now();
for (let lot = 0; lot < NB / 1000; lot++) {
  const ventes = [];
  for (let i = 0; i < 1000; i++) {
    const n = lot * 1000 + i;
    const c = clients[Math.floor(alea() * clients.length)];
    const articles = 1 + Math.floor(alea() * alea() * 8);
    ventes.push({ _id: PREMIER + n, date: new Date(DEBUT + n * 240000), client: c._id, region: c.region, pays: c.pays,
                  canal: "web", articles, montant: Math.round(articles * (5 + alea() * 95) * 100) / 100 });
  }
  coll.insertMany(ventes, { ordered: false });
}
const duree = ((Date.now() - t0) / 1000).toFixed(1);

// Nombre de nouvelles ventes trouvées sur chaque shard (plan d'exécution de la requête diffusée correspondante)
const stats = coll.find({ _id: { $gte: PREMIER } }).explain("executionStats").executionStats.executionStages;
const parShard = stats.shards ?? [{ shardName: stats.shardName, nReturned: stats.nReturned }];
print(`bd511.${nom} : ${NB} nouvelles ventes (octobre 2026) insérées en ${duree} s`);
for (const s of parShard.sort((a, b) => a.shardName.localeCompare(b.shardName))) {
  const n = s.nReturned ?? s.executionStages?.nReturned;
  print(`  ${s.shardName}  ${String(n).padStart(6)} nouvelles ventes ${String(Math.round(100 * n / NB)).padStart(4)} %`);
}
