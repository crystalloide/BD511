# `requirements.txt` — explications

**Module BD511 · Chapitre 3 · Les bibliothèques Python nécessaires au TP**

## En bref

`requirements.txt` n'est pas un programme : c'est la **liste des bibliothèques Python** dont les scripts du TP ont besoin, avec leur version exacte. Ce fichier est lu par `pip`, le gestionnaire de paquets de Python, qui télécharge et installe tout en une commande :

```bash
pip install -r requirements.txt
```

L'option `-r` (*requirement file*) demande à `pip` de lire la liste dans le fichier.

Le format est simple : un paquet par ligne, et les lignes qui commencent par `#` sont des commentaires.

---

## Explication ligne par ligne

```text
# Versions figées : installation reproductible (même résultat sur tous les postes)
```

Commentaire. Il explique le choix de **figer les versions** : chaque stagiaire installe exactement les mêmes versions que celles avec lesquelles le TP a été testé. Sans cela, `pip` installerait la dernière version disponible le jour de l'installation, qui pourrait se comporter différemment (nouveaux avertissements, fonctions modifiées ou retirées).

```text
pymongo==4.19.0
```

**PyMongo**, le driver officiel MongoDB pour Python, en version **exactement** 4.19.0. C'est lui qui fournit `MongoClient`, les opérations CRUD, les agrégations, etc.

Il contient aussi le module `bson`, qui convertit les types Python en types BSON et inversement (`ObjectId`, `Decimal128`…).

> N'installez **jamais** le paquet `bson` séparément depuis PyPI : c'est un projet sans rapport avec MongoDB, qui entre en conflit avec le `bson` fourni par PyMongo.

```text
dnspython==2.9.0
```

**dnspython**, une bibliothèque d'interrogation DNS. PyMongo s'en sert pour les URI de la forme `mongodb+srv://…` : au lieu de lister tous les serveurs d'un cluster dans l'URI, on donne un seul nom, et le driver retrouve la liste des serveurs et certaines options dans des enregistrements DNS (SRV et TXT). C'est la forme d'URI utilisée notamment par MongoDB Atlas.

`dnspython` est de toute façon une dépendance de PyMongo, installée automatiquement. Le citer ici permet de **figer aussi sa version**.

---

## Les opérateurs de version

| Écriture | Signification |
|---|---|
| `pymongo==4.19.0` | exactement la version 4.19.0 (choix du TP) |
| `pymongo>=4.19` | la version 4.19 ou n'importe quelle version plus récente |
| `pymongo~=4.19.0` | version « compatible » : 4.19.0 ou plus, mais inférieure à 4.20 |
| `pymongo` | la dernière version disponible |

---

## Installation dans un environnement virtuel

Sur Ubuntu 24.04, `pip` refuse d'installer des paquets dans le Python du système (erreur `externally-managed-environment`) pour ne pas perturber les outils du système. On installe donc les bibliothèques dans un **environnement virtuel** (*venv*) : un dossier qui contient un Python et des bibliothèques propres au projet.

Si le guide du TP ne prévoit pas déjà une autre procédure, la démarche type est la suivante :

```bash
cd ~/bd511/ch03/python
python3 -m venv .venv               # crée l'environnement virtuel dans le dossier .venv
source .venv/bin/activate           # l'active : le prompt affiche (.venv)
pip install -r requirements.txt     # installe les versions figées
python -c "import pymongo; print(pymongo.__version__)"   # vérification : 4.19.0
```

L'activation (`source .venv/bin/activate`) vaut pour le terminal courant uniquement : dans un nouveau terminal, il faut la refaire, comme le `source` du fichier `bd511.env`.

Pour voir ce qui est installé : `pip list`. Pour produire un tel fichier à partir d'un environnement existant : `pip freeze > requirements.txt`.
