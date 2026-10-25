// incident.js - BD511 ch.9 : l'incident à réparer. Un script de purge, lancé avec le compte de l'application,
// devait supprimer l'ancienne collection commandes_archive ; une erreur de nom lui fait supprimer commandes.
// Le script note l'heure et le nombre de commandes juste avant la suppression, pour vérifier la restauration.
// Usage : ~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/incident.js
const collection = "commandes";                       // l'erreur : "commandes" au lieu de "commandes_archive"
const avant = db.getCollection(collection).countDocuments();
print(`${new Date().toTimeString().slice(0, 8)}  purge de bd511.${collection} (${avant} documents)`);
db.getCollection(collection).drop();
print(`${new Date().toTimeString().slice(0, 8)}  collection bd511.${collection} supprimée`);
