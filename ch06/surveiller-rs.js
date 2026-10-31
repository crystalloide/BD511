// surveiller-rs.js - BD511 ch.6 : affiche l'état des membres du replica set à chaque changement
// Usage : ~/bd511/ch06/mongosh-rs1 --quiet ~/bd511/ch06/surveiller-rs.js   (15 min par défaut, DUREE=<s> pour changer ; Ctrl+C pour arrêter)
// Chaque seconde, l'état est demandé de préférence à un secondaire (readPreference secondaryPreferred) :
// la surveillance continue pendant la panne du primaire, vue par les autres membres.
const admin = db.getSiblingDB("admin");
const duree = Number(process.env.DUREE || 900);
let precedent = "";
print(`Surveillance de ${db.hello().setName} pendant ${duree} s (une ligne à chaque changement)`);
for (let i = 0; i < duree; i++) {
  let ligne, source = "";
  try {
    const s = admin.runCommand({ replSetGetStatus: 1 }, { readPreference: "secondaryPreferred" });
    source = `   (vu par ${s.members.find(m => m.self).name.split(":")[0]})`;
    const etats = s.members.map(m => `${m.name.split(":")[0]}:${m.health === 1 ? m.stateStr : "injoignable"}`);
    ligne = `terme ${s.term}  ${etats.join("  ")}`;
  } catch (e) {
    ligne = `aucun membre ne répond (${e.codeName || e.name})`;
  }
  if (ligne !== precedent) print(`${new Date().toTimeString().slice(0, 8)}  ${ligne}${source}`);
  precedent = ligne;
  sleep(1000);
}
