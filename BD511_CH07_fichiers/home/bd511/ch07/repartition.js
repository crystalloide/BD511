// repartition.js - BD511 ch.7 : répartition d'une collection shardée de la base bd511 entre les shards
// Pour chaque shard : documents possédés, volume (données non compressées), chunks, documents orphelins.
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const config = db.getSiblingDB("config");
const coll = config.collections.findOne({ _id: ns });
if (!coll) { print(`${ns} n'est pas une collection shardée.`); quit(1); }

const chunks = {};
config.chunks.aggregate([{ $match: { uuid: coll.uuid } }, { $group: { _id: "$shard", n: { $sum: 1 } } }])
  .forEach(c => { chunks[c._id] = c.n; });
const repartition = db.getSiblingDB("admin").aggregate([{ $shardedDataDistribution: {} }, { $match: { ns } }]).toArray();
const parShard = Object.fromEntries((repartition[0]?.shards ?? []).map(s => [s.shardName, s]));
const total = Object.values(parShard).reduce((t, s) => t + s.numOwnedDocuments, 0);

print(`${ns}   clé de sharding ${EJSON.stringify(coll.key)}`);
for (const { _id: shard } of config.shards.find({}, { _id: 1 }).sort({ _id: 1 })) {
  const s = parShard[shard] ?? { numOwnedDocuments: 0, ownedSizeBytes: 0, numOrphanedDocs: 0 };
  const pct = total ? Math.round(100 * s.numOwnedDocuments / total) : 0;
  print(`  ${shard}  ${String(s.numOwnedDocuments).padStart(7)} documents ${String(pct).padStart(4)} %` +
        `  ${(s.ownedSizeBytes / 1048576).toFixed(1).padStart(5)} Mo  ${String(chunks[shard] ?? 0).padStart(3)} chunk(s)` +
        `  ${String(s.numOrphanedDocs).padStart(6)} orphelin(s)`);
}
