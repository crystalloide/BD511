// BD511 – TP chapitre 5 – Étape 2.3 : rôles personnalisés (principe du moindre privilège)
// Lancement (en tant qu'admin_secu) :
//   mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u admin_secu --file ~/tp05-securite/scripts/tp2_roles.js
// Script rejouable : un rôle existant est mis à jour au lieu d'être recréé.

function definirRole(base, nom, privileges, rolesHerites) {
  const cible = db.getSiblingDB(base);
  if (cible.getRole(nom) === null) {
    cible.createRole({ role: nom, privileges: privileges, roles: rolesHerites });
    print(`créé       : ${nom}@${base}`);
  } else {
    cible.updateRole(nom, { privileges: privileges, roles: rolesHerites });
    print(`mis à jour : ${nom}@${base}`);
  }
}

// 1. Lecture du seul catalogue produits
definirRole("boutique", "lectureCatalogue",
  [ { resource: { db: "boutique", collection: "produits" }, actions: [ "find" ] } ],
  []);

// 2. Gestion des commandes : lecture, création, modification — mais PAS de suppression.
//    Hérite de lectureCatalogue (un vendeur doit voir les produits).
definirRole("boutique", "gestionCommandes",
  [ { resource: { db: "boutique", collection: "commandes" }, actions: [ "find", "insert", "update" ] } ],
  [ { role: "lectureCatalogue", db: "boutique" } ]);

// 3. Lecture de la vue pseudonymisée des clients (aucun droit sur la collection clients)
definirRole("boutique", "lectureClientsAnonymes",
  [ { resource: { db: "boutique", collection: "clients_anonymes" }, actions: [ "find" ] } ],
  []);

// 4. Analyse marketing : composition de rôles + lecture des commandes
definirRole("boutique", "analyseMarketing",
  [ { resource: { db: "boutique", collection: "commandes" }, actions: [ "find" ] } ],
  [ { role: "lectureCatalogue", db: "boutique" }, { role: "lectureClientsAnonymes", db: "boutique" } ]);

// 5. Supervision légère (rôle défini dans admin car il porte sur la ressource « cluster »)
//    - serverStatus : métriques de l'instance (ressource cluster)
//    - dbStats / collStats : volumétrie de toutes les bases (db: "" et collection: "" = toutes)
definirRole("admin", "supervisionLegere",
  [ { resource: { cluster: true }, actions: [ "serverStatus" ] },
    { resource: { db: "", collection: "" }, actions: [ "dbStats", "collStats" ] } ],
  []);

print("\nRôles personnalisés (rôle@base -> rôles hérités) :");
for (const base of [ "boutique", "admin" ]) {
  db.getSiblingDB(base).runCommand({ rolesInfo: 1 }).roles
    .sort((a, b) => a.role.localeCompare(b.role))
    .forEach(r => print(`  ${(r.role + "@" + base).padEnd(32)} -> ${r.roles.map(x => x.role).sort().join(", ") || "aucun"}`));
}
