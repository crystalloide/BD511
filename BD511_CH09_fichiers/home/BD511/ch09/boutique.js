// boutique.js - BD511 ch.9 : l'application de la boutique en ligne, qui passe des commandes en continu
// Chaque commande est une transaction multi-documents : le stock de l'article diminue de la quantité commandée
// ET la commande est enregistrée, ou rien du tout. Pour chaque article, stockInitial = stock + quantités commandées.
// L'application vise RYTHME commandes par seconde (10 par défaut) pendant DUREE secondes (7200 par défaut) et
// s'arrête proprement dès que le fichier ~/BD511/ch09/boutique.stop existe. Toutes les 10 s, elle écrit un bilan.
// Usage : lancé par boutique.sh (~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/boutique.js)
const fs = require("fs");
const STOP = process.env.HOME + "/BD511/ch09/boutique.stop";
const rythme = Number(process.env.RYTHME || 10), duree = Number(process.env.DUREE || 7200);
const intervalle = 1000 / rythme, fin = Date.now() + duree * 1000;
const heure = () => new Date().toTimeString().slice(0, 8);
const hasard = n => Math.floor(Math.random() * n);
const QUANTITES = [1, 1, 1, 1, 2, 2, 3, 4, 5];

const session = db.getMongo().startSession();
const articles = session.getDatabase("bd511").articles, commandes = session.getDatabase("bd511").commandes;
let bilan = { commandes: 0, ruptures: 0, erreurs: 0, ms: 0 }, prochainBilan = Date.now() + 10000;
print(`${heure()}  début : ${rythme} commandes/s visées`);
while (Date.now() < fin && !fs.existsSync(STOP)) {
  const article = "ART" + String(1 + hasard(20000)).padStart(5, "0"), quantite = QUANTITES[hasard(QUANTITES.length)];
  const t0 = Date.now();
  try {
    session.withTransaction(() => {
      const a = articles.findOneAndUpdate({ _id: article, stock: { $gte: quantite } }, { $inc: { stock: -quantite } },
                                          { projection: { prix: 1 } });
      if (!a) { bilan.ruptures++; return; }                       // stock insuffisant : rien n'est écrit
      commandes.insertOne({ date: new Date(), client: "C" + String(1 + hasard(50000)).padStart(5, "0"), article,
                            quantite, montant: Math.round(quantite * a.prix * 100) / 100 });
      bilan.commandes++;
    });
  } catch (e) {
    bilan.erreurs++;
    print(`${heure()}  erreur : ${e.codeName ?? ""} ${e.message}`);
    sleep(1000);
  }
  bilan.ms += Date.now() - t0;
  if (Date.now() >= prochainBilan) {
    const n = bilan.commandes + bilan.ruptures;
    print(`${heure()}  commandes ${bilan.commandes} (moy. ${n ? Math.round(bilan.ms / n) : 0} ms), ruptures ${bilan.ruptures}, erreurs ${bilan.erreurs}`);
    bilan = { commandes: 0, ruptures: 0, erreurs: 0, ms: 0 }; prochainBilan += 10000;
  }
  sleep(Math.max(0, intervalle - (Date.now() - t0)));
}
session.endSession();
print(`${heure()}  fin`);
