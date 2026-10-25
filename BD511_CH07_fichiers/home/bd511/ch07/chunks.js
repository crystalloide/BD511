// chunks.js - BD511 ch.7 : liste les chunks d'une collection shardée, dans l'ordre de la clé, avec leur shard
// Puis les plages de zones éventuellement définies sur la collection.
// Usage : COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/chunks.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const config = db.getSiblingDB("config");
const coll = config.collections.findOne({ _id: ns });
if (!coll) { print(`${ns} n'est pas une collection shardée.`); quit(1); }
const texte = v => EJSON.stringify(v);
print(`${ns}   clé de sharding ${texte(coll.key)}`);
config.chunks.find({ uuid: coll.uuid }).sort({ min: 1 })
  .forEach(c => print(`  chunk  ${c.shard}  ${texte(c.min)}  ->  ${texte(c.max)}`));
config.tags.find({ ns }).sort({ min: 1 })
  .forEach(z => print(`  zone   ${z.tag}  ${texte(z.min)}  ->  ${texte(z.max)}`));
