// ecrivain.js - BD511 ch.6 : simule une application qui écrit en continu (10 insertions par seconde)
// Usage : DUREE=120 ~/bd511/ch06/mongosh-rs1 --compte appli --quiet ~/bd511/ch06/ecrivain.js
// Affiche les incidents (erreur ou écriture de plus d'une seconde), un point d'étape toutes les 10 s,
// puis la plus longue interruption : l'écart maximal entre deux écritures confirmées.
const duree = Number(process.env.DUREE || 120);
const coll = db.getSiblingDB("bd511").ecritures;
const heure = () => new Date().toTimeString().slice(0, 8);
let ok = 0, erreurs = 0, n = 0, dernierOk = Date.now(), interruption = 0;
const fin = Date.now() + duree * 1000;
let prochainPoint = Date.now() + 10000;
print(`${heure()}  début : une insertion toutes les 100 ms pendant ${duree} s`);
while (Date.now() < fin) {
  const debut = Date.now();
  try {
    coll.insertOne({ n: ++n, t: new Date() });
    ok++;
    interruption = Math.max(interruption, Date.now() - dernierOk);
    dernierOk = Date.now();
    if (Date.now() - debut >= 1000) print(`${heure()}  écriture n°${n} confirmée après ${Date.now() - debut} ms`);
  } catch (e) {
    erreurs++;
    print(`${heure()}  écriture n°${n} en erreur après ${Date.now() - debut} ms : ${e.codeName || e.name}`);
  }
  if (Date.now() >= prochainPoint) {
    print(`${heure()}  ${ok} écritures confirmées, ${erreurs} en erreur`);
    prochainPoint = Date.now() + 10000;
  }
  sleep(Math.max(0, 100 - (Date.now() - debut)));
}
print(`${heure()}  fin : ${ok} écritures confirmées, ${erreurs} en erreur, plus longue interruption ${(interruption / 1000).toFixed(1)} s`);
