# `p3_agregation.py` — explications

**Module BD511 · Chapitre 3 · Pipelines d'agrégation avec PyMongo**

## En bref

Un **pipeline d'agrégation** est une suite d'**étapes** (*stages*) que les documents traversent l'une après l'autre, comme sur une chaîne de montage : chaque étape reçoit les documents produits par la précédente, les filtre, les transforme ou les regroupe, puis les passe à la suivante. Tout le calcul est fait **par le serveur** : seul le résultat final transite sur le réseau.

Le script fait trois choses :

1. une **mise à jour préalable** : convertir en nombres des notes d'évaluation stockées sous forme de texte ;
2. un premier rapport : la **note moyenne par domaine** de formation ;
3. un second rapport : le **chiffre d'affaires HT** des cinq formations qui en rapportent le plus.

```bash
source ~/bd511/ch03/python/bd511.env
python3 p3_agregation.py
```

Dans un pipeline, une chaîne qui commence par `$` désigne la **valeur d'un champ** du document en cours : `"$evaluation.note"` signifie « la valeur du champ `note` du sous-document `evaluation` ».

---

## Explication instruction par instruction

### 1. Docstring, import et connexion

```python
"""p3_agregation.py - BD511 ch.3 : pipelines d'agrégation avec PyMongo."""
from connexion import get_client
```

Docstring du module, puis import de la fonction qui crée le client MongoDB (voir `connexion.md`).

```python
with get_client() as client:
    inscriptions = client["bd511"]["inscriptions"]
```

- `with ... as client:` crée le client et le fermera automatiquement à la fin du bloc ;
- `client["bd511"]["inscriptions"]` : la collection `inscriptions` de la base `bd511`. Les deux rapports partent de cette collection.

### 2. Mise à jour préalable : des notes texte converties en entiers

```python
    # Préalable : notes migrées en texte -> entiers (mise à jour par pipeline, sans effet si déjà faite)
    r = inscriptions.update_many({"evaluation.note": {"$type": "string"}},
                                 [{"$set": {"evaluation.note": {"$toInt": "$evaluation.note"}}}])
    print("Notes converties en entiers :", r.modified_count)
```

Dans le jeu de données, certaines notes ont été enregistrées sous forme de texte (`"4"` au lieu de `4`), comme cela arrive après une migration depuis un autre système. MongoDB n'impose pas de schéma : un même champ peut contenir des types différents d'un document à l'autre. Or une moyenne ne se calcule que sur des nombres.

- le **filtre** `{"evaluation.note": {"$type": "string"}}` sélectionne les documents dont la note est une **chaîne de caractères**. `$type` teste le type BSON d'un champ ;
- la **modification** est une **liste** `[ ... ]` : c'est une **mise à jour par pipeline**. Contrairement à une mise à jour classique, elle peut calculer la nouvelle valeur **à partir de la valeur actuelle** du champ ;
- `{"$toInt": "$evaluation.note"}` convertit la note actuelle en entier : `"4"` devient `4` ;
- `r.modified_count` affiche le nombre de documents convertis.

> **Piège** : dans une mise à jour classique (sans crochets), `{"$set": {"evaluation.note": "$evaluation.note"}}` écrirait littéralement le texte `"$evaluation.note"` dans le champ. Seule la mise à jour par pipeline interprète `"$champ"` comme une référence à une valeur.

Cette étape est **idempotente** : une fois les notes converties, le filtre ne trouve plus rien, et une nouvelle exécution affiche `Notes converties en entiers : 0`.

### 3. Premier rapport : note moyenne par domaine

```python
    # Pipeline construit dans Compass (EXPORT CODE > Python)
```

Ce pipeline a été mis au point dans **Compass**, dont l'onglet *Aggregations* permet de construire un pipeline étape par étape en voyant le résultat de chacune. Le bouton d'export de code (*Export Code*) le traduit ensuite en Python. C'est une méthode de travail efficace : on construit et on teste dans Compass, puis on colle le code dans le programme.

```python
    pipeline = [
        {"$match": {"evaluation.note": {"$type": "number"}}},
        {"$lookup": {"from": "formations", "localField": "formation_id", "foreignField": "_id", "as": "formation"}},
        {"$group": {"_id": {"$first": "$formation.domaine"}, "note_moyenne": {"$avg": "$evaluation.note"},
                    "evaluations": {"$sum": 1}}},
        {"$project": {"_id": 0, "domaine": "$_id", "note_moyenne": {"$round": ["$note_moyenne", 2]},
                      "evaluations": "$evaluations"}},
        {"$sort": {"note_moyenne": -1}},
    ]
```

En Python, le pipeline est une **liste de dictionnaires**, un par étape, exécutés dans l'ordre :

**Étape 1 — `$match` : filtrer**

```python
{"$match": {"evaluation.note": {"$type": "number"}}}
```

Ne garde que les inscriptions qui ont une note **numérique** (`"number"` regroupe tous les types numériques : entier, entier long, double, décimal). Les inscriptions sans évaluation sont écartées. On filtre **le plus tôt possible** : les étapes suivantes ont moins de documents à traiter, et un `$match` en début de pipeline peut profiter des index.

**Étape 2 — `$lookup` : joindre**

```python
{"$lookup": {"from": "formations", "localField": "formation_id", "foreignField": "_id", "as": "formation"}}
```

C'est l'équivalent d'une **jointure** : pour chaque inscription, MongoDB cherche dans la collection `formations` (`from`) les documents dont l'`_id` (`foreignField`) est égal au `formation_id` de l'inscription (`localField`). Les documents trouvés sont ajoutés dans un **tableau** nommé `formation` (`as`). Ce tableau contient ici un seul élément, la formation concernée.

**Étape 3 — `$group` : regrouper et calculer**

```python
{"$group": {"_id": {"$first": "$formation.domaine"}, "note_moyenne": {"$avg": "$evaluation.note"},
            "evaluations": {"$sum": 1}}}
```

Regroupe les documents et calcule une valeur par groupe :

- `_id` définit la **clé de regroupement** : un groupe par valeur différente. Comme `formation` est un tableau, `"$formation.domaine"` est lui aussi un tableau (par exemple `["Bases de données NoSQL"]`). L'opérateur `$first` en prend le **premier élément**, pour regrouper sur une simple chaîne ;
- `note_moyenne` : `$avg` calcule la **moyenne** des notes du groupe ;
- `evaluations` : `$sum: 1` ajoute 1 par document, ce qui **compte** les évaluations du groupe.

> `$first` existe sous deux formes. Comme **accumulateur** de `$group` (`"x": {"$first": "$champ"}`), il prend la valeur du premier document du groupe. Dans une **expression** (comme ici, dans `_id`), il prend le premier élément d'un tableau.

**Étape 4 — `$project` : mettre en forme**

```python
{"$project": {"_id": 0, "domaine": "$_id", "note_moyenne": {"$round": ["$note_moyenne", 2]},
              "evaluations": "$evaluations"}}
```

Définit la forme des documents de sortie :

- `"_id": 0` masque le champ `_id` ;
- `"domaine": "$_id"` crée le champ `domaine` à partir de la clé de regroupement (un renommage) ;
- `{"$round": ["$note_moyenne", 2]}` arrondit la moyenne à 2 décimales ;
- `"evaluations": "$evaluations"` conserve le comptage.

**Étape 5 — `$sort` : trier**

```python
{"$sort": {"note_moyenne": -1}}
```

Trie par note moyenne **décroissante** (`-1`) : le domaine le mieux noté en premier.

```python
    print(f"\n{'Domaine':<27}{'Note':>6}{'Évaluations':>13}")
```

Affiche l'en-tête du tableau. Dans la f-string, `:<27` aligne à gauche sur 27 caractères et `:>6` aligne à droite sur 6 ; `\n` ajoute une ligne vide avant.

```python
    for ligne in inscriptions.aggregate(pipeline):
        print(f"{ligne['domaine']:<27}{ligne['note_moyenne']:>6.2f}{ligne['evaluations']:>13}")
```

- `aggregate(pipeline)` envoie le pipeline au serveur et renvoie un **curseur** sur les résultats ;
- la boucle affiche chaque document résultat sur une ligne, avec les mêmes largeurs de colonnes que l'en-tête ;
- `:>6.2f` affiche un nombre décimal avec 2 chiffres après la virgule, aligné à droite sur 6 caractères.

### 4. Second rapport : chiffre d'affaires HT des 5 premières formations

```python
    # Chiffre d'affaires HT des 5 premières formations (montants Decimal128 -> decimal.Decimal)
    pipeline = [
        {"$match": {"statut": {"$in": ["terminée", "confirmée"]}}},
        {"$group": {"_id": "$formation_id", "ca_ht": {"$sum": "$prix_ht"}, "inscriptions": {"$sum": 1}}},
        {"$sort": {"ca_ht": -1}},
        {"$limit": 5},
        {"$lookup": {"from": "formations", "localField": "_id", "foreignField": "_id", "as": "formation"}},
        {"$project": {"_id": 0, "code": "$_id", "titre": {"$first": "$formation.titre"},
                      "inscriptions": "$inscriptions", "ca_ht": "$ca_ht"}},
    ]
```

La variable `pipeline` reçoit un nouveau pipeline :

| Étape | Rôle |
|---|---|
| `$match` | ne garde que les inscriptions **terminées ou confirmées** (`$in`) : les inscriptions en attente ou annulées ne rapportent rien |
| `$group` | un groupe par formation (`"_id": "$formation_id"`) ; `ca_ht` additionne les prix (`$sum: "$prix_ht"`) et `inscriptions` compte les documents (`$sum: 1`) |
| `$sort` | trie par chiffre d'affaires décroissant |
| `$limit` | ne garde que les **5 premiers** |
| `$lookup` | va chercher la formation correspondante, pour récupérer son titre |
| `$project` | produit les champs `code`, `titre` (premier élément du tableau `formation`), `inscriptions` et `ca_ht` |

Deux points à remarquer :

- **L'ordre des étapes compte pour les performances.** Le `$lookup` est placé **après** `$limit` : la jointure n'est faite que pour 5 documents, au lieu d'une par formation ou par inscription. Le résultat serait le même avec le `$lookup` plus tôt, mais pour beaucoup plus de travail ;
- **Les montants restent exacts.** Les prix sont en `Decimal128` : leur somme `$sum` est elle aussi un `Decimal128`, sans les erreurs d'arrondi des nombres à virgule flottante.

```python
    print(f"\n{'Code':<7}{'Titre':<42}{'Inscr.':>7}{'CA HT (€)':>13}")
```

En-tête du second tableau, avec des colonnes de 7, 42, 7 et 13 caractères.

```python
    for ligne in inscriptions.aggregate(pipeline):
        ca = ligne["ca_ht"].to_decimal()
```

Pour chaque résultat, `.to_decimal()` convertit le `Decimal128` (type BSON, prévu pour le stockage) en `decimal.Decimal` Python, que l'on peut formater et utiliser dans des calculs.

```python
        print(f"{ligne['code']:<7}{ligne['titre'][:40]:<42}{ligne['inscriptions']:>7}{ca:>13,.2f}".replace(",", " "))
```

- `ligne['titre'][:40]` **tronque** le titre à ses 40 premiers caractères (découpage de chaîne : du début jusqu'à l'indice 40 exclu), pour qu'il tienne dans sa colonne de 42 ;
- `{ca:>13,.2f}` : montant aligné à droite sur 13 caractères (`>13`), avec une **virgule comme séparateur de milliers** (`,`) et 2 décimales (`.2f`), par exemple `12,345.00` ;
- `.replace(",", " ")` remplace ensuite les virgules par des espaces, pour obtenir une présentation à la française des milliers : `12 345.00`.

---

## Ce que vous devez obtenir

Les valeurs dépendent du jeu de données. La structure de la sortie est la suivante :

```text
Notes converties en entiers : <n>        (0 à partir de la deuxième exécution)

Domaine                      Note  Évaluations
<domaine le mieux noté>      4.xx          <n>
…

Code   Titre                                      Inscr.    CA HT (€)
<code> <titre de la formation>                       <n>    <montant>
…                                                              (5 lignes)
```

## Mémo des étapes utilisées

| Étape | Équivalent SQL approximatif | Rôle |
|---|---|---|
| `$match` | `WHERE` | filtrer les documents |
| `$lookup` | `LEFT OUTER JOIN` | joindre une autre collection (résultat dans un tableau) |
| `$group` | `GROUP BY` + `AVG`, `SUM`, `COUNT` | regrouper et calculer par groupe |
| `$project` | liste des colonnes du `SELECT` | choisir, renommer, calculer les champs de sortie |
| `$sort` | `ORDER BY` | trier |
| `$limit` | `LIMIT` | garder les N premiers |

Pour mettre au point un pipeline, procédez comme dans Compass : ajoutez les étapes **une par une** et regardez le résultat de chacune avant de passer à la suivante.
