# `p1_connexion.py` — explications

**Module BD511 · Chapitre 3 · Test de connexion avec PyMongo**

## En bref

Ce premier script vérifie que Python sait parler à MongoDB, puis affiche une fiche d'identité de la connexion :

- les versions de PyMongo et du serveur ;
- les bases présentes sur le serveur ;
- les principaux réglages du client : taille du pool de connexions, délai maximal des opérations, niveau d'acquittement des écritures (*write concern*) ;
- le nombre de documents de chaque collection de la base `bd511`.

Il ne modifie aucune donnée.

```bash
source ~/bd511/ch03/python/bd511.env    # définit MONGODB_URI (voir connexion.md)
python3 p1_connexion.py
```

---

## Explication instruction par instruction

### 1. Docstring et imports

```python
"""p1_connexion.py - BD511 ch.3 : test de connexion avec PyMongo."""
```

**Docstring** du module : une chaîne de documentation, sans effet à l'exécution.

```python
import sys
```

Module standard `sys`, utilisé ici pour `sys.exit()` (arrêt du programme avec un message).

```python
import pymongo
from pymongo.errors import PyMongoError
```

- `import pymongo` importe le driver entier ; on s'en sert pour lire sa version (`pymongo.__version__`) ;
- `PyMongoError` est la **classe mère de toutes les exceptions de PyMongo** (serveur injoignable, délai dépassé, authentification refusée…). L'intercepter permet de traiter d'un coup toutes les erreurs du driver.

```python
from connexion import get_client
```

Importe la fonction `get_client()` du module `connexion.py`, situé dans le même dossier (voir `connexion.md`).

### 2. Ouverture du client et test de connexion

```python
with get_client() as client:
```

- `get_client()` crée le `MongoClient` à partir de `MONGODB_URI` ;
- `with ... as client:` est un **gestionnaire de contexte** : le client est disponible sous le nom `client` dans tout le bloc indenté, puis **fermé automatiquement** à la sortie du bloc (connexions comprises), même en cas d'erreur ou d'arrêt du programme.

```python
    try:
        client.admin.command("ping")
    except PyMongoError as erreur:
        sys.exit(f"Serveur injoignable : {erreur}")
```

- `client.admin` désigne la base `admin` (écriture équivalente à `client["admin"]`) ;
- `.command("ping")` envoie au serveur la commande `ping`, qui se contente de répondre `{ ok: 1 }`. C'est la façon la plus légère de **tester la connexion** ;
- c'est la **première vraie opération réseau** : comme la création du client ne bloque pas, une adresse erronée ou un serveur arrêté ne se révèle qu'ici ;
- `try: ... except PyMongoError as erreur:` intercepte l'erreur éventuelle et la range dans la variable `erreur`. Un serveur injoignable lève par exemple une `ServerSelectionTimeoutError`, au bout du délai de sélection de serveur (30 s par défaut, ou le délai `timeoutMS` s'il est défini dans l'URI) ;
- `sys.exit(f"...")` arrête le programme avec un message. Le `f` devant la chaîne en fait une **f-string** : `{erreur}` y est remplacé par le texte de l'erreur.

### 3. Fiche d'identité de la connexion

```python
    options = client.options
```

`client.options` donne une vue en lecture seule de la **configuration effective du client** : options passées dans l'URI ou en paramètres, complétées par les valeurs par défaut.

```python
    print("PyMongo                :", pymongo.__version__)
```

Version du driver installé (celle de `requirements.txt`). `print()` affiche ses arguments séparés par un espace ; les espaces dans les libellés servent à aligner les `:`.

```python
    print("Serveur MongoDB        :", client.server_info()["version"])
```

`server_info()` renvoie les informations de compilation du serveur (le résultat de la commande `buildInfo`) sous forme de dictionnaire ; `["version"]` en extrait la version, par exemple `8.3.x`.

```python
    print("Bases                  :", ", ".join(client.list_database_names()))
```

- `list_database_names()` renvoie la liste des noms de bases, par exemple `['admin', 'bd511', 'config', 'local']` ;
- `", ".join(liste)` réunit les éléments en une seule chaîne, séparés par `, `.

```python
    print("Pool de connexions max :", options.pool_options.max_pool_size)
```

Nombre maximal de connexions que le client peut ouvrir simultanément vers un serveur (option d'URI `maxPoolSize`, **100 par défaut**). Au-delà, les opérations attendent qu'une connexion se libère.

```python
    print("Délai des opérations   :", options.timeout, "s")
```

Délai maximal accordé à chaque opération, en secondes (option d'URI `timeoutMS`, convertie en secondes). Passé ce délai, l'opération est abandonnée avec une erreur. Si l'URI ne définit pas `timeoutMS`, la valeur est `None` (pas de délai global) et la ligne affiche `None s`.

```python
    print("Write concern          :", client.write_concern.document)
```

Le **write concern** est le niveau d'acquittement demandé au serveur pour les écritures :

| Valeur affichée | Signification |
|---|---|
| `{}` | rien de précisé : la valeur par défaut du serveur s'applique |
| `{'w': 1}` | le serveur principal confirme l'écriture |
| `{'w': 'majority'}` | la majorité des membres d'un *replica set* confirme l'écriture |
| `{'j': True}` | l'écriture doit être inscrite dans le journal sur disque avant confirmation |

`.document` renvoie ce réglage sous forme de dictionnaire.

### 4. Contenu de la base `bd511`

```python
    db = client["bd511"]
```

Objet `Database` qui représente la base `bd511`. Cette ligne n'envoie aucune requête : elle prépare seulement l'accès.

```python
    for nom in sorted(db.list_collection_names()):
```

- `list_collection_names()` renvoie la liste des collections de la base ;
- `sorted(...)` la trie par ordre alphabétique ;
- `for nom in ...:` parcourt la liste : à chaque tour, `nom` contient le nom d'une collection.

```python
        print(f"bd511.{nom:<16}: {db[nom].count_documents({})} documents")
```

- `db[nom]` donne la collection dont le nom est dans la variable `nom` ;
- `count_documents({})` compte les documents qui correspondent au filtre. Le filtre vide `{}` correspond à **tous** les documents. Ce comptage est exact (il parcourt la collection) ; pour une estimation instantanée à partir des métadonnées, il existe `estimated_document_count()` ;
- dans la f-string, `{nom:<16}` aligne le nom à gauche (`<`) sur 16 caractères pour former une colonne.

---

## Ce que vous devez obtenir

Exemple (les valeurs de pool, de délai et de write concern dépendent de l'URI de `bd511.env`, les comptages dépendent du jeu de données) :

```text
PyMongo                : 4.19.0
Serveur MongoDB        : 8.3.x
Bases                  : admin, bd511, config, local
Pool de connexions max : 100
Délai des opérations   : None s
Write concern          : {}
bd511.formations      : <n> documents
bd511.inscriptions    : <n> documents
bd511.stagiaires      : <n> documents
```

En cas de message `MONGODB_URI n'est pas définie`, faites le `source` du fichier `bd511.env`. En cas de `Serveur injoignable`, vérifiez que `mongod` tourne (`systemctl status mongod`) et que l'URI est correcte.
