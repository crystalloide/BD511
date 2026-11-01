# `p2_crud.py` — explications

**Module BD511 · Chapitre 3 · Création et manipulation de documents avec PyMongo (CRUD)**

## En bref

**CRUD** désigne les quatre opérations de base sur les données : **C**reate (créer), **R**ead (lire), **U**pdate (modifier), **D**elete (supprimer). Ce script les passe toutes en revue avec PyMongo, sur trois collections de la base `bd511` :

| Collection | Rôle dans le script |
|---|---|
| `stagiaires` | on y crée, modifie puis supprime les stagiaires `STG0301` et `STG0302` |
| `inscriptions` | on y crée trois inscriptions de `STG0301`, qu'on modifie puis supprime |
| `formations` | le catalogue, **lu seulement** (prix et sessions) |

Le script est organisé en six parties numérotées, qui s'affichent à l'écran. Il **remet la base dans son état initial** à la fin, et peut donc être relancé autant de fois que nécessaire.

```bash
source ~/bd511/ch03/python/bd511.env
python3 p2_crud.py
```

Prérequis : la base `bd511` doit contenir le catalogue des formations, avec au moins les formations `BD511`, `BD512` et `DO301`.

### Correspondance entre types Python et types BSON

MongoDB stocke les documents au format **BSON** (un JSON binaire, plus riche en types). PyMongo convertit automatiquement :

| Python | BSON (MongoDB) | Exemple dans le script |
|---|---|---|
| `dict` | document (ou sous-document) | `{"ville": "Lyon", ...}` |
| `list` | tableau | `["BD511", "BD512", "DO301"]` |
| `str` | chaîne | `"Moreau"` |
| `int` | entier 32 ou 64 bits | `4` |
| `bool` | booléen | `True` |
| `datetime` | date | `datetime(2026, 10, 22, ...)` |
| `Decimal128` (module `bson`) | décimal exact | prix des formations |
| `ObjectId` (module `bson`) | identifiant généré | `_id` des inscriptions |
| `None` | null | — |

---

## Explication instruction par instruction

### 1. Docstring et imports

```python
"""p2_crud.py - BD511 ch.3 : création et manipulation de documents avec PyMongo."""
from datetime import datetime, timezone
```

- docstring du module (documentation, sans effet à l'exécution) ;
- `datetime` (date et heure) et `timezone` (fuseau horaire) viennent du module standard `datetime`.

```python
from pymongo import DeleteOne, ReturnDocument, UpdateOne
from pymongo.errors import DuplicateKeyError
```

- `UpdateOne` et `DeleteOne` décrivent des opérations à regrouper dans un `bulk_write` (partie 5) ;
- `ReturnDocument` indique si `find_one_and_update` renvoie le document avant ou après modification (partie 4) ;
- `DuplicateKeyError` est l'exception levée quand on insère une valeur déjà présente dans un index unique (partie 1).

```python
from connexion import get_client
```

La fonction qui crée le client MongoDB (voir `connexion.md`).

### 2. Constantes et fonction d'affichage

```python
STAGIAIRE = "STG0301"
FORMATIONS = ["BD511", "BD512", "DO301"]
```

Deux **constantes** : l'identifiant de la stagiaire de test et la liste des formations auxquelles elle va s'inscrire. En Python, les noms en MAJUSCULES signalent par convention une valeur qui ne change pas.

```python
def titre(texte):
    print(f"\n== {texte}")
```

Petite fonction qui affiche un titre de partie. `\n` ajoute une ligne vide avant le titre ; `{texte}` est remplacé par l'argument reçu.

### 3. Connexion et nettoyage préalable

```python
with get_client() as client:
    db = client["bd511"]
    stagiaires, inscriptions = db["stagiaires"], db["inscriptions"]
```

- `with ... as client:` crée le client et le fermera automatiquement à la fin du bloc ;
- `db` représente la base `bd511` ;
- la troisième ligne est une **affectation multiple** : `stagiaires` reçoit la collection `stagiaires`, `inscriptions` la collection `inscriptions`.

Ces lignes n'envoient aucune requête au serveur. Une collection qui n'existe pas encore sera créée automatiquement à la première insertion.

```python
    # Le script peut être relancé : on supprime d'abord les données d'une exécution précédente.
    inscriptions.delete_many({"stagiaire_id": STAGIAIRE})
    stagiaires.delete_many({"_id": {"$in": [STAGIAIRE, "STG0302"]}})
```

Si une exécution précédente a été interrompue, des données de test peuvent rester en base. On les supprime d'abord pour repartir d'un état propre :

- `delete_many(filtre)` supprime **tous** les documents qui correspondent au filtre ;
- `{"stagiaire_id": STAGIAIRE}` : documents dont le champ `stagiaire_id` vaut `"STG0301"` ;
- `{"_id": {"$in": [...]}}` : documents dont l'`_id` fait partie de la liste. `$in` est un **opérateur de requête** ; en MongoDB, les opérateurs commencent par `$`.

### 4. Partie 1 — créer un document : `insert_one`

```python
    titre("1. Création d'un document : insert_one")
    nouvelle = {
        "_id": STAGIAIRE,
        "nom": "Moreau",
        "prenom": "Inès",
        "email": "ines.moreau@acme-data.example",
        "entreprise": "Acme Data",
        "fonction": "Administrateur de bases de données",
        "adresse": {"ville": "Lyon", "code_postal": "69003"},
        "actif": True,
        "inscrit_le": datetime(2026, 10, 22, tzinfo=timezone.utc),
        "annees_experience": 4,
    }
```

Le document est un **dictionnaire Python** (paires `"clé": valeur` entre accolades). À noter :

- `"_id"` est la **clé primaire** de tout document MongoDB. Ici on la choisit nous-mêmes (`"STG0301"`) ; si on l'omet, le driver en génère une (voir partie 2) ;
- `"adresse"` est un **sous-document** : un document imbriqué dans un autre ;
- `"actif": True` est un booléen et `"annees_experience": 4` un entier ;
- `datetime(2026, 10, 22, tzinfo=timezone.utc)` est le 22 octobre 2026 à minuit, **en UTC**. On précise toujours le fuseau horaire, puisque MongoDB stocke les dates en UTC ;
- `"code_postal": "69003"` est volontairement une chaîne : un code postal n'est pas un nombre (pas de calcul, et un zéro initial comme dans `01000` doit être conservé).

```python
    resultat = stagiaires.insert_one(nouvelle)
    print("Stagiaire créée :", resultat.inserted_id)
```

`insert_one()` insère le document et renvoie un objet `InsertOneResult`. Son attribut `inserted_id` donne l'`_id` du document inséré, ici `STG0301`.

```python
    try:
        stagiaires.insert_one(nouvelle)
    except DuplicateKeyError as erreur:
        print("Deuxième insertion refusée : code", erreur.code, "- clé", erreur.details["keyValue"])
```

On tente d'insérer **une seconde fois** le même document. Toute collection possède un **index unique sur `_id`** : le serveur refuse le doublon et PyMongo lève une `DuplicateKeyError`.

- `try: ... except ...:` intercepte l'erreur pour l'afficher au lieu d'arrêter le programme ;
- `erreur.code` vaut **11000**, le code MongoDB des doublons de clé (message `E11000 duplicate key error`) ;
- `erreur.details` contient la réponse d'erreur du serveur ; son champ `keyValue` indique la valeur en double : `{'_id': 'STG0301'}`.

### 5. Partie 2 — créer plusieurs documents : `insert_many`

```python
    titre("2. Création de plusieurs documents : insert_many")
    catalogue = {f["_id"]: f for f in db["formations"].find({"_id": {"$in": FORMATIONS}}, {"prix_ht": 1, "sessions": 1})}
```

Lit les trois formations dans le catalogue et les range dans un dictionnaire indexé par code de formation.

- `find(filtre, projection)` renvoie les documents qui correspondent au filtre :
  - le **filtre** `{"_id": {"$in": FORMATIONS}}` sélectionne `BD511`, `BD512` et `DO301` ;
  - la **projection** `{"prix_ht": 1, "sessions": 1}` ne renvoie que ces champs (plus `_id`, toujours inclus par défaut). Ne lire que les champs utiles réduit le volume transféré sur le réseau ;
- `{f["_id"]: f for f in ...}` est une **compréhension de dictionnaire** : pour chaque document `f`, on crée l'entrée `code → document`. Le résultat ressemble à `{"BD511": {...}, "BD512": {...}, "DO301": {...}}`.

```python
    nouvelles = []
    for code in FORMATIONS:
        session = catalogue[code]["sessions"][0]          # première session à venir de la formation
```

- `nouvelles = []` crée une liste vide qui recevra les inscriptions à créer ;
- la boucle parcourt les trois codes de formation ;
- `catalogue[code]["sessions"][0]` : dans le document de la formation, on prend le tableau `sessions` puis son **premier élément** (`[0]`, les indices commencent à 0). Dans le jeu de données, les sessions sont rangées par date : c'est donc la première session à venir.

```python
        nouvelles.append({
            "stagiaire_id": STAGIAIRE,
            "formation_id": code,
            "session": {"debut": session["debut"], "ville": session["ville"],
                        "modalite": "classe virtuelle" if session["ville"] == "À distance" else "présentiel"},
            "date_inscription": datetime.now(timezone.utc),
            "statut": "en attente",
            "prix_ht": catalogue[code]["prix_ht"],       # Decimal128, comme dans le catalogue
            "financement": "entreprise",
        })
```

`append()` ajoute un document d'inscription à la liste. Il contient :

- `stagiaire_id` et `formation_id` : des **références** vers la stagiaire et la formation (l'équivalent de clés étrangères) ;
- `session` : un sous-document qui **recopie** la date de début et la ville de la session. Dans MongoDB, on duplique souvent les informations lues ensemble, pour éviter une jointure à chaque lecture ;
- `"classe virtuelle" if ... else "présentiel"` est une **expression conditionnelle** : la modalité vaut « classe virtuelle » si la ville est « À distance », « présentiel » sinon ;
- `datetime.now(timezone.utc)` : la date et l'heure actuelles, en UTC ;
- `prix_ht` : le prix recopié du catalogue, de type **`Decimal128`**. Pour des montants, on utilise un type décimal exact : avec des nombres à virgule flottante (`float`), `0.1 + 0.2` ne vaut pas exactement `0.3`.

On ne fournit **pas** d'`_id` : le driver va en générer un pour chaque document.

```python
    resultat = inscriptions.insert_many(nouvelles, ordered=False)
```

`insert_many()` insère toute la liste en un seul envoi au serveur.

- `ordered=True` (par défaut) : les documents sont insérés dans l'ordre et l'insertion **s'arrête à la première erreur** ;
- `ordered=False` : le serveur peut traiter les documents dans n'importe quel ordre et **continue** après une erreur, pour insérer tous les documents valides.

```python
    print(len(resultat.inserted_ids), "inscriptions créées ; _id générés par le driver :",
          {type(i).__name__ for i in resultat.inserted_ids})
```

- `resultat.inserted_ids` est la liste des `_id` insérés ; `len()` donne leur nombre (3) ;
- `{type(i).__name__ for i in ...}` est une **compréhension d'ensemble** : elle collecte le nom du type de chaque `_id`, sans doublon. Résultat : `{'ObjectId'}`.

> **L'`ObjectId`** est l'identifiant généré **côté client, par le driver**, quand un document n'a pas d'`_id`. Il fait 12 octets et contient notamment un horodatage de création, ce qui le rend unique sans consulter le serveur. Le driver ajoute aussi cet `_id` dans les dictionnaires Python de la liste `nouvelles`.

### 6. Partie 3 — lire : `find_one`, `find` et curseur

```python
    titre("3. Lecture : find_one, find et curseur")
    s = stagiaires.find_one({"_id": STAGIAIRE}, {"_id": 0, "prenom": 1, "nom": 1, "inscrit_le": 1})
```

- `find_one(filtre, projection)` renvoie **le premier** document trouvé (sous forme de dictionnaire), ou `None` s'il n'y en a aucun ;
- la projection `{"_id": 0, "prenom": 1, ...}` demande `prenom`, `nom` et `inscrit_le`, et **exclut** `_id` (`0`). Dans une projection d'inclusion (champs à `1`), `_id` est le seul champ qu'on peut exclure explicitement.

```python
    print(f"{s['prenom']} {s['nom']}, inscrite le {s['inscrit_le']:%d/%m/%Y à %H:%M %Z}")
```

- `s['prenom']` lit un champ du dictionnaire. Les clés sont entre apostrophes parce que la f-string elle-même est entre guillemets ;
- après le `:`, `%d/%m/%Y à %H:%M %Z` est un **format de date** : jour/mois/année, heure:minute, puis nom du fuseau horaire ;
- `%Z` affiche `UTC` parce que le client a été créé avec `tz_aware=True` (voir `connexion.md`). Sans cette option, la date relue n'aurait pas de fuseau et `%Z` n'afficherait rien.

Résultat : `Inès Moreau, inscrite le 22/10/2026 à 00:00 UTC`.

```python
    curseur = (inscriptions.find({"stagiaire_id": STAGIAIRE}, {"formation_id": 1, "session": 1, "prix_ht": 1})
               .sort("session.debut", 1))
```

- `find()` renvoie un **curseur** : un objet qui permet de parcourir les résultats. **Aucune requête n'est envoyée à ce stade** : elle partira au premier parcours du curseur ;
- `.sort("session.debut", 1)` trie par date de début de session, en ordre croissant (`1` ; `-1` pour décroissant). Le tri est fait **par le serveur** ;
- `"session.debut"` est la **notation pointée** : elle désigne le champ `debut` du sous-document `session` ;
- les parenthèses autour de l'expression permettent de l'écrire sur deux lignes.

```python
    for i in curseur:                                      # le curseur est itéré par lots, à la demande
        print(f"  {i['formation_id']}  {i['session']['debut']:%d/%m/%Y}  {i['session']['ville']:<12}"
              f"{i['prix_ht'].to_decimal():>9} € HT")
```

- `for i in curseur:` parcourt les documents un par un. En coulisse, le driver les récupère **par lots** : un premier lot avec la requête, puis d'autres (commande `getMore`) au fur et à mesure du parcours. Même avec des millions de résultats, la mémoire n'en contient qu'un lot à la fois ;
- deux f-strings écrites l'une après l'autre sont **concaténées automatiquement** par Python : c'est un moyen de couper une longue ligne ;
- `{...:%d/%m/%Y}` formate la date, `{...:<12}` aligne la ville à gauche sur 12 caractères ;
- `.to_decimal()` convertit le `Decimal128` (type BSON, prévu pour le stockage et sans opérations de calcul) en `decimal.Decimal` Python, qu'on peut afficher et utiliser dans des calculs ; `:>9` l'aligne à droite sur 9 caractères.

```python
    print("Inscriptions de la stagiaire :", inscriptions.count_documents({"stagiaire_id": STAGIAIRE}))
```

`count_documents(filtre)` compte les documents qui correspondent au filtre : 3.

```python
    print("Formations à 2400 € HT ou plus :", [f["_id"] for f in
          db["formations"].find({"prix_ht": {"$gte": 2400}}, {"_id": 1}).sort([("prix_ht", -1), ("_id", 1)])])
```

- `{"prix_ht": {"$gte": 2400}}` : formations dont le prix est **supérieur ou égal** (`$gte`, *greater than or equal*) à 2 400. Les autres opérateurs de comparaison sont `$gt`, `$lt`, `$lte`, `$eq`, `$ne` ;
- le prix est stocké en `Decimal128` et comparé à l'entier `2400` : MongoDB compare les nombres **par leur valeur**, quel que soit leur type numérique ;
- `{"_id": 1}` : seul le code de la formation est renvoyé ;
- `.sort([("prix_ht", -1), ("_id", 1)])` : pour trier sur plusieurs champs, on passe une **liste de paires** `(champ, sens)`. L'ordre de la liste fixe la priorité : d'abord le prix décroissant, puis, à prix égal, le code croissant ;
- `[f["_id"] for f in ...]` est une **compréhension de liste** : elle construit la liste des codes de formation.

### 7. Partie 4 — modifier

```python
    titre("4. Mises à jour")
    r = stagiaires.update_one({"_id": STAGIAIRE},
                              {"$set": {"telephone": "06 11 22 33 44"}, "$inc": {"annees_experience": 1},
                               "$currentDate": {"maj_le": True}})
    print("update_one  :", r.matched_count, "trouvé,", r.modified_count, "modifié")
```

`update_one(filtre, modifications)` modifie **le premier** document qui correspond au filtre. Les modifications s'expriment avec des **opérateurs de mise à jour** :

| Opérateur | Effet ici |
|---|---|
| `$set` | donne une valeur à un champ, en le créant s'il n'existe pas : ajoute le téléphone |
| `$inc` | ajoute une valeur à un champ numérique : années d'expérience 4 → 5 |
| `$currentDate` | met la date courante **du serveur** dans le champ `maj_le` |

Le résultat (`UpdateResult`) distingue :

- `matched_count` : nombre de documents **trouvés** par le filtre (1) ;
- `modified_count` : nombre de documents **réellement modifiés** (1). Il vaudrait 0 si les nouvelles valeurs étaient identiques aux anciennes.

```python
    r = inscriptions.update_many({"stagiaire_id": STAGIAIRE, "statut": "en attente"}, {"$set": {"statut": "confirmée"}})
    print("update_many :", r.modified_count, "inscriptions confirmées")
```

`update_many()` modifie **tous** les documents qui correspondent au filtre : les 3 inscriptions « en attente » de la stagiaire passent à « confirmée ». Un filtre à plusieurs champs combine les conditions par un **ET**.

```python
    apres = stagiaires.find_one_and_update(
        {"_id": STAGIAIRE},
        {"$push": {"competences": {"$each": ["mongosh", "Compass", "PyMongo"]}}},
        projection={"_id": 0, "competences": 1, "annees_experience": 1},
        return_document=ReturnDocument.AFTER)
    print("find_one_and_update :", apres)
```

`find_one_and_update()` trouve un document, le modifie et le renvoie, **en une seule opération atomique** : aucune autre opération ne peut s'intercaler entre la modification et la lecture. C'est utile pour un compteur ou pour « réserver » un élément dans une file d'attente.

- `$push` ajoute une valeur à la fin d'un tableau (le tableau `competences` est créé s'il n'existe pas) ; avec `$each`, il ajoute **plusieurs** valeurs d'un coup ;
- `projection=` limite les champs renvoyés ;
- `return_document=ReturnDocument.AFTER` renvoie le document **après** modification. Par défaut (`BEFORE`), on obtiendrait le document tel qu'il était avant.

Résultat : `{'annees_experience': 5, 'competences': ['mongosh', 'Compass', 'PyMongo']}`.

```python
    for _ in range(2):                                     # un upsert rejoué ne crée pas de doublon
        r = stagiaires.update_one({"_id": "STG0302"},
                                  {"$set": {"nom": "Fabre", "prenom": "Hugo", "entreprise": "Datavolt"},
                                   "$setOnInsert": {"inscrit_le": datetime(2026, 10, 22, tzinfo=timezone.utc)}},
                                  upsert=True)
        print("upsert      : upserted_id =", r.upserted_id, "| trouvé :", r.matched_count)
```

Démonstration de l'**upsert** (*update* + *insert*), exécuté deux fois de suite :

- `range(2)` produit 0 puis 1 : la boucle tourne deux fois. La variable `_` n'est pas utilisée ; ce nom le signale par convention ;
- `upsert=True` : si **aucun** document ne correspond au filtre, MongoDB en **crée** un, à partir des champs d'égalité du filtre (`_id: "STG0302"`) et des modifications ;
- `$setOnInsert` ne s'applique **que lors d'une création** : la date d'inscription est fixée une fois pour toutes, et pas écrasée par les exécutions suivantes.

| Tour | Le document existe ? | Ce qui se passe | Affichage |
|---|---|---|---|
| 1 | non | création du document | `upserted_id = STG0302 \| trouvé : 0` |
| 2 | oui | simple mise à jour, `$setOnInsert` ignoré | `upserted_id = None \| trouvé : 1` |

Rejouer l'opération ne crée **pas de doublon** : l'upsert est idéal pour un import ou une synchronisation qu'on peut relancer.

```python
    r = stagiaires.replace_one({"_id": "STG0302"}, {"nom": "Fabre", "prenom": "Hugo"})
    print("replace_one :", r.modified_count, "remplacé ->", stagiaires.find_one({"_id": "STG0302"}))
```

`replace_one()` **remplace le document entier** (sauf son `_id`) par le nouveau. Les champs absents du nouveau document disparaissent : ici `entreprise` et `inscrit_le`. Le nouveau document ne doit contenir **aucun opérateur** (`$set`…).

Résultat : `1 remplacé -> {'_id': 'STG0302', 'nom': 'Fabre', 'prenom': 'Hugo'}`.

> **Piège classique** : pour changer quelques champs, on utilise `update_one` avec `$set`. `replace_one` écrase tout le reste du document.

### 8. Partie 5 — écritures groupées : `bulk_write`

```python
    titre("5. Écritures groupées : bulk_write")
    r = inscriptions.bulk_write([
        UpdateOne({"stagiaire_id": STAGIAIRE, "formation_id": "BD511"}, {"$set": {"financement": "OPCO"}}),
        UpdateOne({"stagiaire_id": STAGIAIRE, "formation_id": "BD512"}, {"$set": {"remise_pct": 10}}),
        DeleteOne({"stagiaire_id": STAGIAIRE, "formation_id": "DO301"}),
    ], ordered=False)
```

`bulk_write()` reçoit une **liste d'opérations** de types différents et les envoie au serveur **en lot**, au lieu d'une requête par opération :

- `UpdateOne(filtre, modifications)` : même effet que `update_one` ;
- `DeleteOne(filtre)` : supprime le premier document qui correspond (ici l'inscription à `DO301`) ;
- `ordered=False` : le serveur peut exécuter les opérations dans n'importe quel ordre et continue en cas d'erreur sur l'une d'elles. Avec `ordered=True` (par défaut), il s'arrêterait à la première erreur.

```python
    print("bulk_write  :", r.modified_count, "modifiés,", r.deleted_count, "supprimé (un seul aller-retour réseau)")
```

Le résultat (`BulkWriteResult`) totalise les effets : 2 documents modifiés, 1 supprimé.

> **Combien d'allers-retours ?** `Collection.bulk_write` regroupe les opérations **par type** : ici, une commande pour les deux mises à jour et une pour la suppression, soit 2 échanges avec le serveur au lieu de 3. Le gain grandit avec le nombre d'opérations : 1 000 mises à jour partent en un seul lot. Depuis MongoDB 8.0, `client.bulk_write()` (PyMongo 4.9 et plus) peut envoyer des opérations de tous types, et même sur plusieurs collections, en une seule commande.

### 9. Partie 6 — supprimer

```python
    titre("6. Suppressions")
    r = inscriptions.delete_many({"stagiaire_id": STAGIAIRE})
    print("delete_many :", r.deleted_count, "inscriptions supprimées")
```

Supprime toutes les inscriptions restantes de la stagiaire : 2 (celle de `DO301` a déjà été supprimée par le `bulk_write`). `deleted_count` donne le nombre de documents supprimés.

```python
    r = stagiaires.delete_many({"_id": {"$in": [STAGIAIRE, "STG0302"]}})
    print("delete_many :", r.deleted_count, "stagiaires supprimés")
```

Supprime les deux stagiaires de test : 2.

```python
    print("Contrôle    :", stagiaires.count_documents({}), "stagiaires,", inscriptions.count_documents({}), "inscriptions")
```

Compte **tous** les documents des deux collections (filtre vide `{}`). Les nombres doivent être les mêmes qu'avant l'exécution du script : la base est revenue à son état initial.

---

## Ce que vous devez obtenir

Les lignes marquées `…` dépendent du jeu de données (dates de session, prix, effectifs) :

```text

== 1. Création d'un document : insert_one
Stagiaire créée : STG0301
Deuxième insertion refusée : code 11000 - clé {'_id': 'STG0301'}

== 2. Création de plusieurs documents : insert_many
3 inscriptions créées ; _id générés par le driver : {'ObjectId'}

== 3. Lecture : find_one, find et curseur
Inès Moreau, inscrite le 22/10/2026 à 00:00 UTC
  …  (une ligne par inscription : code, date de début, ville, prix HT)
Inscriptions de la stagiaire : 3
Formations à 2400 € HT ou plus : […]

== 4. Mises à jour
update_one  : 1 trouvé, 1 modifié
update_many : 3 inscriptions confirmées
find_one_and_update : {'annees_experience': 5, 'competences': ['mongosh', 'Compass', 'PyMongo']}
upsert      : upserted_id = STG0302 | trouvé : 0
upsert      : upserted_id = None | trouvé : 1
replace_one : 1 remplacé -> {'_id': 'STG0302', 'nom': 'Fabre', 'prenom': 'Hugo'}

== 5. Écritures groupées : bulk_write
bulk_write  : 2 modifiés, 1 supprimé (un seul aller-retour réseau)

== 6. Suppressions
delete_many : 2 inscriptions supprimées
delete_many : 2 stagiaires supprimés
Contrôle    : … stagiaires, … inscriptions
```

## Mémo des opérations

| Opération | Méthode PyMongo | Résultat utile |
|---|---|---|
| Créer un document | `insert_one(doc)` | `inserted_id` |
| Créer plusieurs documents | `insert_many(liste, ordered=...)` | `inserted_ids` |
| Lire un document | `find_one(filtre, projection)` | un `dict` ou `None` |
| Lire plusieurs documents | `find(filtre, projection).sort(...)` | un curseur à parcourir |
| Compter | `count_documents(filtre)` | un entier |
| Modifier un / plusieurs | `update_one` / `update_many` | `matched_count`, `modified_count` |
| Modifier et relire | `find_one_and_update(..., return_document=...)` | le document |
| Créer ou modifier | `update_one(..., upsert=True)` | `upserted_id` |
| Remplacer | `replace_one(filtre, doc)` | `modified_count` |
| Grouper | `bulk_write([UpdateOne, DeleteOne, ...])` | `modified_count`, `deleted_count`… |
| Supprimer un / plusieurs | `delete_one` / `delete_many` | `deleted_count` |
