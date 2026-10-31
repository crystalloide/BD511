// BD511 – TP chapitre 5 – Étape 1.4 : premier administrateur créé grâce à l'exception localhost
// Lancement : mongosh --quiet "mongodb://127.0.0.1:27017/admin" --file ~/tp05-securite/scripts/tp1_premier_admin.js
// Rôle userAdminAnyDatabase : gère utilisateurs et rôles de toutes les bases, sans accès aux données.

const admin = db.getSiblingDB("admin");

admin.createUser({
  user: "admin_secu",
  pwd: "Secu-Lab-2026",            // en production : pwd: passwordPrompt()
  roles: [ { role: "userAdminAnyDatabase", db: "admin" } ],
  mechanisms: [ "SCRAM-SHA-256" ],
  customData: { fonction: "Administrateur sécurité", cree_par: "exception localhost" }
});

print("OK : utilisateur admin_secu créé dans la base admin.");
print("L'exception localhost est maintenant fermée : la session courante n'est PAS authentifiée.");
