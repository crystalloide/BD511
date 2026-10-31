// BD511 – TP chapitre 5 – Étape 3.4 : matrice des droits effectifs
// Lancement (aucune authentification préalable : le script ouvre une connexion par compte) :
//   mongosh --quiet --nodb --file ~/tp05-securite/scripts/tp3_matrice_droits.js
// Pour chaque compte, le script tente 11 opérations et compare le résultat à la matrice attendue.
// Les écritures de test sont neutres (filtre sur un _id inexistant) sauf « créer commande »,
// dont les documents de test sont supprimés en fin de script.

const HOTE = "127.0.0.1:27017";

// Comptes de LABORATOIRE (en production, jamais de mot de passe en clair dans un script)
const comptes = [
  { user: "admin_secu",   pwd: "Secu-Lab-2026",        authSource: "admin" },
  { user: "dba",          pwd: "Dba-Lab-2026",         authSource: "admin" },
  { user: "app_boutique", pwd: "App-Lab-2026",         authSource: "boutique" },
  { user: "vendeur",      pwd: "Vendeur-Lab-2026",     authSource: "boutique" },
  { user: "marketing",    pwd: "Marketing-Lab-2026",   authSource: "boutique" },
  { user: "supervision",  pwd: "Supervision-Lab-2026", authSource: "admin" },
];

const INEXISTANT = { _id: "__aucun_document__" };
const operations = [
  [ "R-prod", "lire produits",          b => b.produits.findOne() ],
  [ "R-cli",  "lire clients",           b => b.clients.findOne() ],
  [ "R-vue",  "lire clients_anonymes",  b => b.clients_anonymes.findOne() ],
  [ "R-cmd",  "lire commandes",         b => b.commandes.findOne() ],
  [ "C-cmd",  "créer une commande",     (b, u) => b.commandes.insertOne({ _id: "TEST-" + u, test_tp05: true }) ],
  [ "U-cmd",  "modifier une commande",  b => b.commandes.updateOne(INEXISTANT, { $set: { statut: "test" } }) ],
  [ "D-cmd",  "supprimer une commande", b => b.commandes.deleteOne(INEXISTANT) ],
  [ "U-prod", "modifier un produit",    b => b.produits.updateOne(INEXISTANT, { $set: { prix: 0 } }) ],
  [ "Users",  "lister les comptes",     b => b.runCommand({ usersInfo: 1 }) ],
  [ "Status", "serverStatus",           b => b.adminCommand({ serverStatus: 1 }) ],
  [ "Stats",  "dbStats boutique",       b => b.runCommand({ dbStats: 1 }) ],
];

// Matrice attendue : 1 = autorisé, 0 = refusé (même ordre que les opérations)
const attendu = {
  admin_secu:   [0,0,0,0, 0,0,0,0, 1,0,0],
  dba:          [1,1,1,1, 1,1,1,1, 0,1,1],
  app_boutique: [1,1,1,1, 1,1,1,1, 0,0,1],
  vendeur:      [1,0,0,1, 1,1,0,0, 0,0,0],
  marketing:    [1,0,1,1, 0,0,0,0, 0,0,0],
  supervision:  [0,0,0,0, 0,0,0,0, 0,1,1],
};

function essayer(fn, base, user) {
  try {
    const r = fn(base, user);
    if (r && r.ok === 0) return r.codeName === "Unauthorized" ? 0 : "ERR:" + r.errmsg;
    return 1;
  } catch (e) {
    if (e.code === 13 || e.codeName === "Unauthorized") return 0;
    return "ERR:" + e.message;
  }
}

const OK = "✔", NON = "✘";
let conformes = 0, total = 0;
const ecarts = [];

print("\nCompte          " + operations.map(o => o[0].padEnd(7)).join(""));
print("-".repeat(16 + operations.length * 7));

for (const c of comptes) {
  const uri = `mongodb://${encodeURIComponent(c.user)}:${encodeURIComponent(c.pwd)}` +
              `@${HOTE}/?authSource=${c.authSource}`;
  let conn;
  try {
    conn = new Mongo(uri);
    conn.getDB("admin").runCommand({ connectionStatus: 1 });
  } catch (e) {
    print(`${c.user.padEnd(16)}ÉCHEC D'AUTHENTIFICATION : ${e.message}`);
    ecarts.push(`${c.user} : authentification impossible`);
    total += operations.length;
    continue;
  }
  const boutique = conn.getDB("boutique");
  const cellules = operations.map(([code, libelle, fn], i) => {
    const obtenu = essayer(fn, boutique, c.user);
    total++;
    if (obtenu === attendu[c.user][i]) { conformes++; }
    else { ecarts.push(`${c.user} / ${libelle} : obtenu ${obtenu}, attendu ${attendu[c.user][i] ? "autorisé" : "refusé"}`); }
    const symbole = obtenu === 1 ? OK : obtenu === 0 ? NON : "?";
    return (symbole + (obtenu === attendu[c.user][i] ? " " : "!")).padEnd(7);
  });
  print(c.user.padEnd(16) + cellules.join(""));
  conn.close();
}

// Nettoyage des commandes de test (avec le compte dba)
const nettoyage = new Mongo(`mongodb://dba:${encodeURIComponent("Dba-Lab-2026")}@${HOTE}/?authSource=admin`);
const supprimees = nettoyage.getDB("boutique").commandes.deleteMany({ test_tp05: true }).deletedCount;
nettoyage.close();

print(`\nLégende : ${OK} autorisé   ${NON} refusé   ! écart avec la matrice attendue`);
print(`Commandes de test supprimées : ${supprimees}`);
print(`Résultat : ${conformes}/${total} contrôles conformes à la matrice attendue.`);
if (ecarts.length) { print("Écarts :"); ecarts.forEach(e => print("  - " + e)); }
else { print("Tous les droits effectifs correspondent à la politique définie."); }
