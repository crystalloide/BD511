# `connexion.py` — explications

**Module BD511 · Chapitre 3 · Le client MongoDB partagé par les scripts Python du TP**

## En bref

`connexion.py` n'est pas un script que l'on lance : c'est un **module utilitaire**, importé par les scripts `p1_connexion.py`, `p2_crud.py` et `p3_agregation.py` avec la ligne :

```python
from connexion import get_client
```

Il fournit une seule fonction, `get_client()`, qui crée le **client MongoDB** à partir de la variable d'environnement `MONGODB_URI`. Cette organisation a deux avantages :

- les paramètres de connexion (adresse, port, options, identifiants éventuels) sont rassemblés à un seul endroit, le fichier `bd511.env`, et **pas dans le code** ;
- tous les scripts du TP se connectent exactement de la même façon.

**Prérequis** : dans chaque nouveau terminal, avant de lancer les scripts, chargez la variable d'environnement :

```bash
source ~/bd511/ch03/python/bd511.env
echo $MONGODB_URI        # vérification : affiche l'URI de connexion
```

Une variable d'environnement n'existe que dans le terminal où elle a été définie (et dans les programmes qu'il lance) : si vous ouvrez un nouveau terminal, il faut refaire le `source`.

---

## Explication instruction par instruction

### 1. Docstring du module

```python
"""connexion.py - BD511 ch.3 : création du client MongoDB partagé par les scripts du TP."""
```

Une chaîne entre triples guillemets placée tout en haut d'un fichier est une **docstring** : la documentation du module. Elle n'a aucun effet à l'exécution, mais elle s'affiche avec `help(connexion)` et dans les éditeurs de code.

### 2. Imports

```python
import os
import sys
```

Deux modules de la **bibliothèque standard** de Python (disponibles sans installation) :

- `os` : interaction avec le système d'exploitation, ici pour lire les variables d'environnement ;
- `sys` : interaction avec l'interpréteur Python, ici pour arrêter le programme proprement.

```python
from pymongo import MongoClient
```

Importe la classe `MongoClient` du **driver PyMongo** (installé grâce à `requirements.txt`). Le client est le point d'entrée de toute communication avec MongoDB : on en tire les bases (`client["bd511"]`), puis les collections.

> Par convention (PEP 8), les imports sont regroupés : d'abord la bibliothèque standard, puis les bibliothèques externes, séparés par une ligne vide.

### 3. Déclaration de la fonction

```python
def get_client() -> MongoClient:
```

- `def` déclare une **fonction** nommée `get_client`, sans paramètre (parenthèses vides) ;
- `-> MongoClient` est une **annotation de type** : elle indique que la fonction renvoie un objet `MongoClient`. Python ne la vérifie pas à l'exécution, mais elle documente le code et aide les éditeurs (autocomplétion, détection d'erreurs) ;
- le `:` final ouvre le **bloc** de la fonction. En Python, ce sont les **indentations** (4 espaces) qui délimitent les blocs, pas des accolades.

```python
    """Crée le client à partir de MONGODB_URI (un seul client par processus : il gère son pool de connexions)."""
```

Docstring de la fonction. Elle rappelle une règle importante :

> **Un seul client par processus.** Un `MongoClient` ouvre et entretient lui-même un **pool de connexions** : un ensemble de connexions réseau réutilisées d'une opération à l'autre. Créer une connexion coûte cher (connexion TCP, éventuellement chiffrement TLS et authentification). On crée donc **un** client au démarrage du programme et on le réutilise partout ; on n'en crée surtout pas un par requête. Le client peut être partagé sans risque entre plusieurs threads.

### 4. Lecture de l'URI de connexion

```python
    uri = os.environ.get("MONGODB_URI")
```

- `os.environ` se comporte comme un dictionnaire contenant les variables d'environnement ;
- `.get("MONGODB_URI")` renvoie la valeur de la variable, ou `None` si elle n'existe pas (alors que `os.environ["MONGODB_URI"]` provoquerait une erreur `KeyError`).

L'**URI de connexion** (*connection string*) décrit où et comment se connecter. Sa forme générale est :

```text
mongodb://[utilisateur:motdepasse@]hote:port/[base][?option1=valeur&option2=valeur]
```

Elle peut porter des options comme la taille maximale du pool (`maxPoolSize`), le délai maximal des opérations (`timeoutMS`) ou le niveau d'acquittement des écritures (`w`). Ouvrez le fichier `bd511.env` pour voir l'URI utilisée dans le TP ; `p1_connexion.py` affiche ensuite les valeurs effectivement appliquées.

### 5. Arrêt immédiat si la variable manque

```python
    if not uri:
        sys.exit("MONGODB_URI n'est pas définie : exécutez « source ~/bd511/ch03/python/bd511.env ».")
```

- `not uri` est vrai si `uri` vaut `None` (variable absente) ou une chaîne vide ;
- `sys.exit("message")` affiche le message sur la sortie d'erreur et arrête le programme avec le code retour `1` (échec).

C'est le principe du **« fail fast »** (échouer tôt) : sans URI, il vaut mieux s'arrêter tout de suite avec un message qui dit quoi faire, plutôt que d'obtenir plus loin une erreur obscure (ou, pire, une connexion à un mauvais serveur).

La commande proposée, `source fichier`, exécute le fichier dans le terminal courant : la ligne `export MONGODB_URI=...` qu'il contient y définit la variable pour toute la session.

### 6. Création du client

```python
    # tz_aware=True : les dates lues sont des datetime avec fuseau (UTC), jamais des dates « naïves »
    return MongoClient(uri, tz_aware=True)
```

- `return` renvoie le résultat de la fonction ;
- `MongoClient(uri, ...)` crée le client. La création **ne bloque pas** : le driver se connecte en arrière-plan, et la première opération attend qu'un serveur soit disponible. Une adresse erronée ne provoque donc pas d'erreur ici, mais à la première requête (voir le `ping` de `p1_connexion.py`) ;
- `tz_aware=True` règle la façon dont les **dates** sont relues.

> **Pourquoi `tz_aware=True` ?** MongoDB stocke les dates (type BSON `Date`) en UTC, sans fuseau horaire. Par défaut, PyMongo les relit sous forme de `datetime` **« naïfs »** : sans indication de fuseau, alors qu'ils sont en UTC. C'est une source d'erreurs classique (comparaison avec une heure locale, décalage d'une ou deux heures, ou erreur `TypeError` quand on compare une date naïve et une date avec fuseau). Avec `tz_aware=True`, chaque date relue porte explicitement le fuseau UTC. Vous le verrez dans `p2_crud.py`, où l'affichage d'une date se termine par `UTC`.

---

## Utilisation dans les scripts

Les scripts du TP utilisent tous le même schéma :

```python
from connexion import get_client

with get_client() as client:
    db = client["bd511"]
    ...
```

- Python trouve `connexion.py` parce qu'il se trouve **dans le même dossier** que les scripts : le dossier du script lancé fait partie des emplacements où Python cherche les modules ;
- le bloc `with` ferme automatiquement le client (et toutes ses connexions) à la fin du bloc, même si une erreur survient.
