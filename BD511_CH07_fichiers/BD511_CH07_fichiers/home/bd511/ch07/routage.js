// routage.js - BD511 ch.7 : comment mongos route quelques requêtes types sur une collection shardée
// « ciblée » : envoyée au seul shard concerné ; « diffusée » : envoyée à tous les shards (scatter-gather).
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
const coll = db.getCollection(process.env.COLL || "ventes");
const requetes = [
  ["un client", { client: "C01913" }],
  ["100 clients consécutifs", { client: { $gte: "C15000", $lt: "C15100" } }],
  ["un mois de ventes", { date: { $gte: ISODate("2026-09-01T00:00:00Z"), $lt: ISODate("2026-10-01T00:00:00Z") } }],
  ["une région", { region: "AM" }],
  ["une région et un client", { region: "EU", client: "C01913" }],
];
for (const [libelle, filtre] of requetes) {
  const plan = coll.find(filtre).explain().queryPlanner.winningPlan;
  const shards = plan.shards.map(s => s.shardName).sort();
  const routage = shards.length === 1 ? "ciblée" : "diffusée";
  print(`${libelle.padEnd(25)} ${routage.padEnd(8)}  ${plan.stage.padEnd(12)}  ${shards.join(", ")}`);
}
