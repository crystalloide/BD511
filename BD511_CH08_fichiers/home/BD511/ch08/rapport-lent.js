// rapport-lent.js - BD511 ch.8 : rapport « fidélité des clients », écrit sans précaution par un analyste
// Pour chaque client, compte les ventes réalisées plus d'un an après sa première commande. Sans index sur
// le champ client, chaque recherche ($lookup) parcourt toute la collection : le rapport ne se termine jamais.
// Usage : APPNAME=rapport-fidelite ~/BD511/ch08/mongosh-bd511 --compte charge --quiet ~/BD511/ch08/rapport-lent.js
const debut = Date.now();
print(`${new Date().toTimeString().slice(0, 8)}  rapport de fidélité : début`);
try {
  const resultat = db.getSiblingDB("bd511").ventes.aggregate([
    { $group: { _id: "$client", premiere: { $min: "$date" } } },
    { $lookup: {
        from: "ventes", let: { client: "$_id", premiere: "$premiere" },
        pipeline: [
          { $match: { $expr: { $and: [
            { $eq: ["$client", "$$client"] },
            { $gt: ["$date", { $dateAdd: { startDate: "$$premiere", unit: "year", amount: 1 } }] },
          ] } } },
          { $count: "n" },
        ],
        as: "fidelite" } },
    { $match: { "fidelite.n": { $gte: 5 } } },
    { $count: "clientsFideles" },
  ], { allowDiskUse: true }).toArray();
  print(`${new Date().toTimeString().slice(0, 8)}  clients fidèles : ${resultat[0]?.clientsFideles ?? 0} (${Math.round((Date.now() - debut) / 1000)} s)`);
} catch (e) {
  print(`${new Date().toTimeString().slice(0, 8)}  rapport interrompu au bout de ${Math.round((Date.now() - debut) / 1000)} s : ${e.codeName ?? ""} ${e.message}`);
}
