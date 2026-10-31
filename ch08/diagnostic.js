// diagnostic.js - BD511 ch.8 : photographie de la charge de mongod, d'après deux appels à serverStatus
// espacés de INTERVALLE secondes (10 par défaut) : débits, efficacité des requêtes, concurrence, mémoire.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/diagnostic.js
const intervalle = Number(process.env.INTERVALLE || 10);
const n = v => Number(v ?? 0);
const fmt = (v, d = 0) => v.toLocaleString("fr-FR", { maximumFractionDigits: d, minimumFractionDigits: d });
const avant = db.serverStatus();
sleep(intervalle * 1000);
const apres = db.serverStatus();
const debit = chemin => (n(chemin(apres)) - n(chemin(avant))) / intervalle;

const lectures = debit(s => s.opcounters.query), commandes = debit(s => s.opcounters.command);
const insertions = debit(s => s.opcounters.insert), majs = debit(s => s.opcounters.update);
const examines = debit(s => s.metrics.queryExecutor.scannedObjects), cles = debit(s => s.metrics.queryExecutor.scanned);
const renvoyes = debit(s => s.metrics.document.returned), tris = debit(s => s.metrics.operation.scanAndOrder);
const latence = (type) => {
  const ops = n(apres.opLatencies[type].ops) - n(avant.opLatencies[type].ops);
  return ops ? (n(apres.opLatencies[type].latency) - n(avant.opLatencies[type].latency)) / ops / 1000 : 0;
};
const ga = apres.globalLock.activeClients, gq = apres.globalLock.currentQueue;
const tickets = apres.queues.execution.read.normalPriority ?? apres.queues.execution.read;
const cache = apres.wiredTiger.cache, Mo = v => n(v) / 1048576;
const utilise = Mo(cache["bytes currently in the cache"]), maxi = Mo(cache["maximum bytes configured"]);

print(`Diagnostic de ${apres.host} (MongoDB ${apres.version}) sur ${intervalle} s, à ${new Date().toTimeString().slice(0, 8)}`);
print(`  Opérations/s        : lectures ${fmt(lectures, 1)}, insertions ${fmt(insertions, 1)}, mises à jour ${fmt(majs, 1)}, commandes ${fmt(commandes, 1)}`);
print(`  Documents/s         : examinés ${fmt(examines)}, renvoyés ${fmt(renvoyes)}` +
      (renvoyes ? ` (${fmt(examines / renvoyes)} examinés par document renvoyé)` : ""));
print(`  Clés d'index/s      : ${fmt(cles)} ; tris en mémoire/s : ${fmt(tris, 1)}`);
print(`  Latence moyenne     : lectures ${fmt(latence("reads"), 1)} ms, écritures ${fmt(latence("writes"), 1)} ms`);
print(`  Opérations actives  : ${ga.readers} en lecture, ${ga.writers} en écriture ; en attente : ${gq.readers} en lecture, ${gq.writers} en écriture`);
print(`  Tickets de lecture  : ${tickets.out} utilisés sur ${tickets.totalTickets}`);
print(`  Connexions          : ${apres.connections.current} ouvertes, ${apres.connections.available} disponibles`);
print(`  Cache WiredTiger    : ${fmt(utilise)} Mo sur ${fmt(maxi)} Mo (${fmt(100 * utilise / maxi)} %), mémoire résidente ${apres.mem.resident} Mo`);
