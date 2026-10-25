// suivre-balancer.js - BD511 ch.7 : suit le travail du balancer sur une collection jusqu'à ce qu'elle soit équilibrée
// Une ligne au départ, puis à chaque migration terminée : documents et chunks de chaque shard, migrations depuis le sharding.
// S'arrête dès que la collection est équilibrée (balancerCompliant), ou au bout de DUREE secondes (300 par défaut).
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/suivre-balancer.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const duree = Number(process.env.DUREE || 300);
const config = db.getSiblingDB("config");
const { uuid } = config.collections.findOne({ _id: ns });
const shards = config.shards.find({}, { _id: 1 }).sort({ _id: 1 }).toArray().map(s => s._id);
const debut = Date.now();
const heure = () => new Date().toTimeString().slice(0, 8);

// Nombre de chunks de chaque shard, lu dans les métadonnées : il change quand une migration est validée (commit)
function chunksParShard() {
  const chunks = {};
  config.chunks.aggregate([{ $match: { uuid } }, { $group: { _id: "$shard", n: { $sum: 1 } } }]).forEach(c => { chunks[c._id] = c.n; });
  return shards.map(s => chunks[s] ?? 0);
}

function ligne(chunks) {
  const docs = {};
  const r = db.getSiblingDB("admin").aggregate([{ $shardedDataDistribution: {} }, { $match: { ns } }]).toArray();
  for (const s of r[0]?.shards ?? []) docs[s.shardName] = s.numOwnedDocuments;
  const migrations = config.changelog.countDocuments({ ns, what: "moveChunk.commit" });
  const texte = shards.map((s, i) => `${s} ${String(docs[s] ?? 0).padStart(6)} docs ${String(chunks[i]).padStart(2)} chunk(s)`).join(" | ");
  return `${heure()}  ${texte} | ${migrations} migration(s)`;
}

// Affiche une ligne si la répartition des chunks a changé depuis la dernière ligne affichée
let precedent = "";
function afficherSiChange(attente) {
  if (chunksParShard().join() === precedent) return;
  sleep(attente);                     // laisse la migration finir de s'enregistrer (orphelins, historique)
  const chunks = chunksParShard();
  print(ligne(chunks));
  precedent = chunks.join();
}

print(`${heure()}  suivi de ${ns} : taille de chunk ${sh.balancerCollectionStatus(ns).chunkSize} Mo, balancer ${sh.getBalancerState() ? "actif" : "arrêté"}`);
afficherSiChange(0);
for (;;) {
  if (sh.balancerCollectionStatus(ns).balancerCompliant) {
    sleep(2000);                      // une dernière migration peut encore être en cours de validation
    afficherSiChange(0);
    print(`${heure()}  collection équilibrée`);
    break;
  }
  afficherSiChange(400);
  if ((Date.now() - debut) / 1000 > duree) { print(`${heure()}  arrêt du suivi après ${duree} s`); break; }
  sleep(250);
}
