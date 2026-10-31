// coherence.js - BD511 ch.9 : vérifie l'invariant de la boutique sur la base bd511
//   pour chaque article : stockInitial = stock + somme des quantités de ses commandes
// Sur un replica set, toutes les lectures se font dans un même instantané (session « snapshot ») : le contrôle
// est exact même pendant que l'application écrit. Sur l'instance de test (mongod autonome), lectures ordinaires.
// Usage : ~/BD511/ch09/mongosh-rs9 [--cible restau] --quiet ~/BD511/ch09/coherence.js
const fmt = v => v.toLocaleString("fr-FR");
const replicaSet = Boolean(db.hello().setName);
const session = replicaSet ? db.getMongo().startSession({ snapshot: true }) : null;
const base = session ? session.getDatabase("bd511") : db.getSiblingDB("bd511");

const a = base.articles.aggregate([{ $group: { _id: null, n: { $sum: 1 }, initial: { $sum: "$stockInitial" },
                                                stock: { $sum: "$stock" } } }]).toArray()[0] ?? { n: 0, initial: 0, stock: 0 };
const c = base.commandes.aggregate([{ $group: { _id: null, n: { $sum: 1 }, quantite: { $sum: "$quantite" } } }])
  .toArray()[0] ?? { n: 0, quantite: 0 };
const parArticle = new Map(base.commandes.aggregate([{ $group: { _id: "$article", q: { $sum: "$quantite" } } }])
  .toArray().map(x => [x._id, x.q]));
let incoherents = 0;
base.articles.find({}, { stockInitial: 1, stock: 1 }).forEach(x => {
  if (x.stockInitial - x.stock !== (parArticle.get(x._id) ?? 0)) incoherents++;
});
const ecart = a.initial - a.stock - c.quantite;
const h = db.hello();
const cible = replicaSet ? `${h.me.split(":")[0]} (${h.isWritablePrimary ? "primaire" : "secondaire"} de ${h.setName})` : "restau (instance de test)";
print(`bd511 sur ${cible} : ${fmt(a.n)} articles, ${fmt(c.n)} commandes`);
print(`  stock initial ${fmt(a.initial)} = stock restant ${fmt(a.stock)} + quantités commandées ${fmt(c.quantite)} : ` +
      (ecart === 0 ? "COHÉRENT" : `INCOHÉRENT (écart de ${ecart > 0 ? "+" : ""}${fmt(ecart)} unités)`));
print(`  articles incohérents : ${fmt(incoherents)}`);
if (session) session.endSession();
