// init-rscfg.js - BD511 ch.7 : initialise le replica set RSCFG des serveurs de configuration
// Exécuté dans le conteneur config1, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/bd511/cluster && sudo docker compose exec -T config1 mongosh --port 27041 --quiet --file /dev/stdin < ~/bd511/ch07/init-rscfg.js
const config = {
  _id: "RSCFG",
  configsvr: true,                 // replica set de serveurs de configuration (lancés avec --configsvr)
  members: [                       // trois membres porteurs de données, sans arbitre (interdit pour RSCFG)
    { _id: 0, host: "config1:27041" },
    { _id: 1, host: "config2:27042" },
    { _id: 2, host: "config3:27043" },
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection d'un primaire et de la synchronisation des secondaires (60 s au plus)
for (let i = 0; i < 60; i++) {
  const etats = rs.status().members.map(m => m.stateStr);
  if (etats.filter(e => e === "PRIMARY").length === 1 && etats.filter(e => e === "SECONDARY").length === 2) break;
  sleep(1000);
}
for (const m of rs.status().members) print(`${m.name.padEnd(14)} ${m.stateStr}`);
