# BD511 – Chapitre 5 : Sécurité — Handlab

- **Formation :** BD511 – NoSQL MongoDB : mise en œuvre et administration
- **Travaux pratiques :** activation de l'authentification ; création d'un administrateur, d'utilisateurs et de rôles personnalisés ; tests des droits depuis mongosh et Compass
- **Environnement :** VM stagiaire Ubuntu 24.04 LTS Desktop, MongoDB Community 8.3 installé au chapitre 2, Compass installé sur la VM
- **Durée indicative :** 1 h 15 (préparation 15 min, TP1 15 min, TP2 25 min, TP3 20 min)

---

## Sommaire

- [Présentation](#présentation)
- [Partie 0 – Préparation de l'environnement](#partie-0--préparation-de-lenvironnement)
- [TP1 – Activation de l'authentification](#tp1--activation-de-lauthentification)
- [TP2 – Administrateur, utilisateurs et rôles personnalisés](#tp2--administrateur-utilisateurs-et-rôles-personnalisés)
- [TP3 – Tests des droits depuis mongosh et Compass](#tp3--tests-des-droits-depuis-mongosh-et-compass)
- [Synthèse et passage en production](#synthèse-et-passage-en-production)
- [Annexe A – Noyau HWE 7.0 d'Ubuntu 24.04 et MongoDB 8.3](#annexe-a--noyau-hwe-70-dubuntu-2404-et-mongodb-83)
- [Annexe B – Réinitialiser le TP](#annexe-b--réinitialiser-le-tp)
- [Annexe C – Dépannage](#annexe-c--dépannage)
- [Annexe D – Fichiers du TP et références](#annexe-d--fichiers-du-tp-et-références)

---

## Présentation

### Objectifs

À la fin de ce TP, vous saurez :

1. activer l'authentification d'une instance `mongod` et créer le premier administrateur grâce à l'exception localhost ;
2. séparer les responsabilités entre un administrateur de la sécurité et un administrateur des bases ;
3. créer des utilisateurs et des rôles personnalisés appliquant le principe du moindre privilège, y compris un accès pseudonymisé aux données personnelles via une vue ;
4. vérifier les droits effectifs depuis mongosh, depuis Compass et dans le journal du serveur.

### Versions validées

| Composant | Version | Remarque |
| --- | --- | --- |
| Ubuntu | 24.04 LTS (Desktop) | VM stagiaire, disque unique |
| MongoDB Community Server | **8.3.13** (13 octobre 2026) | dernier correctif de la branche 8.3 retenue pour BD511 |
| mongosh | **2.13.0** (5 octobre 2026) | paquet `mongodb-mongosh` |
| MongoDB Database Tools | **100.19.1** (septembre 2026) | `mongoimport` |
| MongoDB Compass | **1.53.0** (13 octobre 2026) | paquet `.deb` |

> **À savoir :** MongoDB 9.0 est disponible depuis le 29 septembre 2026. Le programme BD511 porte sur la branche 8.x : ce TP reste donc sur la 8.3. Les commandes utilisées (`createUser`, `createRole`, vues, paramètres de sécurité) existent aussi en 9.0, mais le TP n'a pas été rejoué sur cette version.

### Scénario

L'entreprise *Boutique* stocke dans la base `boutique` son catalogue (`produits`), ses clients (`clients`, données personnelles : nom, e-mail, téléphone) et ses commandes (`commandes`). L'instance est aujourd'hui ouverte à quiconque peut se connecter. Vous allez la sécuriser et attribuer à chaque acteur le strict nécessaire.

| Compte | Base d'authentification | Rôle(s) | Mot de passe (labo) | Usage |
| --- | --- | --- | --- | --- |
| `admin_secu` | `admin` | `userAdminAnyDatabase` | `Secu-Lab-2026` | administration des comptes et des rôles, **sans accès aux données** |
| `dba` | `admin` | `dbAdminAnyDatabase`, `readWriteAnyDatabase`, `clusterMonitor` | `Dba-Lab-2026` | exploitation des bases, **sans gestion des comptes** |
| `app_boutique` | `boutique` | `readWrite` (intégré) | `App-Lab-2026` | application web |
| `vendeur` | `boutique` | `gestionCommandes` (personnalisé) | `Vendeur-Lab-2026` | service commercial |
| `marketing` | `boutique` | `analyseMarketing` (personnalisé) | `Marketing-Lab-2026` | service marketing, données clients pseudonymisées |
| `supervision` | `admin` | `supervisionLegere` (personnalisé) | `Supervision-Lab-2026` | sonde de supervision |
| `stagiaire_temp` | `boutique` | temporaire | `Temp-Lab-2026` | démonstration du cycle de vie d'un compte |

Hiérarchie des rôles personnalisés :

```text
analyseMarketing@boutique ──┬── lectureCatalogue@boutique ........ find sur boutique.produits
                            ├── lectureClientsAnonymes@boutique .. find sur boutique.clients_anonymes (vue)
                            └── privilège propre ................. find sur boutique.commandes

gestionCommandes@boutique ──┬── lectureCatalogue@boutique ........ find sur boutique.produits
                            └── privilège propre ................. find, insert, update sur boutique.commandes

supervisionLegere@admin ────── privilèges propres ................ serverStatus (cluster) ; dbStats, collStats (toutes les bases)
```

> **Mots de passe :** ils sont volontairement simples et écrits en clair pour que le TP soit reproductible. En production, on les saisit avec `passwordPrompt()` ou on les lit dans un coffre-fort de secrets, et jamais sur la ligne de commande (`ps`, historique du shell).

### Conventions

- Les blocs `bash` se collent dans un terminal de la VM (utilisateur normal, `sudo` quand c'est indiqué).
- Les blocs `javascript` se collent dans la session **mongosh** ouverte juste avant.
- Quand mongosh affiche `Enter password:`, saisissez le mot de passe du compte (tableau ci-dessus) : rien ne s'affiche à l'écran pendant la frappe, c'est normal.
- ✅ = résultat attendu : succès ; ⛔ = résultat attendu : refus. Les identifiants de session (`lsid`), dates et numéros de connexion affichés varient d'une machine à l'autre.

---

## Partie 0 – Préparation de l'environnement

### 0.1 Vérifier les prérequis

Le TP part de l'état obtenu à la fin du chapitre 2 : MongoDB 8.3 installé depuis le dépôt officiel `repo.mongodb.org`, service `mongod` géré par systemd, Compass installé sur la VM. Vérifiez les versions :

```bash
mongod --version | head -n 1
mongosh --version
mongoimport --version | head -n 1
mongodb-compass --version
```

Si une version est inférieure à celles du tableau *Versions validées*, appliquez l'étape 0.2 ; sinon passez à 0.3.

> Vous rejouez ce TP sur une VM où il a déjà été fait ? Exécutez d'abord l'[annexe B](#annexe-b--réinitialiser-le-tp).

### 0.2 Mettre à jour MongoDB et Compass (si nécessaire)

```bash
sudo apt-get update
sudo apt-get install -y --only-upgrade mongodb-org mongodb-org-database mongodb-org-server \
  mongodb-org-mongos mongodb-org-tools mongodb-mongosh mongodb-database-tools
sudo systemctl restart mongod

cd ~
wget -q https://downloads.mongodb.com/compass/mongodb-compass_1.53.0_amd64.deb
sudo apt install -y ./mongodb-compass_1.53.0_amd64.deb
rm -f mongodb-compass_1.53.0_amd64.deb
```

> La ligne `N: Download is performed unsandboxed as root…` affichée par `apt` lors de l'installation d'un `.deb` local est une simple information. Si les paquets MongoDB ont été figés (`apt-mark hold`) au chapitre 2, libérez-les d'abord avec `sudo apt-mark unhold mongodb-org mongodb-org-database mongodb-org-server mongodb-org-mongos mongodb-org-tools mongodb-mongosh`.

### 0.3 Créer les fichiers du TP

Tous les fichiers sont générés dans `~/tp05-securite` : `conf/` (configurations `mongod`), `donnees/` (jeu de données) et `scripts/`. Collez les blocs suivants dans l'ordre.

**Arborescence :**

```bash
mkdir -p ~/tp05-securite/conf ~/tp05-securite/donnees ~/tp05-securite/scripts
```

**Configurations `mongod`** — trois étapes successives du durcissement, étudiées au TP1 :

```bash
cat > ~/tp05-securite/conf/mongod.conf.0-reference <<'FIN_FICHIER'
# /etc/mongod.conf — BD511 TP chapitre 5 — étape 0 : référence SANS authentification
# YAML : indentation par 2 espaces, jamais de tabulation.

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 127.0.0.1            # écoute locale uniquement (Compass est installé sur la VM)

processManagement:
  timeZoneInfo: /usr/share/zoneinfo
FIN_FICHIER

cat > ~/tp05-securite/conf/mongod.conf.1-authentification <<'FIN_FICHIER'
# /etc/mongod.conf — BD511 TP chapitre 5 — étape 1 : authentification ACTIVÉE
# YAML : indentation par 2 espaces, jamais de tabulation.

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 127.0.0.1            # écoute locale uniquement (Compass est installé sur la VM)

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: enabled       # authentification obligatoire + contrôle d'accès par rôles
  javascriptEnabled: false     # durcissement : pas d'exécution de JavaScript côté serveur

setParameter:
  authenticationMechanisms: SCRAM-SHA-256   # SCRAM-SHA-1 n'est plus accepté
FIN_FICHIER

cat > ~/tp05-securite/conf/mongod.conf.2-production <<'FIN_FICHIER'
# /etc/mongod.conf — BD511 TP chapitre 5 — étape 2 : configuration de PRODUCTION
# YAML : indentation par 2 espaces, jamais de tabulation.

storage:
  dbPath: /var/lib/mongodb

systemLog:
  destination: file
  logAppend: true
  path: /var/log/mongodb/mongod.log

net:
  port: 27017
  bindIp: 127.0.0.1            # écoute locale uniquement (Compass est installé sur la VM)

processManagement:
  timeZoneInfo: /usr/share/zoneinfo

security:
  authorization: enabled       # authentification obligatoire + contrôle d'accès par rôles
  javascriptEnabled: false     # durcissement : pas d'exécution de JavaScript côté serveur

setParameter:
  authenticationMechanisms: SCRAM-SHA-256   # SCRAM-SHA-1 n'est plus accepté
  enableLocalhostAuthBypass: false          # exception localhost fermée définitivement
FIN_FICHIER
```

**Jeu de données** — format JSON étendu (Extended JSON v2), un document par ligne. Les adresses e-mail utilisent le domaine réservé `example.com` et les numéros de téléphone la plage réservée par l'ARCEP aux œuvres de fiction :

```bash
cat > ~/tp05-securite/donnees/produits.json <<'FIN_FICHIER'
{"_id": "P001", "nom": "Clavier mécanique AZERTY", "categorie": "informatique", "prix": {"$numberDecimal": "89.90"}, "stock": 42, "actif": true}
{"_id": "P002", "nom": "Souris sans fil ergonomique", "categorie": "informatique", "prix": {"$numberDecimal": "39.90"}, "stock": 120, "actif": true}
{"_id": "P003", "nom": "Écran 27 pouces QHD", "categorie": "informatique", "prix": {"$numberDecimal": "279.00"}, "stock": 18, "actif": true}
{"_id": "P004", "nom": "Casque audio Bluetooth", "categorie": "audio", "prix": {"$numberDecimal": "129.00"}, "stock": 35, "actif": true}
{"_id": "P005", "nom": "Enceinte portable étanche", "categorie": "audio", "prix": {"$numberDecimal": "59.90"}, "stock": 64, "actif": true}
{"_id": "P006", "nom": "Disque SSD externe 1 To", "categorie": "stockage", "prix": {"$numberDecimal": "99.00"}, "stock": 50, "actif": true}
{"_id": "P007", "nom": "Clé USB-C 128 Go", "categorie": "stockage", "prix": {"$numberDecimal": "19.90"}, "stock": 300, "actif": true}
{"_id": "P008", "nom": "Webcam Full HD", "categorie": "informatique", "prix": {"$numberDecimal": "49.90"}, "stock": 75, "actif": true}
{"_id": "P009", "nom": "Hub USB-C 7 ports", "categorie": "accessoires", "prix": {"$numberDecimal": "34.90"}, "stock": 90, "actif": true}
{"_id": "P010", "nom": "Sacoche ordinateur 15 pouces", "categorie": "accessoires", "prix": {"$numberDecimal": "44.90"}, "stock": 40, "actif": true}
{"_id": "P011", "nom": "Lampe de bureau LED", "categorie": "maison", "prix": {"$numberDecimal": "29.90"}, "stock": 55, "actif": true}
{"_id": "P012", "nom": "Station d'accueil double écran", "categorie": "accessoires", "prix": {"$numberDecimal": "189.00"}, "stock": 0, "actif": false}
FIN_FICHIER

cat > ~/tp05-securite/donnees/clients.json <<'FIN_FICHIER'
{"_id": "C001", "nom": "Martin", "prenom": "Camille", "email": "camille.martin@example.com", "telephone": "+33 6 39 98 10 20", "adresse": {"ville": "Lyon", "code_postal": "69003"}, "segment": "particulier", "date_inscription": {"$date": "2025-03-01T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C002", "nom": "Bernard", "prenom": "Lucas", "email": "lucas.bernard@example.com", "telephone": "+33 6 39 98 17 23", "adresse": {"ville": "Bordeaux", "code_postal": "33000"}, "segment": "particulier", "date_inscription": {"$date": "2025-04-07T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C003", "nom": "Dubois", "prenom": "Léa", "email": "lea.dubois@example.com", "telephone": "+33 6 39 98 24 26", "adresse": {"ville": "Limoges", "code_postal": "87000"}, "segment": "particulier", "date_inscription": {"$date": "2025-05-14T09:00:00Z"}, "consentement_marketing": false}
{"_id": "C004", "nom": "Thomas", "prenom": "Hugo", "email": "hugo.thomas@example.com", "telephone": "+33 6 39 98 31 29", "adresse": {"ville": "Nantes", "code_postal": "44000"}, "segment": "professionnel", "date_inscription": {"$date": "2025-06-20T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C005", "nom": "Robert", "prenom": "Chloé", "email": "chloe.robert@example.com", "telephone": "+33 6 39 98 38 32", "adresse": {"ville": "Lille", "code_postal": "59000"}, "segment": "particulier", "date_inscription": {"$date": "2025-07-27T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C006", "nom": "Richard", "prenom": "Nathan", "email": "nathan.richard@example.com", "telephone": "+33 6 39 98 45 35", "adresse": {"ville": "Toulouse", "code_postal": "31000"}, "segment": "professionnel", "date_inscription": {"$date": "2025-09-02T09:00:00Z"}, "consentement_marketing": false}
{"_id": "C007", "nom": "Petit", "prenom": "Manon", "email": "manon.petit@example.com", "telephone": "+33 6 39 98 52 38", "adresse": {"ville": "Limoges", "code_postal": "87100"}, "segment": "particulier", "date_inscription": {"$date": "2025-10-09T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C008", "nom": "Durand", "prenom": "Louis", "email": "louis.durand@example.com", "telephone": "+33 6 39 98 59 41", "adresse": {"ville": "Rennes", "code_postal": "35000"}, "segment": "particulier", "date_inscription": {"$date": "2025-11-15T09:00:00Z"}, "consentement_marketing": true}
{"_id": "C009", "nom": "Leroy", "prenom": "Inès", "email": "ines.leroy@example.com", "telephone": "+33 6 39 98 66 44", "adresse": {"ville": "Marseille", "code_postal": "13008"}, "segment": "professionnel", "date_inscription": {"$date": "2025-12-22T09:00:00Z"}, "consentement_marketing": false}
{"_id": "C010", "nom": "Moreau", "prenom": "Gabriel", "email": "gabriel.moreau@example.com", "telephone": "+33 6 39 98 73 47", "adresse": {"ville": "Strasbourg", "code_postal": "67000"}, "segment": "particulier", "date_inscription": {"$date": "2026-01-28T09:00:00Z"}, "consentement_marketing": true}
FIN_FICHIER

cat > ~/tp05-securite/donnees/commandes.json <<'FIN_FICHIER'
{"_id": "CMD-2026-0001", "client_id": "C002", "date": {"$date": "2026-09-03T11:46:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P002", "quantite": 1, "prix_unitaire": {"$numberDecimal": "39.90"}}, {"produit_id": "P003", "quantite": 2, "prix_unitaire": {"$numberDecimal": "279.00"}}], "total": {"$numberDecimal": "597.90"}}
{"_id": "CMD-2026-0002", "client_id": "C010", "date": {"$date": "2026-09-05T16:58:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P003", "quantite": 3, "prix_unitaire": {"$numberDecimal": "279.00"}}], "total": {"$numberDecimal": "837.00"}}
{"_id": "CMD-2026-0003", "client_id": "C005", "date": {"$date": "2026-09-07T14:32:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P002", "quantite": 1, "prix_unitaire": {"$numberDecimal": "39.90"}}], "total": {"$numberDecimal": "39.90"}}
{"_id": "CMD-2026-0004", "client_id": "C006", "date": {"$date": "2026-09-09T17:08:00Z"}, "statut": "annulee", "lignes": [{"produit_id": "P003", "quantite": 1, "prix_unitaire": {"$numberDecimal": "279.00"}}], "total": {"$numberDecimal": "279.00"}}
{"_id": "CMD-2026-0005", "client_id": "C010", "date": {"$date": "2026-09-11T12:13:00Z"}, "statut": "expediee", "lignes": [{"produit_id": "P007", "quantite": 3, "prix_unitaire": {"$numberDecimal": "19.90"}}, {"produit_id": "P002", "quantite": 1, "prix_unitaire": {"$numberDecimal": "39.90"}}, {"produit_id": "P010", "quantite": 3, "prix_unitaire": {"$numberDecimal": "44.90"}}], "total": {"$numberDecimal": "234.30"}}
{"_id": "CMD-2026-0006", "client_id": "C004", "date": {"$date": "2026-09-13T11:48:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P009", "quantite": 2, "prix_unitaire": {"$numberDecimal": "34.90"}}, {"produit_id": "P011", "quantite": 3, "prix_unitaire": {"$numberDecimal": "29.90"}}], "total": {"$numberDecimal": "159.50"}}
{"_id": "CMD-2026-0007", "client_id": "C008", "date": {"$date": "2026-09-15T13:00:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P003", "quantite": 2, "prix_unitaire": {"$numberDecimal": "279.00"}}, {"produit_id": "P002", "quantite": 1, "prix_unitaire": {"$numberDecimal": "39.90"}}], "total": {"$numberDecimal": "597.90"}}
{"_id": "CMD-2026-0008", "client_id": "C001", "date": {"$date": "2026-09-17T09:33:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P008", "quantite": 1, "prix_unitaire": {"$numberDecimal": "49.90"}}, {"produit_id": "P001", "quantite": 3, "prix_unitaire": {"$numberDecimal": "89.90"}}], "total": {"$numberDecimal": "319.60"}}
{"_id": "CMD-2026-0009", "client_id": "C009", "date": {"$date": "2026-09-19T15:38:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P001", "quantite": 1, "prix_unitaire": {"$numberDecimal": "89.90"}}], "total": {"$numberDecimal": "89.90"}}
{"_id": "CMD-2026-0010", "client_id": "C007", "date": {"$date": "2026-09-21T08:32:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P003", "quantite": 3, "prix_unitaire": {"$numberDecimal": "279.00"}}], "total": {"$numberDecimal": "837.00"}}
{"_id": "CMD-2026-0011", "client_id": "C003", "date": {"$date": "2026-09-23T11:54:00Z"}, "statut": "expediee", "lignes": [{"produit_id": "P001", "quantite": 2, "prix_unitaire": {"$numberDecimal": "89.90"}}, {"produit_id": "P011", "quantite": 1, "prix_unitaire": {"$numberDecimal": "29.90"}}, {"produit_id": "P003", "quantite": 3, "prix_unitaire": {"$numberDecimal": "279.00"}}], "total": {"$numberDecimal": "1046.70"}}
{"_id": "CMD-2026-0012", "client_id": "C008", "date": {"$date": "2026-09-25T16:26:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P009", "quantite": 2, "prix_unitaire": {"$numberDecimal": "34.90"}}, {"produit_id": "P001", "quantite": 1, "prix_unitaire": {"$numberDecimal": "89.90"}}], "total": {"$numberDecimal": "159.70"}}
{"_id": "CMD-2026-0013", "client_id": "C010", "date": {"$date": "2026-09-27T08:31:00Z"}, "statut": "expediee", "lignes": [{"produit_id": "P007", "quantite": 2, "prix_unitaire": {"$numberDecimal": "19.90"}}, {"produit_id": "P001", "quantite": 2, "prix_unitaire": {"$numberDecimal": "89.90"}}, {"produit_id": "P008", "quantite": 3, "prix_unitaire": {"$numberDecimal": "49.90"}}], "total": {"$numberDecimal": "369.30"}}
{"_id": "CMD-2026-0014", "client_id": "C004", "date": {"$date": "2026-09-29T11:59:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P010", "quantite": 2, "prix_unitaire": {"$numberDecimal": "44.90"}}, {"produit_id": "P004", "quantite": 3, "prix_unitaire": {"$numberDecimal": "129.00"}}, {"produit_id": "P008", "quantite": 3, "prix_unitaire": {"$numberDecimal": "49.90"}}], "total": {"$numberDecimal": "626.50"}}
{"_id": "CMD-2026-0015", "client_id": "C002", "date": {"$date": "2026-10-01T16:27:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P010", "quantite": 1, "prix_unitaire": {"$numberDecimal": "44.90"}}, {"produit_id": "P001", "quantite": 2, "prix_unitaire": {"$numberDecimal": "89.90"}}], "total": {"$numberDecimal": "224.70"}}
{"_id": "CMD-2026-0016", "client_id": "C009", "date": {"$date": "2026-10-03T14:32:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P002", "quantite": 1, "prix_unitaire": {"$numberDecimal": "39.90"}}], "total": {"$numberDecimal": "39.90"}}
{"_id": "CMD-2026-0017", "client_id": "C006", "date": {"$date": "2026-10-05T17:09:00Z"}, "statut": "en_preparation", "lignes": [{"produit_id": "P011", "quantite": 1, "prix_unitaire": {"$numberDecimal": "29.90"}}, {"produit_id": "P008", "quantite": 2, "prix_unitaire": {"$numberDecimal": "49.90"}}, {"produit_id": "P004", "quantite": 2, "prix_unitaire": {"$numberDecimal": "129.00"}}], "total": {"$numberDecimal": "387.70"}}
{"_id": "CMD-2026-0018", "client_id": "C001", "date": {"$date": "2026-10-07T13:58:00Z"}, "statut": "expediee", "lignes": [{"produit_id": "P002", "quantite": 3, "prix_unitaire": {"$numberDecimal": "39.90"}}, {"produit_id": "P011", "quantite": 1, "prix_unitaire": {"$numberDecimal": "29.90"}}], "total": {"$numberDecimal": "149.60"}}
{"_id": "CMD-2026-0019", "client_id": "C007", "date": {"$date": "2026-10-09T12:43:00Z"}, "statut": "annulee", "lignes": [{"produit_id": "P009", "quantite": 2, "prix_unitaire": {"$numberDecimal": "34.90"}}], "total": {"$numberDecimal": "69.80"}}
{"_id": "CMD-2026-0020", "client_id": "C004", "date": {"$date": "2026-10-11T09:29:00Z"}, "statut": "livree", "lignes": [{"produit_id": "P001", "quantite": 1, "prix_unitaire": {"$numberDecimal": "89.90"}}, {"produit_id": "P011", "quantite": 2, "prix_unitaire": {"$numberDecimal": "29.90"}}, {"produit_id": "P010", "quantite": 2, "prix_unitaire": {"$numberDecimal": "44.90"}}], "total": {"$numberDecimal": "239.50"}}
FIN_FICHIER
```

**Scripts système** — contrôle des réglages de production et attente du démarrage de `mongod` :

```bash
cat > ~/tp05-securite/scripts/00_prepa_systeme.sh <<'FIN_FICHIER'
#!/usr/bin/env bash
# BD511 – TP chapitre 5 – Étape 0.4 : contrôle et application des réglages système de production
# Cible : Ubuntu 24.04 LTS + MongoDB 8.3 Community installé depuis le dépôt officiel (chapitre 2).
# Idempotent : peut être relancé sans risque.
# Usage : sudo bash ~/tp05-securite/scripts/00_prepa_systeme.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Lancer ce script avec sudo." >&2; exit 1; fi

ERREURS=0
REDEMARRER=0
ok()   { printf '  [OK]    %s\n' "$*"; }
corr() { printf '  [CORR]  %s\n' "$*"; }
info() { printf '  [INFO]  %s\n' "$*"; }
ko()   { printf '  [KO]    %s\n' "$*"; ERREURS=$((ERREURS + 1)); }
version_de() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true; }

echo "1. Plate-forme"
# shellcheck source=/dev/null
. /etc/os-release
if [[ ${VERSION_ID:-} == "24.04" ]]; then ok "$PRETTY_NAME"; else info "$PRETTY_NAME (handlab validé sur Ubuntu 24.04)"; fi
if grep -qw avx /proc/cpuinfo; then ok "jeu d'instructions AVX disponible"
else ko "AVX absent : l'activer dans l'hyperviseur (exigé par MongoDB depuis la 5.0)"; fi

echo "2. Binaires MongoDB"
for b in mongod mongosh mongoimport; do
  if command -v "$b" > /dev/null; then ok "$b $(version_de "$b")"
  else ko "$b introuvable : refaire le TP du chapitre 2"; fi
done

echo "3. Noyau Linux et allocateur TCMalloc de MongoDB 8.x (SERVER-121912)"
NOYAU=$(uname -r)
IFS='.-' read -r MAJ MIN PAT _ <<< "$NOYAU"
PAT=${PAT%%[!0-9]*}
VNUM=$(( MAJ * 1000000 + MIN * 1000 + ${PAT:-0} ))
DROPIN=/etc/systemd/system/mongod.service.d/10-noyau-rseq.conf
if (( VNUM >= 6019000 && VNUM <= 7000013 )); then
  info "noyau $NOYAU : MongoDB 8.3 refuse de démarrer avec ses caches TCMalloc par CPU (voir annexe A)"
  if [[ -f $DROPIN ]]; then
    ok "contournement déjà en place : $DROPIN"
  else
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<'EOF'
# BD511 – noyau 6.19 à 7.0.13 (dont le noyau HWE 7.0 d'Ubuntu 24.04) : voir annexe A du handlab.
# glibc conserve rseq, TCMalloc passe en caches par thread : mongod peut démarrer.
[Service]
Environment="GLIBC_TUNABLES=glibc.pthread.rseq=1"
EOF
    systemctl daemon-reload
    REDEMARRER=1
    corr "contournement appliqué : $DROPIN"
  fi
else
  ok "noyau $NOYAU compatible avec les caches TCMalloc par CPU"
  if [[ -f $DROPIN ]]; then
    rm -f "$DROPIN"; systemctl daemon-reload; REDEMARRER=1
    corr "contournement retiré (inutile avec ce noyau) : caches par CPU réactivés"
  fi
fi

echo "4. Transparent Huge Pages (recommandation MongoDB 8.x : activées)"
THP=/sys/kernel/mm/transparent_hugepage
UNITE_THP=/etc/systemd/system/enable-transparent-huge-pages.service
etat_thp() { echo "$(cat $THP/enabled)|$(cat $THP/defrag)|$(cat $THP/khugepaged/max_ptes_none)|$(cat /proc/sys/vm/overcommit_memory)"; }
AVANT=$(etat_thp)
cat > "$UNITE_THP" <<'EOF'
[Unit]
Description=Enable Transparent Hugepages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo always | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null && echo defer+madvise | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null && echo 0 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none > /dev/null && echo 1 | tee /proc/sys/vm/overcommit_memory > /dev/null'
RemainAfterExit=true

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --quiet enable-transparent-huge-pages.service
systemctl restart enable-transparent-huge-pages.service
APRES=$(etat_thp)
if [[ $APRES == *"[always]"*"[defer+madvise]"*"|0|1" ]]; then ok "THP enabled=always, defrag=defer+madvise, max_ptes_none=0, overcommit_memory=1"
else ko "valeurs THP inattendues : $APRES"; fi
if [[ $AVANT != "$APRES" ]]; then REDEMARRER=1; corr "réglages THP modifiés (service activé au démarrage)"; fi

echo "5. Paramètres noyau (sysctl)"
SYSCTL=/etc/sysctl.d/90-mongodb.conf
cat > "$SYSCTL" <<'EOF'
# BD511 – paramètres noyau recommandés pour MongoDB (Production Notes)
# Swap uniquement en dernier recours
vm.swappiness = 1
# Au moins 2 x le nombre maximal de connexions entrantes
vm.max_map_count = 1048576
# NUMA : pas de récupération de mémoire par zone
vm.zone_reclaim_mode = 0
# Détection plus rapide des connexions mortes
net.ipv4.tcp_keepalive_time = 120
EOF
sysctl -q -p "$SYSCTL"
ok "swappiness=$(sysctl -n vm.swappiness), max_map_count=$(sysctl -n vm.max_map_count), tcp_keepalive_time=$(sysctl -n net.ipv4.tcp_keepalive_time)"

echo "6. Limites ulimit du service mongod (fixées par l'unité systemd du paquet)"
NOFILE=$(systemctl show mongod -p LimitNOFILE --value)
NPROC=$(systemctl show mongod -p LimitNPROC --value)
if [[ $NOFILE =~ ^[0-9]+$ && $NOFILE -ge 64000 && $NPROC =~ ^[0-9]+$ && $NPROC -ge 64000 ]]; then
  ok "LimitNOFILE=$NOFILE, LimitNPROC=$NPROC"
else ko "LimitNOFILE=$NOFILE, LimitNPROC=$NPROC (64000 minimum attendu)"; fi

echo "7. Synchronisation horaire"
if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == "yes" ]]; then ok "horloge synchronisée (NTP)"
else info "horloge non synchronisée : sans impact pour ce TP, indispensable en production (replica set)"; fi

echo "8. Stockage du dbPath (/var/lib/mongodb)"
FS=$(findmnt -n -o FSTYPE --target /var/lib/mongodb || true)
OPTS=$(findmnt -n -o OPTIONS --target /var/lib/mongodb || true)
if [[ $FS == "xfs" ]]; then ok "système de fichiers XFS"
else info "système de fichiers $FS : MongoDB émettra l'avertissement « XFS strongly recommended » (attendu sur la VM à disque unique)"; fi
if [[ $OPTS == *noatime* ]]; then ok "montage noatime"; else info "montage sans noatime ($OPTS) : en production, monter le volume de données en noatime"; fi

echo "9. Service mongod"
systemctl enable --quiet mongod
if [[ $REDEMARRER -eq 1 ]] || ! systemctl is-active --quiet mongod; then
  if systemctl restart mongod; then corr "mongod (re)démarré"; else ko "échec du démarrage de mongod"; fi
fi
for _ in $(seq 1 60); do
  if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then break; fi
  sleep 1
done
if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then
  ok "mongod $(version_de mongod) répond sur 127.0.0.1:27017"
else
  ko "mongod ne répond pas : voir « sudo journalctl -u mongod -n 30 » et /var/log/mongodb/mongod.log"
fi

echo
if [[ $ERREURS -gt 0 ]]; then echo "BILAN : $ERREURS point(s) bloquant(s) à corriger avant de poursuivre."; exit 1; fi
echo "BILAN : environnement prêt pour le TP."
FIN_FICHIER

cat > ~/tp05-securite/scripts/attendre_mongod.sh <<'FIN_FICHIER'
#!/usr/bin/env bash
# BD511 – TP chapitre 5 – attend que mongod réponde sur 127.0.0.1:27017 (60 s maximum)
# Usage : bash ~/tp05-securite/scripts/attendre_mongod.sh
for _ in $(seq 1 60); do
  if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then
    echo "mongod prêt."
    exit 0
  fi
  sleep 1
done
echo "ÉCHEC : mongod ne répond pas après 60 s." >&2
echo "Diagnostic : sudo systemctl status mongod --no-pager ; sudo tail -n 20 /var/log/mongodb/mongod.log" >&2
exit 1
FIN_FICHIER
```

**Contrôle :** comparez le nombre de lignes de chaque fichier avec le tableau ; un écart signale un copier-coller incomplet (recréez alors le fichier concerné).

```bash
cd ~/tp05-securite && wc -l conf/* donnees/* scripts/*
```

| Fichier | Lignes attendues |
| --- | ---: |
| `conf/mongod.conf.0-reference` | 17 |
| `conf/mongod.conf.1-authentification` | 24 |
| `conf/mongod.conf.2-production` | 25 |
| `donnees/clients.json` | 10 |
| `donnees/commandes.json` | 20 |
| `donnees/produits.json` | 12 |
| `scripts/00_prepa_systeme.sh` | 140 |
| `scripts/attendre_mongod.sh` | 13 |
| **total** | **261** |

### 0.4 Appliquer les réglages système de production

Le script `00_prepa_systeme.sh` contrôle et, si besoin, corrige les réglages recommandés par les *Production Notes* de MongoDB 8.3. Il est rejouable sans risque.

```bash
sudo bash ~/tp05-securite/scripts/00_prepa_systeme.sh
```

| Réglage | Valeur appliquée | Pourquoi |
| --- | --- | --- |
| Compatibilité noyau / TCMalloc | contournement automatique si le noyau est entre 6.19 et 7.0.13 | MongoDB 8.3 refuse de démarrer sur ces noyaux, dont le noyau HWE 7.0 d'Ubuntu 24.04 Desktop ([annexe A](#annexe-a--noyau-hwe-70-dubuntu-2404-et-mongodb-83)) |
| Transparent Huge Pages | `enabled=always`, `defrag=defer+madvise`, `max_ptes_none=0`, `vm.overcommit_memory=1` | recommandation **inversée depuis MongoDB 8.0** : le nouvel allocateur TCMalloc tire parti des THP ; service systemd `enable-transparent-huge-pages` lancé avant `mongod` |
| `vm.swappiness` | `1` | le swap ne sert qu'à éviter l'OOM killer |
| `vm.max_map_count` | `1048576` | au moins deux fois le nombre maximal de connexions |
| `vm.zone_reclaim_mode` | `0` | neutralise la récupération mémoire par zone NUMA |
| `net.ipv4.tcp_keepalive_time` | `120` | détection rapide des connexions coupées |
| `ulimit` (unité systemd du paquet) | `LimitNOFILE=64000`, `LimitNPROC=64000` | vérification seulement |
| NTP, XFS, `noatime` | contrôle informatif | indispensables en production ; la VM à disque unique reste en ext4 |

Résultat attendu (ligne 3 : `[OK]` ou `[CORR]` selon le noyau ; lignes `[INFO]` selon la VM) :

```text
1. Plate-forme
  [OK]    Ubuntu 24.04.x LTS
  [OK]    jeu d'instructions AVX disponible
2. Binaires MongoDB
  [OK]    mongod 8.3.13
  [OK]    mongosh 2.13.0
  [OK]    mongoimport 100.19.1
3. Noyau Linux et allocateur TCMalloc de MongoDB 8.x (SERVER-121912)
  [OK]    noyau 6.8.0-xx-generic compatible avec les caches TCMalloc par CPU
4. Transparent Huge Pages (recommandation MongoDB 8.x : activées)
  [OK]    THP enabled=always, defrag=defer+madvise, max_ptes_none=0, overcommit_memory=1
  [CORR]  réglages THP modifiés (service activé au démarrage)
5. Paramètres noyau (sysctl)
  [OK]    swappiness=1, max_map_count=1048576, tcp_keepalive_time=120
6. Limites ulimit du service mongod (fixées par l'unité systemd du paquet)
  [OK]    LimitNOFILE=64000, LimitNPROC=64000
7. Synchronisation horaire
  [OK]    horloge synchronisée (NTP)
8. Stockage du dbPath (/var/lib/mongodb)
  [INFO]  système de fichiers ext4 : MongoDB émettra l'avertissement « XFS strongly recommended » (attendu sur la VM à disque unique)
  [INFO]  montage sans noatime (rw,relatime) : en production, monter le volume de données en noatime
9. Service mongod
  [CORR]  mongod (re)démarré
  [OK]    mongod 8.3.13 répond sur 127.0.0.1:27017

BILAN : environnement prêt pour le TP.
```

> Avec le noyau HWE 7.0, la section 3 affiche `[INFO] noyau 7.0.0-xx-generic : MongoDB 8.3 refuse de démarrer…` suivi de `[CORR] contournement appliqué`. Le TP se déroule ensuite normalement.

### 0.5 Installer la configuration de référence et importer les données

La configuration d'origine est sauvegardée une seule fois, puis remplacée par la configuration de référence (sans authentification). `install` fixe en une commande le propriétaire et les droits du fichier (`644` : `mongod`, qui tourne sous le compte `mongodb`, doit pouvoir le lire ; il ne contient aucun secret).

```bash
[ -f /etc/mongod.conf.avant-tp05 ] || sudo cp /etc/mongod.conf /etc/mongod.conf.avant-tp05
sudo install -o root -g root -m 644 ~/tp05-securite/conf/mongod.conf.0-reference /etc/mongod.conf
sudo systemctl restart mongod && bash ~/tp05-securite/scripts/attendre_mongod.sh
```

Import des trois collections (l'option `--drop` rend l'import rejouable) :

```bash
cd ~/tp05-securite/donnees
for c in produits clients commandes; do
  mongoimport --uri "mongodb://127.0.0.1:27017/boutique" --collection "$c" --drop --file "$c.json"
done
mongosh --quiet "mongodb://127.0.0.1:27017/boutique" --eval '
  db.getCollectionNames().sort().forEach(c => print(c.padEnd(10), db[c].countDocuments()))'
```

✅ Chaque import se termine par `… document(s) imported successfully. 0 document(s) failed to import.` puis :

```text
clients    10
commandes  20
produits   12
```

### 0.6 Constat : une instance ouverte

Sans authentification, **n'importe quel processus de la machine** lit les données personnelles :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/boutique" --eval '
  printjson(db.clients.findOne({ _id: "C001" }, { nom: 1, email: 1, telephone: 1 }))'
```

```text
{
  _id: 'C001',
  nom: 'Martin',
  email: 'camille.martin@example.com',
  telephone: '+33 6 39 98 10 20'
}
```

Le serveur le signale lui-même dans ses avertissements de démarrage :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin" --eval '
  db.adminCommand({ getLog: "startupWarnings" }).log.forEach(l => { const e = JSON.parse(l); print(e.id, "-", e.msg) })'
```

```text
22297 - Using the XFS filesystem is strongly recommended with the WiredTiger storage engine. See http://dochub.mongodb.org/core/prodnotes-filesystem
22120 - Access control is not enabled for the database. Read and write access to data and configuration is unrestricted
```

L'exposition réseau est déjà limitée par `net.bindIp: 127.0.0.1` : `mongod` n'écoute que sur l'interface locale.

```bash
sudo ss -ltnp | grep 27017
```

```text
LISTEN 0      4096       127.0.0.1:27017      0.0.0.0:*    users:(("mongod",pid=…,fd=…))
```

> **Question :** pourquoi `bindIp` ne suffit-il pas à protéger les données ? *(Réponse : tout utilisateur ou processus local — y compris un service web compromis — reste libre de tout lire, modifier ou supprimer.)*

---

## TP1 – Activation de l'authentification

### 1.1 Lire la configuration cible

```bash
diff ~/tp05-securite/conf/mongod.conf.0-reference ~/tp05-securite/conf/mongod.conf.1-authentification
```

```text
1c1
< # /etc/mongod.conf — BD511 TP chapitre 5 — étape 0 : référence SANS authentification
---
> # /etc/mongod.conf — BD511 TP chapitre 5 — étape 1 : authentification ACTIVÉE
17a18,24
>
> security:
>   authorization: enabled       # authentification obligatoire + contrôle d'accès par rôles
>   javascriptEnabled: false     # durcissement : pas d'exécution de JavaScript côté serveur
>
> setParameter:
>   authenticationMechanisms: SCRAM-SHA-256   # SCRAM-SHA-1 n'est plus accepté
```

| Paramètre | Effet |
| --- | --- |
| `security.authorization: enabled` | toute opération exige un utilisateur authentifié disposant du privilège correspondant (RBAC) |
| `security.javascriptEnabled: false` | désactive l'exécution de JavaScript côté serveur (`$where`, `$function`, `$accumulator`, `mapReduce`) : recommandation de la *Security Checklist* quand l'application n'en a pas besoin ; mongosh, lui, reste un client JavaScript |
| `authenticationMechanisms: SCRAM-SHA-256` | seul le mécanisme SCRAM-SHA-256 (PBKDF2 / SHA-256) est accepté |

### 1.2 Activer l'authentification

```bash
sudo install -o root -g root -m 644 ~/tp05-securite/conf/mongod.conf.1-authentification /etc/mongod.conf
sudo systemctl restart mongod && bash ~/tp05-securite/scripts/attendre_mongod.sh
sudo grep -o '"security":{[^}]*}' /var/log/mongodb/mongod.log | tail -n 1
```

✅ La dernière ligne montre les options lues au démarrage :

```text
"security":{"authorization":"enabled","javascriptEnabled":false}
```

### 1.3 Constater le refus des accès anonymes

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/boutique" --eval 'db.produits.countDocuments()'
mongosh --quiet "mongodb://127.0.0.1:27017/boutique" --eval 'db.adminCommand({ listDatabases: 1 }).databases'
mongosh --quiet "mongodb://127.0.0.1:27017/boutique" --eval 'db.runCommand({ ping: 1 })'
```

```text
MongoServerError: not authorized on boutique to execute command { aggregate: "produits", … }   ⛔
[]                                                                                           ⛔ aucune base visible
{ ok: 1 }                                                                                    ✅ ping reste autorisé
```

> La connexion TCP est acceptée, mais chaque commande est filtrée. `listDatabases` ne renvoie pas d'erreur : il ne liste que les bases sur lesquelles l'appelant a des droits… ici aucune. `ping` (comme `hello`) reste accessible pour les sondes et les drivers.

### 1.4 Créer le premier administrateur grâce à l'exception localhost

Aucun utilisateur n'existe encore : MongoDB ouvre alors l'**exception localhost**. Une connexion **depuis l'interface locale** peut créer **le premier utilisateur (ou le premier rôle)** de l'instance, et rien d'autre. Ce premier compte doit pouvoir créer les suivants : rôle `userAdminAnyDatabase`, dans la base `admin`.

Créez le script :

```bash
cat > ~/tp05-securite/scripts/tp1_premier_admin.js <<'FIN_FICHIER'
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
FIN_FICHIER
```

Exécutez-le **sans vous authentifier**, depuis la VM :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin" --file ~/tp05-securite/scripts/tp1_premier_admin.js
```

```text
OK : utilisateur admin_secu créé dans la base admin.
L'exception localhost est maintenant fermée : la session courante n'est PAS authentifiée.
```

> `mechanisms: ["SCRAM-SHA-256"]` ne stocke que les clés SCRAM-SHA-256, cohérent avec `authenticationMechanisms`. Le mot de passe n'est jamais conservé en clair : le serveur garde un sel et des clés dérivées (TP2.5).

### 1.5 Vérifier que l'exception est fermée

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin" --eval '
  db.createUser({ user: "intrus", pwd: "Intrus-Lab-2026", roles: [ "root" ] })'
```

```text
MongoServerError: Command createUser requires authentication   ⛔
```

### 1.6 Première connexion authentifiée

```bash
mongosh "mongodb://127.0.0.1:27017/admin" -u admin_secu
```

Mot de passe : `Secu-Lab-2026`. Dans la session mongosh :

```javascript
db.runCommand({ connectionStatus: 1 }).authInfo
show users
db.getSiblingDB("boutique").produits.findOne()
exit
```

- ✅ `authInfo` montre `admin_secu@admin` et le rôle `userAdminAnyDatabase`.
- ✅ `show users` liste le compte, ses rôles et `mechanisms: [ 'SCRAM-SHA-256' ]`.
- ⛔ `findOne` échoue : `MongoServerError[Unauthorized]: not authorized on boutique to execute command { find: "produits", … }`.

> **Séparation des tâches :** l'administrateur de la sécurité gère les comptes mais ne lit pas les données. Attention, `userAdminAnyDatabase` peut s'attribuer n'importe quel rôle : ce compte doit être aussi protégé qu'un compte `root`.

### 1.7 Fermer définitivement l'exception localhost (configuration de production)

L'exception se referme dès qu'un utilisateur existe, mais elle se rouvrirait si tous les comptes étaient supprimés. En production, on la désactive explicitement :

```bash
diff ~/tp05-securite/conf/mongod.conf.1-authentification ~/tp05-securite/conf/mongod.conf.2-production
sudo install -o root -g root -m 644 ~/tp05-securite/conf/mongod.conf.2-production /etc/mongod.conf
sudo systemctl restart mongod && bash ~/tp05-securite/scripts/attendre_mongod.sh
sudo grep -o '"setParameter":{[^}]*}' /var/log/mongodb/mongod.log | tail -n 1
```

```text
…
>   enableLocalhostAuthBypass: false          # exception localhost fermée définitivement
mongod prêt.
"setParameter":{"authenticationMechanisms":"SCRAM-SHA-256","enableLocalhostAuthBypass":"false"}
```

Contrôlez les mécanismes acceptés (mot de passe `Secu-Lab-2026` à chaque fois) :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin?authMechanism=SCRAM-SHA-1" -u admin_secu --eval 'db.runCommand({ ping: 1 })'
mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u admin_secu --eval 'db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUsers'
```

```text
MongoServerError: Received authentication for mechanism SCRAM-SHA-1 which is not enabled   ⛔
[ { user: 'admin_secu', db: 'admin' } ]                                                     ✅
```

> **Attention :** avec `enableLocalhostAuthBypass: false`, perdre le mot de passe du dernier administrateur impose de redémarrer `mongod` sans `security.authorization` (arrêt de service). Gardez toujours au moins deux comptes d'administration et leurs mots de passe dans un coffre-fort.

---

## TP2 – Administrateur, utilisateurs et rôles personnalisés

### 2.1 Créer l'administrateur des bases (`dba`)

```bash
mongosh "mongodb://127.0.0.1:27017/admin" -u admin_secu
```

Mot de passe : `Secu-Lab-2026`.

```javascript
use admin
db.createUser({
  user: "dba",
  pwd: "Dba-Lab-2026",
  roles: [
    { role: "dbAdminAnyDatabase",   db: "admin" },
    { role: "readWriteAnyDatabase", db: "admin" },
    { role: "clusterMonitor",       db: "admin" }
  ],
  mechanisms: [ "SCRAM-SHA-256" ]
})
show users
exit
```

✅ `{ ok: 1 }`, puis `show users` liste `admin_secu` et `dba`.

| Rôle intégré | Ce qu'il donne à `dba` |
| --- | --- |
| `dbAdminAnyDatabase` | administration des bases (index, statistiques, profiler, `collMod`, suppression) sauf `local` et `config` |
| `readWriteAnyDatabase` | lecture/écriture des données de toutes les bases sauf `local` et `config` |
| `clusterMonitor` | supervision en lecture seule (`serverStatus`, `getParameter`, `getCmdLineOpts`, `currentOp`…) |

### 2.2 Créer une vue pseudonymisée (en tant que `dba`)

Le service marketing doit analyser les clients **sans** voir leurs nom, e-mail et téléphone. MongoDB Community ne filtre pas les champs par rôle : on crée une **vue** qui ne projette que les champs autorisés, puis on donne des droits sur la vue seulement.

```bash
mongosh "mongodb://127.0.0.1:27017/admin" -u dba
```

Mot de passe : `Dba-Lab-2026`.

```javascript
use boutique
db.produits.countDocuments()
db.createView(
  "clients_anonymes",
  "clients",
  [ { $project: { _id: 1, segment: 1, "adresse.ville": 1, date_inscription: 1, consentement_marketing: 1 } } ]
)
db.clients_anonymes.find().limit(2)
db.createUser({ user: "pirate", pwd: "Pirate-Lab-2026", roles: [ "root" ] })
exit
```

- À la connexion, mongosh affiche les avertissements de démarrage du serveur : `dba` y a droit (action `getLog` de `clusterMonitor`), contrairement à `admin_secu`.
- ✅ `12` produits : `dba` lit les données.
- ✅ `{ ok: 1 }` : la vue est créée ; ses documents ne contiennent que `_id`, `adresse.ville`, `segment`, `date_inscription`, `consentement_marketing`.
- ⛔ `createUser` : `MongoServerError[Unauthorized]: not authorized on boutique to execute command { createUser: "pirate", pwd: "xxx", … }` — `dba` ne gère pas les comptes (et le mot de passe est masqué dans le message).

> La projection est une **liste blanche** (`champ: 1`) : un champ ajouté plus tard à `clients` n'apparaîtra pas dans la vue par accident.

### 2.3 Créer les rôles personnalisés

Un rôle personnalisé associe des **privilèges** (une *ressource* + des *actions*) et peut **hériter** d'autres rôles. Il est défini dans une base : un rôle de `boutique` ne peut porter que sur `boutique` ; un rôle qui vise la ressource `cluster` ou toutes les bases se définit dans `admin`.

Créez le script :

```bash
cat > ~/tp05-securite/scripts/tp2_roles.js <<'FIN_FICHIER'
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
FIN_FICHIER
```

Exécutez-le en tant qu'`admin_secu` (mot de passe `Secu-Lab-2026`) :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u admin_secu --file ~/tp05-securite/scripts/tp2_roles.js
```

```text
créé       : lectureCatalogue@boutique
créé       : gestionCommandes@boutique
créé       : lectureClientsAnonymes@boutique
créé       : analyseMarketing@boutique
créé       : supervisionLegere@admin

Rôles personnalisés (rôle@base -> rôles hérités) :
  analyseMarketing@boutique        -> lectureCatalogue, lectureClientsAnonymes
  gestionCommandes@boutique        -> lectureCatalogue
  lectureCatalogue@boutique        -> aucun
  lectureClientsAnonymes@boutique  -> aucun
  supervisionLegere@admin          -> aucun
```

Inspectez les privilèges **effectifs** (propres + hérités) :

```bash
mongosh "mongodb://127.0.0.1:27017/admin" -u admin_secu
```

```javascript
use boutique
db.getRole("gestionCommandes", { showPrivileges: true }).inheritedPrivileges
db.getRole("analyseMarketing", { showPrivileges: true }).inheritedRoles
db.getSiblingDB("admin").getRole("supervisionLegere", { showPrivileges: true }).privileges
exit
```

✅ `gestionCommandes` cumule `find, insert, update` sur `commandes` et `find` sur `produits` (hérité) — **pas de `remove`**.

### 2.4 Créer les comptes applicatifs et métiers

Les comptes métier sont créés **dans la base `boutique`** : c'est leur *base d'authentification* (`authSource=boutique`). Le compte technique `supervision` est créé dans `admin`. Tous les comptes, quelle que soit leur base, sont stockés dans la collection `admin.system.users`.

Créez le script :

```bash
cat > ~/tp05-securite/scripts/tp2_utilisateurs.js <<'FIN_FICHIER'
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
FIN_FICHIER
```

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u admin_secu --file ~/tp05-securite/scripts/tp2_utilisateurs.js
```

```text
créé       : app_boutique  (base d'authentification : boutique)
créé       : vendeur  (base d'authentification : boutique)
créé       : marketing  (base d'authentification : boutique)
créé       : supervision  (base d'authentification : admin)

Comptes définis sur l'instance (base d'authentification -> utilisateur : rôles) :
  admin     -> admin_secu    : userAdminAnyDatabase@admin
  admin     -> dba           : clusterMonitor@admin, dbAdminAnyDatabase@admin, readWriteAnyDatabase@admin
  admin     -> supervision   : supervisionLegere@admin
  boutique  -> app_boutique  : readWrite@boutique
  boutique  -> marketing     : analyseMarketing@boutique
  boutique  -> vendeur       : gestionCommandes@boutique
```

> Les scripts `tp2_roles.js` et `tp2_utilisateurs.js` sont **rejouables** : relancés, ils affichent `mis à jour` au lieu de `créé`.

### 2.5 Gérer le cycle de vie d'un compte

```bash
mongosh "mongodb://127.0.0.1:27017/admin" -u admin_secu
```

Collez les commandes **une à une** pour observer chaque résultat :

```javascript
use boutique
db.createUser({
  user: "stagiaire_temp",
  pwd: "Temp-Lab-2026",
  roles: [ { role: "lectureCatalogue", db: "boutique" } ],
  mechanisms: [ "SCRAM-SHA-256" ]
})
db.updateUser("stagiaire_temp", { customData: { fin_de_mission: "2026-12-31" } })
db.grantRolesToUser("stagiaire_temp", [ { role: "lectureClientsAnonymes", db: "boutique" } ])
db.revokeRolesFromUser("stagiaire_temp", [ { role: "lectureCatalogue", db: "boutique" } ])
db.getUser("stagiaire_temp")
db.changeUserPassword("stagiaire_temp", "Temp-Lab-2026-bis")
db.getSiblingDB("admin").system.users.find(
  { user: "stagiaire_temp" },
  { user: 1, db: 1, "credentials.SCRAM-SHA-256.iterationCount": 1, "credentials.SCRAM-SHA-256.salt": 1 }
)
db.dropUser("stagiaire_temp")
db.getUser("stagiaire_temp")
exit
```

| Commande | Résultat attendu |
| --- | --- |
| `createUser`, `updateUser`, `grantRolesToUser`, `revokeRolesFromUser`, `changeUserPassword`, `dropUser` | ✅ `{ ok: 1 }` |
| `getUser` | ✅ `roles: [ { role: 'lectureClientsAnonymes', db: 'boutique' } ]` et `customData: { fin_de_mission: '2026-12-31' }` |
| lecture de `admin.system.users` | ✅ `_id: 'boutique.stagiaire_temp'`, `iterationCount: 15000` et un `salt` : seules des clés dérivées sont stockées |
| dernier `getUser` | ✅ `null` : le compte n'existe plus |

> `updateUser` **remplace** la liste des rôles quand on lui passe `roles` ; `grantRolesToUser` / `revokeRolesFromUser` l'ajustent. Pour un départ de collaborateur, supprimer le compte suffit : ses sessions déjà ouvertes perdent immédiatement leurs droits (`Command … requires authentication`).

---

## TP3 – Tests des droits depuis mongosh et Compass

### 3.1 La base d'authentification (`authSource`)

`vendeur` est défini dans `boutique`. Sans précision, mongosh s'authentifie sur `admin`… où ce compte n'existe pas. Mot de passe : `Vendeur-Lab-2026`.

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/" -u vendeur --eval 'db.getName()'
mongosh --quiet "mongodb://127.0.0.1:27017/?authSource=boutique" -u vendeur --eval 'db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUsers'
```

```text
MongoServerError: Authentication failed.             ⛔
[ { user: 'vendeur', db: 'boutique' } ]               ✅
```

> Quand l'URI contient un nom de base (`mongodb://hôte/boutique`), cette base devient la base d'authentification par défaut : c'est ce qu'utilisent les sessions suivantes. Le message client reste volontairement vague ; la cause exacte figure dans le journal du serveur (3.5).

### 3.2 Tester les droits du vendeur

```bash
mongosh "mongodb://127.0.0.1:27017/boutique" -u vendeur
```

Mot de passe : `Vendeur-Lab-2026`. Collez les commandes une à une :

```javascript
db.runCommand({ connectionStatus: 1, showPrivileges: true }).authInfo.authenticatedUserPrivileges
show collections
db.getCollectionInfos({}, { nameOnly: true, authorizedCollections: true }).map(c => c.name)
db.produits.find({ categorie: "audio" }, { _id: 0, nom: 1, prix: 1 })
db.commandes.insertOne({
  _id: "CMD-2026-0021",
  client_id: "C003",
  date: new Date(),
  statut: "en_preparation",
  lignes: [ { produit_id: "P007", quantite: 2, prix_unitaire: NumberDecimal("19.90") } ],
  total: NumberDecimal("39.80")
})
db.commandes.updateOne({ _id: "CMD-2026-0021" }, { $set: { statut: "expediee" } })
db.commandes.deleteOne({ _id: "CMD-2026-0021" })
db.clients.findOne()
db.produits.updateOne({ _id: "P007" }, { $set: { prix: NumberDecimal("9.90") } })
exit
```

| Opération | Attendu | Explication |
| --- | --- | --- |
| `connectionStatus` | ✅ | privilèges effectifs : `find, insert, update` sur `commandes`, `find` sur `produits` |
| `show collections` | ⛔ | mongosh envoie `listCollections` avec `authorizedCollections: false`, ce qui exige l'action `listCollections` |
| `getCollectionInfos(…, { authorizedCollections: true })` | ✅ | `commandes` et `produits` seulement (l'ordre peut varier) |
| lecture des produits | ✅ | `Casque audio Bluetooth` et `Enceinte portable étanche` |
| `insertOne`, `updateOne` sur `commandes` | ✅ | `insertedId: 'CMD-2026-0021'`, puis `modifiedCount: 1` |
| `deleteOne` sur `commandes` | ⛔ | pas d'action `remove` dans `gestionCommandes` |
| lecture de `clients` | ⛔ | aucun privilège sur les données personnelles |
| modification d'un produit | ⛔ | `lectureCatalogue` ne donne que `find` |

La commande `CMD-2026-0021` reste donc en base : vous la supprimerez avec un compte habilité en 3.6.

### 3.3 Tester les droits du marketing

```bash
mongosh "mongodb://127.0.0.1:27017/boutique" -u marketing
```

Mot de passe : `Marketing-Lab-2026`.

```javascript
db.getCollectionInfos({}, { nameOnly: true, authorizedCollections: true }).map(c => c.name)
db.clients_anonymes.find({ "adresse.ville": "Limoges" })
db.clients.find({ "adresse.ville": "Limoges" })
db.commandes.aggregate([
  { $group: { _id: "$client_id", ca: { $sum: "$total" } } },
  { $lookup: { from: "clients", localField: "_id", foreignField: "_id", as: "client" } }
])
db.commandes.aggregate([
  { $match: { statut: { $ne: "annulee" } } },
  { $group: { _id: "$client_id", ca: { $sum: "$total" } } },
  { $lookup: { from: "clients_anonymes", localField: "_id", foreignField: "_id", as: "client" } },
  { $project: { ca: 1, ville: { $first: "$client.adresse.ville" }, segment: { $first: "$client.segment" } } },
  { $sort: { ca: -1 } },
  { $limit: 3 }
])
db.commandes.updateOne({ _id: "CMD-2026-0001" }, { $set: { statut: "annulee" } })
exit
```

| Opération | Attendu | Explication |
| --- | --- | --- |
| collections autorisées | ✅ | `commandes`, `produits`, `clients_anonymes` (l'ordre peut varier) — pas de `clients` |
| lecture de la vue | ✅ | `C003` et `C007` (Limoges) **sans** nom, e-mail ni téléphone |
| lecture de `clients` | ⛔ | droit sur la vue seulement, pas sur sa collection source |
| `$lookup` vers `clients` | ⛔ | les privilèges sont contrôlés sur **toutes** les collections lues par le pipeline |
| `$lookup` vers `clients_anonymes` | ✅ | chiffre d'affaires par client, avec ville et segment uniquement |
| modification d'une commande | ⛔ | `analyseMarketing` est en lecture seule |

Résultat attendu du second `aggregate` :

```text
[
  { _id: 'C010', ca: Decimal128('1440.60'), ville: 'Strasbourg', segment: 'particulier' },
  { _id: 'C003', ca: Decimal128('1086.50'), ville: 'Limoges', segment: 'particulier' },
  { _id: 'C004', ca: Decimal128('1025.50'), ville: 'Nantes', segment: 'professionnel' }
]
```

> Interroger une vue ne demande que le privilège `find` **sur la vue**. C'est ce qui permet d'exposer un sous-ensemble de champs sans ouvrir la collection source.

### 3.4 Contrôler toute la politique : matrice des droits

Le script suivant se connecte successivement avec chaque compte, tente onze opérations et compare chaque résultat à la matrice attendue. Les écritures sont neutres (filtre sur un `_id` inexistant), sauf la création de commande dont les documents de test sont supprimés à la fin.

Créez le script :

```bash
cat > ~/tp05-securite/scripts/tp3_matrice_droits.js <<'FIN_FICHIER'
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
FIN_FICHIER
```

```bash
mongosh --quiet --nodb --file ~/tp05-securite/scripts/tp3_matrice_droits.js
```

```text
Compte          R-prod R-cli  R-vue  R-cmd  C-cmd  U-cmd  D-cmd  U-prod Users  Status Stats
---------------------------------------------------------------------------------------------
admin_secu      ✘      ✘      ✘      ✘      ✘      ✘      ✘      ✘      ✔      ✘      ✘
dba             ✔      ✔      ✔      ✔      ✔      ✔      ✔      ✔      ✘      ✔      ✔
app_boutique    ✔      ✔      ✔      ✔      ✔      ✔      ✔      ✔      ✘      ✘      ✔
vendeur         ✔      ✘      ✘      ✔      ✔      ✔      ✘      ✘      ✘      ✘      ✘
marketing       ✔      ✘      ✔      ✔      ✘      ✘      ✘      ✘      ✘      ✘      ✘
supervision     ✘      ✘      ✘      ✘      ✘      ✘      ✘      ✘      ✘      ✔      ✔

Légende : ✔ autorisé   ✘ refusé   ! écart avec la matrice attendue
Commandes de test supprimées : 3
Résultat : 66/66 contrôles conformes à la matrice attendue.
Tous les droits effectifs correspondent à la politique définie.
```

Questions :

1. Pourquoi `app_boutique` (rôle `readWrite`) lit-il `clients` **et** la vue, alors que `marketing` ne lit que la vue ? *(`readWrite` donne `find` sur toutes les collections non système de la base, vues comprises.)*
2. Pourquoi `dba` ne peut-il pas lister les comptes ? *(L'action `viewUser` appartient aux rôles `userAdmin*`, pas à `dbAdmin*`.)*
3. Que faudrait-il ajouter pour que `supervision` alimente l'exporteur Prometheus du chapitre 8 ? *(Le rôle intégré `clusterMonitor`, qui couvre aussi `replSetGetStatus`, `top`, `getLog`…)*

> Gardez ce script : relancé après chaque modification de rôle, il sert de **test de non-régression** de la politique de sécurité.

### 3.5 Lire les traces d'authentification dans le journal

Chaque authentification réussie (id `5286306`) ou échouée (id `5286307`) est journalisée par le composant `ACCESS`. Créez le script d'extraction :

```bash
cat > ~/tp05-securite/scripts/tp3_journal_auth.py <<'FIN_FICHIER'
#!/usr/bin/env python3
# BD511 – TP chapitre 5 – Étape 3.5 : synthèse des authentifications du journal mongod
# Usage : sudo python3 ~/tp05-securite/scripts/tp3_journal_auth.py [--echecs] [nombre_de_lignes]
#   --echecs : n'affiche que les authentifications refusées
# Seules les entrées du composant ACCESS « Successfully authenticated » (id 5286306)
# et « Failed to authenticate » (id 5286307) du journal JSON sont prises en compte.
# [spéculative] : tentative faite dès le « hello » initial du driver ; en cas d'échec, le driver
# recommence de façon explicite, d'où deux lignes pour une même tentative refusée.
import json, sys

JOURNAL = "/var/log/mongodb/mongod.log"
args = sys.argv[1:]
echecs_seuls = "--echecs" in args
nombres = [a for a in args if a.isdigit()]
NB = int(nombres[0]) if nombres else 15

succes, echecs, lignes = 0, 0, []
with open(JOURNAL, encoding="utf-8", errors="replace") as f:
    for brut in f:
        if '"c":"ACCESS"' not in brut:
            continue
        try:
            e = json.loads(brut)
        except ValueError:
            continue
        if e.get("id") not in (5286306, 5286307):
            continue
        reussi = e["id"] == 5286306
        succes, echecs = succes + reussi, echecs + (not reussi)
        if echecs_seuls and reussi:
            continue
        a = e.get("attr", {})
        quand = e["t"]["$date"][:19].replace("T", " ")
        lignes.append(f"{quand}  {'SUCCÈS' if reussi else 'ÉCHEC '}  {(a.get('user') or '—'):<13} "
                      f"db={a.get('db', '?'):<9} {a.get('mechanism', '?'):<14} "
                      f"{a.get('client', '?'):<16} {'[spéculative] ' if a.get('isSpeculative') else ''}"
                      f"{a.get('error', '')}")

print(f"Journal : {succes} authentification(s) réussie(s), {echecs} refusée(s). "
      f"{min(NB, len(lignes))} dernière(s) ligne(s){' (échecs uniquement)' if echecs_seuls else ''} :")
print("\n".join(lignes[-NB:]))
FIN_FICHIER
```

```bash
sudo python3 ~/tp05-securite/scripts/tp3_journal_auth.py --echecs
```

```text
Journal : … authentification(s) réussie(s), 4 refusée(s). 4 dernière(s) ligne(s) (échecs uniquement) :
2026-10-23 10:52:41  ÉCHEC   —             db=admin     SCRAM-SHA-1    127.0.0.1:50556  [spéculative] MechanismUnavailable: Received authentication for mechanism SCRAM-SHA-1 which is not enabled
2026-10-23 10:52:41  ÉCHEC   —             db=admin     SCRAM-SHA-1    127.0.0.1:50556  MechanismUnavailable: Received authentication for mechanism SCRAM-SHA-1 which is not enabled
2026-10-23 11:01:07  ÉCHEC   vendeur       db=admin     SCRAM-SHA-256  127.0.0.1:47214  [spéculative] UserNotFound: Could not find user "vendeur" for db "admin"
2026-10-23 11:01:07  ÉCHEC   vendeur       db=admin     SCRAM-SHA-256  127.0.0.1:47214  UserNotFound: Could not find user "vendeur" for db "admin"
```

Le client ne reçoit que `Authentication failed.` ; le serveur, lui, enregistre la cause (`UserNotFound`, `MechanismUnavailable`), le mécanisme et l'adresse du client. Chaque tentative refusée apparaît deux fois : les drivers tentent d'abord une authentification *spéculative* dès le `hello` initial (économie d'un aller-retour), puis recommencent de façon explicite. Pour le refus SCRAM-SHA-1, le nom d'utilisateur n'a même pas été lu (`—`). Sans l'option `--echecs`, le script affiche aussi les succès (`sudo python3 ~/tp05-securite/scripts/tp3_journal_auth.py 20`) : une session mongosh ouvre plusieurs connexions, d'où plusieurs lignes par session.

> En production, ces événements sont envoyés à un SIEM ; une rafale d'échecs depuis une même adresse doit déclencher une alerte. Le journal d'audit détaillé (`auditLog`) est réservé à l'édition Enterprise.

### 3.6 Tester les droits depuis Compass

Lancez Compass depuis le menu des applications ou avec la commande `mongodb-compass &`. Créez **trois connexions**, une par profil :

1. Dans la barre latérale **Connections**, cliquez sur **Add New Connection** (ou sur l'icône « + »).
2. **URI** : `mongodb://127.0.0.1:27017/` ; **Name** : `TP5 – dba` (puis `TP5 – vendeur`, `TP5 – marketing`).
3. Ouvrez **Advanced Connection Options** → onglet **Authentication** → **Username / Password** :

| Connexion | Username | Password | Authentication Database | Authentication Mechanism |
| --- | --- | --- | --- | --- |
| TP5 – dba | `dba` | `Dba-Lab-2026` | `admin` | SCRAM-SHA-256 |
| TP5 – vendeur | `vendeur` | `Vendeur-Lab-2026` | `boutique` | SCRAM-SHA-256 |
| TP5 – marketing | `marketing` | `Marketing-Lab-2026` | `boutique` | SCRAM-SHA-256 |

4. Cliquez sur **Save & Connect** (ou **Connect**). Observez que l'URI affichée en haut du formulaire contient désormais `authSource=…` et `authMechanism=SCRAM-SHA-256`, sans le mot de passe.

Manipulations et résultats attendus :

| Profil | Manipulation dans Compass | Attendu |
| --- | --- | --- |
| vendeur | consulter la liste des bases et des collections | ✅ seule `boutique` apparaît, avec `commandes` et `produits` |
| vendeur | `commandes` → filtre `{ _id: "CMD-2026-0021" }` → **Find**, puis modifier `statut` en `livree` → **Update** | ✅ document mis à jour |
| vendeur | sur ce même document : icône corbeille → **Delete** | ⛔ message d'erreur contenant `not authorized on boutique to execute command { delete: "commandes"…` |
| vendeur | `produits` → modifier un prix | ⛔ refus `update` |
| marketing | liste des collections | ✅ `clients_anonymes` (marquée comme vue), `commandes`, `produits` ; pas de `clients` |
| marketing | `clients_anonymes` → onglet **Schema** → **Analyze** | ✅ aucun champ `nom`, `email` ou `telephone` |
| marketing | `commandes` → **ADD DATA** → **Insert document** | ⛔ refus `insert` |
| dba | liste des bases | ✅ toutes les bases de l'instance |
| dba | `boutique.commandes` → document `CMD-2026-0021` → **Delete** | ✅ la commande de test est supprimée (nettoyage) |
| dba | onglet **Mongosh** (en bas de la fenêtre) : `db.getUsers()` | ⛔ refus `usersInfo` : `dba` ne gère pas les comptes |

> **Ne pas enregistrer les mots de passe** sur un poste partagé : Compass les conserve dans le trousseau du système. Pour un poste d'administration, préférez une connexion sans mot de passe enregistré ou une authentification par certificat x.509.

Si vous n'avez pas fait la suppression dans Compass, nettoyez en ligne de commande (mot de passe `Dba-Lab-2026`) :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/boutique?authSource=admin" -u dba --eval 'db.commandes.deleteOne({ _id: "CMD-2026-0021" })'
```

✅ `deletedCount: 1` (ou `0` si la commande a déjà été supprimée dans Compass).

---

## Synthèse et passage en production

### Ce qui a été mis en place

| Mesure | Mise en œuvre dans le TP |
| --- | --- |
| Authentification obligatoire | `security.authorization: enabled` |
| Mécanisme d'authentification robuste | `authenticationMechanisms: SCRAM-SHA-256`, comptes créés avec `mechanisms: ["SCRAM-SHA-256"]` |
| Premier administrateur sans fenêtre d'exposition | exception localhost, puis `enableLocalhostAuthBypass: false` |
| Séparation des tâches | `admin_secu` (comptes) ≠ `dba` (bases) ≠ comptes métier |
| Moindre privilège | rôles personnalisés par collection et par action, héritage de rôles |
| Protection des données personnelles | vue `clients_anonymes` en liste blanche + droits sur la vue seulement |
| Réduction de la surface d'attaque | `bindIp: 127.0.0.1`, `javascriptEnabled: false` |
| Contrôle continu | matrice de non-régression, journal `ACCESS` |
| Socle système | THP, `swappiness`, `max_map_count`, `ulimit`, compatibilité noyau |

### À compléter en production

| Point | Recommandation |
| --- | --- |
| Écoute réseau | `bindIp` limité à `127.0.0.1` + l'adresse privée de l'interface applicative ; jamais `0.0.0.0` sans pare-feu |
| Pare-feu | `ufw default deny incoming`, puis `ufw allow from <sous-réseau applicatif> to any port 27017 proto tcp` (et l'accès d'administration SSH) |
| Chiffrement en transit | `net.tls.mode: requireTLS` avec des certificats d'une autorité interne ; certificats x.509 pour l'authentification interne des replica sets (chapitre 6) |
| Secrets | mots de passe longs et générés, stockés dans un coffre-fort (Vault, gestionnaire de secrets cloud), rotation planifiée |
| Comptes nominatifs | un compte par administrateur (traçabilité), comptes de service distincts par application |
| Audit et chiffrement au repos | journal d'audit et moteur de stockage chiffré : édition Enterprise ; chiffrement côté client (CSFLE, Queryable Encryption) pour les champs les plus sensibles |
| Revue des droits | rejouer régulièrement la matrice de droits ; supprimer les comptes inutilisés |

### Pour la suite de la formation

L'instance reste sécurisée. Pour administrer, connectez-vous avec `dba` ; pour créer un compte (par exemple l'utilisateur `clusterMonitor` de l'exporteur Prometheus au chapitre 8), connectez-vous avec `admin_secu`.

---

## Annexe A – Noyau HWE 7.0 d'Ubuntu 24.04 et MongoDB 8.3

**Symptôme :** `mongod` s'arrête aussitôt démarré et `/var/log/mongodb/mongod.log` contient :

```text
MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility with this version of MongoDB. See https://jira.mongodb.org/browse/SERVER-121912 for more information.
```

**Cause :** les noyaux 6.19 à 7.0.13 sont incompatibles avec les caches *par CPU* de l'allocateur TCMalloc intégré à MongoDB 8.x ; `mongod` détecte ces versions et refuse de démarrer. Ubuntu Desktop 24.04 suit la pile matérielle HWE, passée au noyau 7.0 (versions `7.0.0-xx-generic`) avec Ubuntu 24.04.5. Comme Ubuntu affiche toujours `7.0.0` quel que soit le correctif amont intégré, l'exemption prévue par MongoDB pour les noyaux 7.0.14 et ultérieurs ne s'applique pas (ticket SERVER-136848, encore ouvert ; correctif SERVER-131779 annoncé pour MongoDB 8.3.14). Les caches par CPU ne sont actifs que si la variable `GLIBC_TUNABLES=glibc.pthread.rseq=0` est définie, ce que fait l'unité systemd du paquet.

```bash
uname -r
systemctl cat mongod | grep GLIBC_TUNABLES
```

**Contournement appliqué par `00_prepa_systeme.sh` (VM de TP) :** un fichier complémentaire d'unité systemd redéfinit la variable. glibc conserve alors l'enregistrement *rseq* et TCMalloc fonctionne en caches par thread, comme avant MongoDB 8.0. `mongod` démarre ; seule l'optimisation mémoire apportée par la 8.x est perdue.

```bash
cat /etc/systemd/system/mongod.service.d/10-noyau-rseq.conf
mongosh --quiet "mongodb://127.0.0.1:27017/admin" -u dba --eval 'db.serverStatus({ tcmalloc: 1 }).tcmalloc.usingPerCPUCaches'
```

`false` avec le contournement, `true` avec un noyau compatible (mot de passe `Dba-Lab-2026`).

**Solution de production :** utiliser le noyau GA d'Ubuntu 24.04 (6.8), noyau par défaut d'Ubuntu Server et noyau de référence de la plate-forme supportée. Sur une VM Desktop, on peut le rendre prioritaire dans GRUB à l'aide des identifiants d'entrée, indépendants de la langue du système (procédure à valider d'abord sur une VM de test) :

```bash
sudo apt-get install -y linux-generic
sudo update-grub
GA=$(ls /boot/vmlinuz-6.8.0-*-generic | sort -V | tail -n 1 | sed 's|/boot/vmlinuz-||')
SOUS_MENU=$(sudo grep -oP "menuentry_id_option '\Kgnulinux-advanced-[^']+" /boot/grub/grub.cfg | head -n 1)
ENTREE=$(sudo grep -oP "menuentry_id_option '\Kgnulinux-${GA}-advanced-[^']+" /boot/grub/grub.cfg | head -n 1)
echo "GRUB_DEFAULT=\"${SOUS_MENU}>${ENTREE}\""
```

Si les deux identifiants sont bien renseignés, appliquez puis redémarrez, **dans le même terminal** (les variables `SOUS_MENU` et `ENTREE` sont réutilisées) :

```bash
sudo sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${SOUS_MENU}>${ENTREE}\"|" /etc/default/grub
sudo update-grub
sudo reboot
```

Après redémarrage, `uname -r` affiche `6.8.0-xx-generic` ; relancez `sudo bash ~/tp05-securite/scripts/00_prepa_systeme.sh` : il retire le contournement et réactive les caches par CPU. Après une future mise à jour de MongoDB intégrant la correction pour les noyaux Ubuntu, réévaluez ce choix.

---

## Annexe B – Réinitialiser le TP

Ce script remet l'instance dans l'état « avant TP » : configuration sans authentification, suppression des comptes et rôles créés par le TP, puis de la base `boutique`. Les autres comptes éventuels ne sont pas touchés (s'il en reste, l'exception localhost ne sera pas disponible au TP1).

```bash
cat > ~/tp05-securite/scripts/zz_reinitialiser_tp05.sh <<'FIN_FICHIER'
#!/usr/bin/env bash
# BD511 – TP chapitre 5 – Annexe B : remise de l'instance dans l'état « avant TP »
#  - configuration de référence SANS authentification ;
#  - suppression des comptes et rôles créés par le TP, puis de la base boutique.
# Les autres comptes éventuels de l'instance ne sont pas touchés.
# Usage : bash ~/tp05-securite/scripts/zz_reinitialiser_tp05.sh   (sudo sera demandé)
set -euo pipefail
DIR_TP="$(cd "$(dirname "$0")/.." && pwd)"

sudo install -o root -g root -m 644 "$DIR_TP/conf/mongod.conf.0-reference" /etc/mongod.conf
sudo systemctl restart mongod
for _ in $(seq 1 60); do
  mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1 && break
  sleep 1
done

mongosh --quiet "mongodb://127.0.0.1:27017/admin" --eval '
  const admin = db.getSiblingDB("admin");
  for (const u of ["admin_secu", "dba", "supervision"]) {
    if (admin.getUser(u) !== null) { admin.dropUser(u); print("compte supprimé : " + u + "@admin"); }
  }
  if (admin.getRole("supervisionLegere") !== null) { admin.dropRole("supervisionLegere"); print("rôle supprimé : supervisionLegere@admin"); }
  const boutique = db.getSiblingDB("boutique");
  print("comptes supprimés dans boutique : " + boutique.runCommand({ dropAllUsersFromDatabase: 1 }).n);
  print("rôles supprimés dans boutique   : " + boutique.runCommand({ dropAllRolesFromDatabase: 1 }).n);
  boutique.dropDatabase();
  print("base boutique supprimée");
  const restants = admin.runCommand({ usersInfo: { forAllDBs: true } }).users.length;
  print(restants === 0
    ? "Aucun compte restant : l\u2019exception localhost sera disponible au TP1."
    : restants + " compte(s) d\u2019autres TP subsiste(nt) : l\u2019exception localhost ne sera PAS disponible.");
'
echo "Réinitialisation terminée : reprendre le TP à l'étape 0.5."
FIN_FICHIER
```

```bash
bash ~/tp05-securite/scripts/zz_reinitialiser_tp05.sh
```

```text
compte supprimé : admin_secu@admin
compte supprimé : dba@admin
compte supprimé : supervision@admin
rôle supprimé : supervisionLegere@admin
comptes supprimés dans boutique : 3
rôles supprimés dans boutique   : 4
base boutique supprimée
Aucun compte restant : l’exception localhost sera disponible au TP1.
Réinitialisation terminée : reprendre le TP à l'étape 0.5.
```

Pour revenir à la configuration d'avant le TP : `sudo cp /etc/mongod.conf.avant-tp05 /etc/mongod.conf && sudo systemctl restart mongod`.

---

## Annexe C – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `mongod prêt.` n'apparaît pas, `ÉCHEC : mongod ne répond pas` | erreur dans `/etc/mongod.conf` (tabulation, indentation YAML) ou noyau incompatible | `sudo systemctl status mongod --no-pager` ; `sudo tail -n 20 /var/log/mongodb/mongod.log` ; réinstaller le fichier de `~/tp05-securite/conf` ; [annexe A](#annexe-a--noyau-hwe-70-dubuntu-2404-et-mongodb-83) |
| `MongoServerError: Authentication failed.` | mauvais mot de passe, ou mauvaise base d'authentification | vérifier le tableau des comptes ; ajouter `?authSource=boutique` ou `?authSource=admin` |
| `Command createUser requires authentication` à l'étape 1.4 | un utilisateur existe déjà (TP déjà joué, autre chapitre) | [annexe B](#annexe-b--réinitialiser-le-tp) |
| `Received authentication for mechanism SCRAM-SHA-1 which is not enabled` | client forcé en SCRAM-SHA-1 | utiliser `authMechanism=SCRAM-SHA-256` ou le mécanisme par défaut |
| `not authorized on … to execute command` | comportement attendu : le rôle n'a pas l'action requise | comparer avec la matrice de 3.4 |
| `show collections` refusé | l'utilisateur n'a pas l'action `listCollections` | `db.getCollectionInfos({}, { nameOnly: true, authorizedCollections: true })` |
| `NamespaceExists` en 2.2 | la vue existe déjà (étape rejouée) | aucune action |
| Compass n'affiche aucune collection | base d'authentification erronée ou mot de passe enregistré obsolète | modifier la connexion : **Authentication Database** = `boutique` pour `vendeur` et `marketing` |
| `mongoimport` : `Failed: (Unauthorized) Command drop requires authentication` | import tenté après l'activation de l'authentification | importer avec le compte `dba` en ajoutant `--username dba --authenticationDatabase admin` (mot de passe demandé), ou réinitialiser (annexe B) |

---

## Annexe D – Fichiers du TP et références

| Fichier | Rôle | Créé à l'étape |
| --- | --- | --- |
| `conf/mongod.conf.0-reference` | configuration de référence sans authentification | 0.3 |
| `conf/mongod.conf.1-authentification` | authentification activée, SCRAM-SHA-256, JavaScript serveur désactivé | 0.3 |
| `conf/mongod.conf.2-production` | idem + exception localhost désactivée | 0.3 |
| `donnees/produits.json`, `clients.json`, `commandes.json` | jeu de données `boutique` (12, 10 et 20 documents) | 0.3 |
| `scripts/00_prepa_systeme.sh` | contrôle et application des réglages système de production | 0.3 |
| `scripts/attendre_mongod.sh` | attente du démarrage de `mongod` | 0.3 |
| `scripts/tp1_premier_admin.js` | premier administrateur via l'exception localhost | 1.4 |
| `scripts/tp2_roles.js` | rôles personnalisés (rejouable) | 2.3 |
| `scripts/tp2_utilisateurs.js` | comptes applicatifs et métiers (rejouable) | 2.4 |
| `scripts/tp3_matrice_droits.js` | matrice de non-régression des droits | 3.4 |
| `scripts/tp3_journal_auth.py` | synthèse des authentifications du journal | 3.5 |
| `scripts/zz_reinitialiser_tp05.sh` | réinitialisation du TP | annexe B |

Fichiers système modifiés : `/etc/mongod.conf` (sauvegarde `/etc/mongod.conf.avant-tp05`), `/etc/systemd/system/enable-transparent-huge-pages.service`, `/etc/sysctl.d/90-mongodb.conf` et, selon le noyau, `/etc/systemd/system/mongod.service.d/10-noyau-rseq.conf`.

**Références (documentation officielle MongoDB) :**

- Release Notes for MongoDB 8.3 : https://www.mongodb.com/docs/manual/release-notes/8.3/
- Production Notes (8.3) : https://www.mongodb.com/docs/v8.3/administration/production-notes/
- TCMalloc Performance Optimization (THP, rseq) : https://www.mongodb.com/docs/v8.3/administration/tcmalloc-performance/
- Localhost Exception : https://www.mongodb.com/docs/v8.3/core/localhost-exception/
- Built-In Roles : https://www.mongodb.com/docs/manual/reference/built-in-roles/
- Security Checklist : https://www.mongodb.com/docs/manual/administration/security-checklist/
- Compass – installation : https://www.mongodb.com/docs/compass/install/
- Compass – authentification : https://www.mongodb.com/docs/compass/current/connect/advanced-connection-options/authentication-connection/
- SERVER-121912 (noyaux 6.19+) : https://jira.mongodb.org/browse/SERVER-121912
- SERVER-136848 (versions de noyau Ubuntu) : https://jira.mongodb.org/browse/SERVER-136848
