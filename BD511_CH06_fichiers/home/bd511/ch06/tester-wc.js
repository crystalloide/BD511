// tester-wc.js - BD511 ch.6 : une insertion par write concern, avec sa durée et son résultat
// Usage : ~/bd511/ch06/mongosh-rs1 --compte appli --quiet ~/bd511/ch06/tester-wc.js
// wtimeout borne l'attente à 3 s ; on vérifie ensuite si le document a bien été écrit sur le primaire.
const coll = db.getSiblingDB("bd511").tests_wc;
const essais = [
  { w: 0 },
  { w: 1 },
  { w: 1, j: true },
  { w: "majority", wtimeout: 3000 },
  { w: 2, wtimeout: 3000 },
  { w: 3, wtimeout: 3000 },
];
print(`Primaire : ${db.hello().primary}`);
print("writeConcern".padEnd(36) + "durée".padStart(8) + "  résultat".padEnd(40) + "écrit sur le primaire ?");
for (const wc of essais) {
  const id = new ObjectId();
  const debut = Date.now();
  let resultat;
  try {
    const r = coll.insertOne({ _id: id, wc, t: new Date() }, { writeConcern: wc });
    resultat = r.acknowledged ? "acquittée" : "non acquittée (w: 0)";
  } catch (e) {
    resultat = `erreur ${e.codeName || e.code}`;
  }
  const duree = `${Date.now() - debut} ms`;
  sleep(200);   // laisse aboutir l'écriture w: 0, qui n'attend aucune réponse
  const present = coll.findOne({ _id: id }) ? "oui" : "non";
  print(EJSON.stringify(wc).padEnd(36) + duree.padStart(8) + `  ${resultat}`.padEnd(40) + present);
}
