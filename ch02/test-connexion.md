# `test-connexion.js` — explications

**Module BD511 · Chapitre 2 · Informations de connexion après l'installation**

## En bref

Ce fichier n'est pas un script bash mais un script **JavaScript** exécuté par **`mongosh`**, le shell de MongoDB. Une fois connecté au serveur, il interroge MongoDB avec plusieurs commandes d'administration et affiche une fiche récapitulative : versions, noyau, processus, stockage, réseau, connexions, bases et avertissements.

```bash
mongosh --quiet --file ~/bd511/ch02/test-connexion.js
```

- sans adresse précisée, `mongosh` se connecte au serveur local par défaut (`mongodb://127.0.0.1:27017`) ;
- `--quiet` supprime le message d'accueil de `mongosh` ;
- `--file` exécute le script puis rend la main au terminal.

Pas besoin de `sudo` : le script ne fait que lire des informations par le réseau local.

> Dans `mongosh`, la variable `db` désigne la **base courante** (`test` par défaut). Une **commande d'administration** s'envoie avec `runCommand({ nomDeLaCommande: 1 })` et renvoie un document JSON.

---

## Explication instruction par instruction

### 1. Commentaires d'en-tête

```javascript
// test-connexion.js - BD511 ch.2 : informations de connexion après installation
// Usage : mongosh --quiet --file ~/bd511/ch02/test-connexion.js
```

En JavaScript, `//` commence un commentaire, ignoré à l'exécution.

### 2. Collecte des informations

Chaque ligne range un résultat dans une **constante** (`const`), c'est-à-dire une variable dont on ne changera pas la valeur.

```javascript
const admin = db.getSiblingDB("admin");
```

`getSiblingDB("admin")` donne accès à la base `admin` **sans changer** de base courante. La plupart des commandes d'administration doivent être envoyées à cette base.

```javascript
const build = admin.runCommand({ buildInfo: 1 });
```

`buildInfo` décrit le **binaire** `mongod` : sa version, la façon dont il a été compilé, l'allocateur mémoire intégré, etc.

```javascript
const statut = admin.runCommand({ serverStatus: 1 });
```

`serverStatus` décrit l'**état du serveur en fonctionnement** : PID, durée de fonctionnement, connexions, moteur de stockage, statistiques mémoire de TCMalloc… C'est la commande de base de la supervision.

```javascript
const options = admin.runCommand({ getCmdLineOpts: 1 }).parsed;
```

`getCmdLineOpts` renvoie les **options de démarrage** de `mongod`. Le champ `.parsed` contient ces options après lecture du fichier de configuration `/etc/mongod.conf`, avec la même structure que ce fichier : `storage.dbPath`, `net.bindIp`, `net.port`…

```javascript
const hote = admin.runCommand({ hostInfo: 1 });
```

`hostInfo` décrit la **machine** qui héberge le serveur : système d'exploitation, processeur, mémoire. Le sous-document `extra` contient des détails propres à Linux, dont la version du noyau.

```javascript
const avertissements = admin.runCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg);
```

Récupère les **avertissements émis au démarrage** de `mongod`, en trois temps :

1. `getLog: "startupWarnings"` renvoie un document dont le champ `log` est un tableau ;
2. depuis MongoDB 4.4, chaque entrée de journal est une **chaîne au format JSON** ; `JSON.parse(l)` la transforme en objet ;
3. `.map(l => ...)` applique cette transformation à chaque élément du tableau et ne garde que le message (`.msg`).

`l => JSON.parse(l).msg` est une **fonction fléchée** : une façon courte d'écrire « pour chaque `l`, renvoyer `JSON.parse(l).msg` ».

```javascript
const bases = admin.runCommand({ listDatabases: 1, nameOnly: true }).databases.map(b => b.name);
```

- `listDatabases` liste les bases du serveur ;
- `nameOnly: true` demande seulement leurs noms, ce qui est plus rapide (pas de calcul de taille) ;
- `.databases` est un tableau de documents `{ name: ... }` ; `.map(b => b.name)` n'en garde que les noms.

```javascript
const formations = db.getSiblingDB("bd511").formations;
```

Désigne la collection `formations` de la base `bd511`. Cette ligne ne crée rien : dans MongoDB, une base et une collection ne sont créées qu'à la première insertion de données.

### 3. Fonction d'affichage

```javascript
const ligne = (libelle, valeur) => print(libelle.padEnd(28) + ": " + valeur);
```

Définit une petite fonction fléchée `ligne` qui affiche un libellé et une valeur :

- `padEnd(28)` complète le libellé avec des espaces jusqu'à 28 caractères, pour aligner toutes les valeurs en colonne ;
- `+` colle les morceaux de texte ;
- `print()` affiche le résultat dans le terminal.

### 4. Affichage de la fiche

```javascript
ligne("Serveur MongoDB", build.version + " (allocateur " + build.allocator + ")");
```

Version du serveur et nom de l'**allocateur mémoire** compilé dans le binaire (une variante de TCMalloc pour les binaires officiels).

```javascript
ligne("Shell mongosh", version());
```

Dans `mongosh`, la fonction `version()` renvoie la version **du shell** lui-même, distincte de celle du serveur.

```javascript
ligne("Noyau Linux", hote.extra.kernelVersion);
```

Version du noyau vue par le serveur. Après la partie 0.4, elle doit être de la forme `6.8.0-…-generic`.

```javascript
ligne("Processus mongod", "PID " + String(statut.pid) + ", démarré depuis " + statut.uptime + " s");
```

- `statut.pid` est le numéro du processus `mongod`. Il est stocké comme entier 64 bits (type `Long`) ; `String()` le convertit en texte pour un affichage propre (sinon on obtiendrait `Long('1234')`) ;
- `statut.uptime` est le temps écoulé depuis le démarrage de `mongod`, en secondes.

```javascript
ligne("Moteur de stockage", statut.storageEngine.name);
```

Moteur de stockage utilisé : `wiredTiger`, le moteur par défaut de MongoDB.

```javascript
ligne("dbPath", options.storage.dbPath);
```

Dossier des données, tel que configuré : `/var/lib/mongodb`.

```javascript
ligne("Écoute", options.net.bindIp + ":" + options.net.port);
```

Adresse et port d'écoute : `127.0.0.1:27017`. Le serveur n'accepte que les connexions venant de la machine elle-même.

```javascript
ligne("Caches TCMalloc par CPU", statut.tcmalloc.usingPerCPUCaches);
```

`true` attendu : l'allocateur TCMalloc utilise bien ses caches par processeur, signe que le réglage `GLIBC_TUNABLES=glibc.pthread.rseq=0` du service est effectif (voir `check-mongodb.md`).

```javascript
ligne("Connexions", statut.connections.current + " ouverte(s), " + statut.connections.available + " disponible(s)");
```

- `current` : connexions ouvertes en ce moment, dont celle(s) de votre `mongosh` ;
- `available` : connexions encore possibles avant d'atteindre la limite du serveur.

```javascript
ligne("Bases", bases.join(", "));
```

`join(", ")` réunit les éléments du tableau en une seule chaîne, séparés par une virgule. On voit au minimum les bases système `admin`, `config` et `local`, et `bd511` dès qu'elle contient des données.

```javascript
ligne("bd511.formations", formations.countDocuments() + " document(s)");
```

`countDocuments()` compte les documents de la collection. Le résultat vaut 0 si la collection n'existe pas encore.

```javascript
ligne("Avertissements de démarrage", avertissements.length);
avertissements.forEach(a => print("  - " + a));
```

- `.length` donne le nombre d'avertissements ;
- `forEach` exécute la fonction pour chaque élément : chaque message est affiché sur sa propre ligne, précédé d'un tiret.

À ce stade du TP, un seul avertissement est normal : « Access control is not enabled for the database », car l'authentification n'est pas encore activée.

---

## Ce que vous devez obtenir

| Ligne affichée | Valeur attendue |
|---|---|
| Serveur MongoDB | 8.3.x, allocateur TCMalloc |
| Shell mongosh | version du shell installé |
| Noyau Linux | `6.8.0-…-generic` |
| Processus mongod | un PID et une durée en secondes |
| Moteur de stockage | `wiredTiger` |
| dbPath | `/var/lib/mongodb` |
| Écoute | `127.0.0.1:27017` |
| Caches TCMalloc par CPU | `true` |
| Connexions | au moins 1 ouverte (la vôtre) |
| Bases | `admin, config, local` (+ `bd511` selon l'avancement du TP) |
| bd511.formations | nombre de documents (0 si la collection n'existe pas encore) |
| Avertissements de démarrage | 1 (accès sans authentification) |

Une valeur différente ? Lancez `sudo bash ~/bd511/ch02/check-mongodb.sh` : il indique précisément quel réglage corriger.
