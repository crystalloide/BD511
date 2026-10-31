// init-rs2.js - BD511 ch.7 : initialise le replica set RS2 (futur shard 2), sur le modèle de RS1
// Exécuté dans le conteneur rs21, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/bd511/cluster && sudo docker compose exec -T rs21 mongosh --port 27021 --quiet --file /dev/stdin < ~/bd511/ch07/init-rs2.js
const config = {
  _id: "RS2",
  members: [
    { _id: 0, host: "rs21:27021", priority: 2 },        // primaire de l'architecture : priorité la plus haute
    { _id: 1, host: "rs22:27022", priority: 1 },        // secondaire
    { _id: 2, host: "rs2arb:27023", arbiterOnly: true }, // arbitre : vote, ne stocke pas de données
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection de rs21 comme primaire et de la synchronisation de rs22 (60 s au plus)
for (let i = 0; i < 60; i++) {
  const etats = rs.status().members.map(m => m.stateStr);
  if (db.hello().isWritablePrimary && etats.includes("SECONDARY")) break;
  sleep(1000);
}
for (const m of rs.status().members) print(`${m.name.padEnd(13)} ${m.stateStr}`);
