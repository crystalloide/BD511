// client-charge.js - BD511 ch.8 : un client de l'application de vente en ligne, qui sollicite la collection bd511.ventes
// À chaque opération, tirage au hasard :
//   60 % « fiche client »  : les 10 dernières ventes d'un client (find sur client, tri par date décroissante)
//   25 % « nouvelle vente » : insertion d'une vente
//   15 % « mise à jour »    : changement du statut d'une vente, retrouvée par son numéro (_id)
// Le client vise RYTHME opérations par seconde (10 par défaut) et s'arrête au bout de DUREE secondes (3600 par défaut).
// Toutes les 10 s, il écrit une ligne de bilan : nombre d'opérations et durée moyenne par type.
// Usage : lancé par charge.sh (RYTHME=10 DUREE=3600 ~/BD511/ch08/mongosh-bd511 --compte charge --quiet client-charge.js)
const ventes = db.getSiblingDB("bd511").ventes;
const rythme = Number(process.env.RYTHME || 10), duree = Number(process.env.DUREE || 3600);
const intervalle = 1000 / rythme, fin = Date.now() + duree * 1000;
const heure = () => new Date().toTimeString().slice(0, 8);
const hasard = n => Math.floor(Math.random() * n);
const client = () => "C" + String(1 + hasard(50000)).padStart(5, "0");
const operations = {
  "fiches client": () => ventes.find({ client: client() }).sort({ date: -1 }).limit(10).toArray(),
  "nouvelles ventes": () => ventes.insertOne({ date: new Date(), client: client(), region: "EU", pays: "FR", canal: "web",
                                              statut: "payee", articles: 1 + hasard(8), montant: 5 + hasard(9500) / 10 }),
  "mises à jour": () => ventes.updateOne({ _id: 1 + hasard(1000000) }, { $set: { statut: "livree" }, $currentDate: { maj: true } }),
};
const choisir = () => { const x = Math.random(); return x < 0.60 ? "fiches client" : x < 0.85 ? "nouvelles ventes" : "mises à jour"; };

let bilan = {}, prochainBilan = Date.now() + 10000;
print(`${heure()}  début : ${rythme} opérations/s visées pendant ${duree} s`);
while (Date.now() < fin) {
  const nom = choisir(), t0 = Date.now();
  try { operations[nom](); } catch (e) { print(`${heure()}  erreur (${nom}) : ${e.message}`); sleep(1000); }
  const ms = Date.now() - t0;
  bilan[nom] ??= { n: 0, ms: 0 };
  bilan[nom].n++; bilan[nom].ms += ms;
  if (Date.now() >= prochainBilan) {
    print(`${heure()}  ` + Object.entries(bilan).sort().map(([k, v]) => `${k} ${v.n} (moy. ${Math.round(v.ms / v.n)} ms)`).join(" ; "));
    bilan = {}; prochainBilan += 10000;
  }
  sleep(Math.max(0, intervalle - ms));
}
print(`${heure()}  fin`);
