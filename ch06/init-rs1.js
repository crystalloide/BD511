// init-rs1.js - BD511 ch.6 : initialise le replica set RS1
// Exécuté dans le conteneur rs11, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/bd511/cluster && sudo docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin < ~/bd511/ch06/init-rs1.js
const config = {
  _id: "RS1",
  members: [
    { _id: 0, host: "rs11:27011", priority: 2 },        // primaire de l'architecture : priorité la plus haute
    { _id: 1, host: "rs12:27012", priority: 1 },        // secondaire
    { _id: 2, host: "rs1arb:27013", arbiterOnly: true }, // arbitre : vote, ne stocke pas de données (priorité 0)
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection de rs11 comme primaire (60 s au plus)
for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
for (const m of rs.status().members) print(`${m.name.padEnd(13)} ${m.stateStr}`);
