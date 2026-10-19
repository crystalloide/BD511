// test-connexion.js - BD511 ch.2 : informations de connexion après installation
// Usage : mongosh --quiet --file ~/bd511/ch02/test-connexion.js
const admin = db.getSiblingDB("admin");
const build = admin.runCommand({ buildInfo: 1 });
const statut = admin.runCommand({ serverStatus: 1 });
const options = admin.runCommand({ getCmdLineOpts: 1 }).parsed;
const hote = admin.runCommand({ hostInfo: 1 });
const avertissements = admin.runCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg);
const bases = admin.runCommand({ listDatabases: 1, nameOnly: true }).databases.map(b => b.name);
const formations = db.getSiblingDB("bd511").formations;

const ligne = (libelle, valeur) => print(libelle.padEnd(28) + ": " + valeur);
ligne("Serveur MongoDB", build.version + " (allocateur " + build.allocator + ")");
ligne("Shell mongosh", version());
ligne("Noyau Linux", hote.extra.kernelVersion);
ligne("Processus mongod", "PID " + String(statut.pid) + ", démarré depuis " + statut.uptime + " s");
ligne("Moteur de stockage", statut.storageEngine.name);
ligne("dbPath", options.storage.dbPath);
ligne("Écoute", options.net.bindIp + ":" + options.net.port);
ligne("Caches TCMalloc par CPU", statut.tcmalloc.usingPerCPUCaches);
ligne("Connexions", statut.connections.current + " ouverte(s), " + statut.connections.available + " disponible(s)");
ligne("Bases", bases.join(", "));
ligne("bd511.formations", formations.countDocuments() + " document(s)");
ligne("Avertissements de démarrage", avertissements.length);
avertissements.forEach(a => print("  - " + a));
