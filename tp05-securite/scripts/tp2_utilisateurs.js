// BD511 – TP chapitre 5 – Étape 2.4 : comptes applicatifs et métiers
// Lancement (en tant qu'admin_secu) :
//   mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u admin_secu --file ~/tp05-securite/scripts/tp2_utilisateurs.js
// Script rejouable : un compte existant est mis à jour (mot de passe et rôles).
// Mots de passe de LABORATOIRE uniquement ; en production : pwd: passwordPrompt() ou coffre-fort de secrets.

function definirUtilisateur(base, nom, motDePasse, roles, description) {
  const cible = db.getSiblingDB(base);
  if (cible.getUser(nom) === null) {
    cible.createUser({ user: nom, pwd: motDePasse, roles: roles,
                       mechanisms: [ "SCRAM-SHA-256" ], customData: { description: description } });
    print(`créé       : ${nom}  (base d'authentification : ${base})`);
  } else {
    cible.updateUser(nom, { pwd: motDePasse, roles: roles,
                            mechanisms: [ "SCRAM-SHA-256" ], customData: { description: description } });
    print(`mis à jour : ${nom}  (base d'authentification : ${base})`);
  }
}

// Comptes métier : créés dans la base boutique => authSource=boutique
definirUtilisateur("boutique", "app_boutique", "App-Lab-2026",
  [ { role: "readWrite", db: "boutique" } ],
  "Compte de l'application web (rôle intégré readWrite)");

definirUtilisateur("boutique", "vendeur", "Vendeur-Lab-2026",
  [ { role: "gestionCommandes", db: "boutique" } ],
  "Service commercial : commandes sans suppression");

definirUtilisateur("boutique", "marketing", "Marketing-Lab-2026",
  [ { role: "analyseMarketing", db: "boutique" } ],
  "Service marketing : données clients pseudonymisées");

// Compte technique : créé dans admin => authSource=admin
definirUtilisateur("admin", "supervision", "Supervision-Lab-2026",
  [ { role: "supervisionLegere", db: "admin" } ],
  "Sonde de supervision (rôle personnalisé, aucune donnée métier)");

print("\nComptes définis sur l'instance (base d'authentification -> utilisateur : rôles) :");
db.getSiblingDB("admin").runCommand({ usersInfo: { forAllDBs: true } }).users
  .sort((a, b) => (a.db + a.user).localeCompare(b.db + b.user))
  .forEach(u => print(`  ${u.db.padEnd(9)} -> ${u.user.padEnd(13)} : ${u.roles.map(r => r.role + "@" + r.db).join(", ")}`));
