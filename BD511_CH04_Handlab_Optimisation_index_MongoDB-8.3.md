# BD511 – Chapitre 4 – Handlab : optimiser une requête lente avec explain, Compass et un index composé

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 4 – Modélisation et indexation |
| **Durée indicative** | 3 h |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop préparée au chapitre 2 (2 vCPU, 4 Go de RAM) : `mongod` actif avec les réglages de production, mongosh, Database Tools et Compass installés |
| **Versions vérifiées le 22/10/2026** | MongoDB Community Server **8.3.13** · mongosh **2.13.0** · Database Tools **100.19.1** · Compass **1.53.0** · Python **3.12** (Ubuntu 24.04) · jq **1.7.1** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. reproduire et mesurer une requête lente, puis la retrouver dans le journal JSON de `mongod` ;
2. lire un plan d'exécution avec `explain()` dans mongosh (modes `queryPlanner`, `executionStats` et `allPlansExecution`) puis dans la vue **Explain Plan** de Compass ;
3. interpréter le passage de COLLSCAN à IXSCAN, le ratio documents examinés / documents renvoyés et le tri en mémoire ;
4. concevoir un **index composé** selon la règle **ESR** (Égalité, Tri, Plage) et **comparer les performances avant et après** ;
5. gérer les index en exploitation, dans mongosh et dans l'onglet **Indexes** de Compass : taille, coût en écriture, utilisation, index masqués, suppression et suivi d'une construction.

## Le scénario

La plate-forme e-learning de l'organisme de formation enregistre chaque activité des stagiaires (vidéo regardée, lecture, quiz, lab) dans la collection `BD511.activites` : un million de documents. Les formateurs se plaignent de la page **« Derniers quiz réussis »** de leur tableau de bord, qui affiche les 10 quiz les plus récents réussis (score ≥ 80) dans une formation : elle met une demi-seconde à s'afficher, et ce temps augmente avec le volume de la collection.

Votre mission : mesurer le problème, l'expliquer, le corriger par un index adapté, prouver le gain, puis laisser la collection dans un état propre (pas d'index inutile).

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Vérification de l'environnement | 10 min |
| 1 | Génération et import du jeu de données `activites` (1 million de documents) | 15 min |
| 2 | Diagnostic de la requête lente : journal de `mongod` et `explain()` dans mongosh | 35 min |
| 3 | Même analyse dans la vue Explain Plan de Compass | 20 min |
| 4 | Index simple, index composés, règle ESR et comparaison avant/après | 55 min |
| 5 | Gestion des index : taille, coût en écriture, utilisation, masquage, suppression, construction | 35 min |
| 6 | Bilan | 10 min |

## Conventions

- Le TP utilise **deux terminaux** (`Ctrl` + `Alt` + `T`, puis `Ctrl` + `Maj` + `T` pour un onglet) :
  - **terminal 1 (bash)** : commandes **bash**, exécutées avec votre compte habituel ; `sudo` est indiqué quand des droits d'administration sont nécessaires ;
  - **terminal 2 (mongosh)** : une session mongosh ouverte à la partie 1.5 et conservée jusqu'à la fin ; les blocs **javascript** se tapent à l'invite `BD511>` (ou se collent en entier : mongosh exécute les lignes dans l'ordre).
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Le jeu de données est généré de façon déterministe : nombres de documents, résultats des requêtes, plans d'exécution, clés et documents examinés sont **identiques** sur toutes les VM. Varient seulement les **durées** (elles dépendent de la puissance de la VM ; seuls les ordres de grandeur comptent), les horodatages, les tailles sur disque et les compteurs d'utilisation.
- Tous les fichiers du TP sont générés dans `~/BD511/ch04` ; l'annexe B en donne la liste.

> **Note formateur.** Le script `importer-activites.sh` (partie 1.4) remet la collection `activites` dans son état initial en une minute environ. L'annexe C donne les commandes de rattrapage pour démarrer directement la partie 4 ou la partie 5.

---

## Partie 0 – Vérification de l'environnement

### 0.1 Créer l'espace de travail

Dans le terminal 1 :

```bash
mkdir -p ~/BD511/ch04/donnees
cd ~/BD511/ch04
```

### 0.2 Contrôler l'installation du chapitre 2

Relancez le contrôle des réglages de production réalisé à la fin du chapitre 2 :

```bash
sudo bash ~/BD511/ch02/check-mongodb.sh | tail -n 1
```

Résultat attendu :

```text
Bilan : 26 OK, 0 KO
```

Si le script est absent ou signale des points KO, reprenez le handlab du chapitre 2 avant de continuer : les mesures de ce TP n'ont de sens que sur une instance réglée comme en production (THP, `swappiness`, ordonnanceur d'E/S, volume XFS…).

### 0.3 Contrôler les prérequis du chapitre

Générez puis exécutez le contrôle propre à ce chapitre (outils, espace disque, réglages du journal des requêtes lentes) :

```bash
cat > ~/BD511/ch04/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.4 : vérifie l'environnement avant le TP
# Usage : bash ~/BD511/ch04/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }
URI="mongodb://127.0.0.1:27017/?appName=BD511-prerequis"

echo "== Serveur et outils MongoDB"
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "Serveur MongoDB $v"; else nok "Serveur MongoDB 8.3 attendu (trouvé : ${v:-absent})"; fi
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
if mongosh --quiet "$URI" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1
then ok "Connexion à mongodb://127.0.0.1:27017"; else nok "Connexion impossible à mongodb://127.0.0.1:27017"; fi
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
v=$(dpkg-query -W -f='${Version}' mongodb-compass 2>/dev/null)
if [[ -n $v ]]; then ok "MongoDB Compass $v"; else nok "Compass absent (chapitre 2, partie 4)"; fi

echo "== Outils et ressources"
v=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
if [[ -n $v ]]; then ok "Python $v (générateur du jeu de données)"; else nok "python3 absent : sudo apt-get install -y python3"; fi
v=$(jq --version 2>/dev/null)
if [[ -n $v ]]; then ok "$v (lecture du journal JSON de mongod)"; else nok "jq absent : sudo apt-get install -y jq"; fi
libre=$(df -BG --output=avail "$HOME" | tail -n 1 | tr -dc '0-9')
if (( libre >= 1 )); then ok "Espace libre dans $HOME : ${libre} Go (1 Go requis)"; else nok "Espace libre dans $HOME : ${libre} Go (1 Go requis)"; fi
libre=$(df -BG --output=avail /var/lib/mongodb | tail -n 1 | tr -dc '0-9')
if (( libre >= 1 )); then ok "Espace libre sur /var/lib/mongodb : ${libre} Go (1 Go requis)"; else nok "Espace libre sur /var/lib/mongodb : ${libre} Go (1 Go requis)"; fi
v=$(mongosh --quiet "$URI" --eval 'const p = db.getSiblingDB("BD511").getProfilingStatus(); print(p.was + " " + p.slowms)' 2>/dev/null)
if [[ $v == "0 100" ]]; then ok "Profiler désactivé, seuil des requêtes lentes slowms = 100 ms (valeurs par défaut)"
else nok "Profiler/slowms modifiés (was slowms = ${v:-?}) : redémarrez mongod (sudo systemctl restart mongod)"; fi

echo
if (( ko == 0 )); then echo "Résultat : environnement prêt pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch04/00-prerequis.sh
```

Résultat attendu (les espaces libres dépendent de votre VM) :

```text
== Serveur et outils MongoDB
  [OK] Serveur MongoDB v8.3.13
  [OK] Service mongod actif
  [OK] Connexion à mongodb://127.0.0.1:27017
  [OK] mongosh 2.13.0
  [OK] Database Tools 100.19.1
  [OK] MongoDB Compass 1.53.0
== Outils et ressources
  [OK] Python 3.12.3 (générateur du jeu de données)
  [OK] jq-1.7.1 (lecture du journal JSON de mongod)
  [OK] Espace libre dans /home/stagiaire : 5 Go (1 Go requis)
  [OK] Espace libre sur /var/lib/mongodb : 8 Go (1 Go requis)
  [OK] Profiler désactivé, seuil des requêtes lentes slowms = 100 ms (valeurs par défaut)

Résultat : environnement prêt pour le TP.
```

---

## Partie 1 – Le jeu de données `activites`

### 1.1 Le modèle de données

Chaque **activité** d'un stagiaire est un petit document autonome :

| Champ | Type BSON | Exemple | Rôle |
| --- | --- | --- | --- |
| `_id` | ObjectId | `ObjectId('659200fca5114c0000000000')` | identifiant ; ses 4 premiers octets contiennent l'horodatage |
| `stagiaire_id` | string | `"STG0245"` | référence vers `stagiaires._id` (chapitre 3) |
| `formation_id` | string | `"PY201"` | référence vers `formations._id` (chapitre 3) |
| `type` | string | `"video"`, `"lecture"`, `"quiz"`, `"lab"` | nature de l'activité |
| `date` | date | `ISODate('2024-01-01T00:02:04.000Z')` | instant de l'activité (UTC) |
| `appareil` | string | `"ordinateur"`, `"mobile"`, `"tablette"` | appareil utilisé |
| `duree_s` | int | `973` | durée en secondes |
| `score` | int | `77` | note sur 100, **uniquement** pour les quiz et les labs (champ absent sinon) |

Ce modèle applique les principes vus en cours :

- **On modélise à partir des requêtes de l'application.** La plate-forme lit les activités par formation (tableau de bord des formateurs) et par stagiaire (page « Mon activité ») ; ces deux accès guideront les index.
- **Relation 1-N non bornée → référence.** Un stagiaire accumule des milliers d'activités, sans limite. Les imbriquer dans un tableau du document `stagiaires` alourdirait chaque lecture du stagiaire, rendrait les écritures de plus en plus coûteuses et finirait par dépasser la limite de 16 Mo par document (anti-modèle du *tableau non borné*). Chaque activité porte donc la **référence** de son stagiaire et de sa formation.
- **Documents petits et homogènes** (142 octets en moyenne) : un index composé sur quelques champs y est très efficace.
- **Schéma flexible** : le champ `score` est absent des vidéos et lectures plutôt que mis à `null` ; dans un index, un champ absent est indexé avec la valeur `null`.

### 1.2 Générer le fichier de données

Les données sont produites par un script Python qui n'utilise que la bibliothèque standard. Son générateur pseudo-aléatoire est déterministe : tout le monde obtient exactement le même fichier, ce que la somme de contrôle de l'étape suivante vérifie.

```bash
cat > ~/BD511/ch04/generer_activites.py <<'EOF'
#!/usr/bin/env python3
"""generer_activites.py - BD511 ch.4 : génère le journal d'activité de la plate-forme e-learning.

Fichier produit dans le répertoire courant :
  activites.json   1 000 000 activités, un document Extended JSON par ligne -> mongoimport

Une activité = un événement (vidéo regardée, lecture, quiz, lab) d'un stagiaire dans une formation.
Les champs stagiaire_id et formation_id référencent les collections stagiaires et formations du chapitre 3.
Toutes les données sont fictives. Le générateur pseudo-aléatoire est déterministe : le fichier
est identique, octet pour octet, sur toutes les machines (somme de contrôle dans SHA256SUMS).
Bibliothèque standard uniquement ; durée : 15 à 30 secondes.
"""
import json
from datetime import datetime, timedelta, timezone

M64 = 0xFFFFFFFFFFFFFFFF
NOMBRE = 1_000_000
DEBUT = datetime(2024, 1, 1, tzinfo=timezone.utc)


class Alea:
    """Générateur xorshift64* : même suite de nombres sur toutes les plates-formes."""

    def __init__(self, graine):
        self.etat = graine & M64 or 1

    def suivant(self):
        x = self.etat
        x ^= x >> 12
        x ^= (x << 25) & M64
        x ^= x >> 27
        self.etat = x
        return (x * 0x2545F4914F6CDD1D) & M64

    def entier(self, a, b):
        return a + self.suivant() % (b - a + 1)


def table_ponderee(poids):
    """Liste où chaque valeur apparaît autant de fois que son poids : un tirage uniforme y suit les poids."""
    return [valeur for valeur, p in poids for _ in range(p)]


# Les 24 formations du catalogue, pondérées par leur popularité
FORMATIONS = table_ponderee([
    ("BD511", 8), ("BD512", 7), ("BD513", 3), ("BD514", 4), ("BD515", 2), ("BD516", 6), ("BD520", 5),
    ("BG601", 4), ("BG602", 4), ("BG603", 6), ("BG604", 2), ("BG605", 3), ("BG606", 2),
    ("IA101", 6), ("IA102", 5), ("IA103", 5),
    ("DO301", 5), ("DO302", 5), ("DO303", 3), ("DO304", 3),
    ("SY401", 4), ("SY402", 2), ("PY201", 5), ("PY202", 3)])
TYPES = table_ponderee([("video", 45), ("lecture", 20), ("quiz", 20), ("lab", 15)])
APPAREILS = table_ponderee([("ordinateur", 70), ("mobile", 20), ("tablette", 10)])
DUREES = {"video": (60, 1800), "lecture": (30, 900), "quiz": (120, 1200), "lab": (600, 5400)}


def main():
    alea = Alea(5114)
    instant = DEBUT
    with open("activites.json", "w", encoding="utf-8") as sortie:
        for i in range(NOMBRE):
            # une activité toutes les 88 secondes en moyenne, dans l'ordre chronologique
            instant += timedelta(seconds=alea.entier(0, 176))
            type_ = TYPES[alea.entier(0, len(TYPES) - 1)]
            doc = {
                # ObjectId déterministe : horodatage de l'activité (4 octets) + numéro d'ordre
                "_id": {"$oid": f"{int(instant.timestamp()):08x}a5114c{i:010x}"},
                "stagiaire_id": f"STG{alea.entier(1, 300):04d}",
                "formation_id": FORMATIONS[alea.entier(0, len(FORMATIONS) - 1)],
                "type": type_,
                "date": {"$date": instant.strftime("%Y-%m-%dT%H:%M:%SZ")},
                "appareil": APPAREILS[alea.entier(0, len(APPAREILS) - 1)],
                "duree_s": alea.entier(*DUREES[type_]),
            }
            if type_ in ("quiz", "lab"):
                # score sur 100, centré vers 70 (moyenne de trois tirages) ; absent pour les vidéos et lectures
                doc["score"] = (alea.entier(20, 100) + alea.entier(30, 100) + alea.entier(40, 100)) // 3
            sortie.write(json.dumps(doc, separators=(",", ":")) + "\n")
    print(f"activites.json : {NOMBRE} activités, du {DEBUT:%d/%m/%Y} au {instant:%d/%m/%Y}")


if __name__ == "__main__":
    main()
EOF
cd ~/BD511/ch04/donnees
python3 ../generer_activites.py
```

Résultat attendu (après 15 à 30 secondes) :

```text
activites.json : 1000000 activités, du 01/01/2024 au 15/10/2026
```

> Le jeu de données est aussi fourni tout fait, compressé (`activites.json.gz`, 20 Mo), dans l'archive `BD511_CH04_fichiers.zip` qui accompagne ce handlab. Si le générateur ne peut pas être exécuté, copiez ce fichier dans `~/BD511/ch04/donnees/` : le script d'import de la partie 1.4 le décompresse et vérifie sa somme de contrôle.

### 1.3 Vérifier l'intégrité du fichier

```bash
cat > ~/BD511/ch04/donnees/SHA256SUMS <<'EOF'
5f3b8145768ba5995ded0fdbe995dec762768cfd079b7849d3925c4d7e818ba3  activites.json
EOF
cd ~/BD511/ch04/donnees
sha256sum -c SHA256SUMS
ls -lh activites.json
head -n 2 activites.json
```

Résultat attendu (date du fichier variable) :

```text
activites.json: OK
-rw-rw-r-- 1 stagiaire stagiaire 180M Oct 22 17:12 activites.json
{"_id":{"$oid":"659200fca5114c0000000000"},"stagiaire_id":"STG0245","formation_id":"PY201","type":"quiz","date":{"$date":"2024-01-01T00:02:04Z"},"appareil":"ordinateur","duree_s":973,"score":77}
{"_id":{"$oid":"65920197a5114c0000000001"},"stagiaire_id":"STG0225","formation_id":"PY201","type":"video","date":{"$date":"2024-01-01T00:04:39Z"},"appareil":"tablette","duree_s":1716}
```

Le fichier est au format **Extended JSON**, un document par ligne : `$oid` et `$date` conservent les types BSON `ObjectId` et `date` à l'import (chapitre 3).

### 1.4 Importer la collection

Le script suivant (re)crée la collection dans son **état initial** : il recrée le fichier s'il est absent ou altéré (en décompressant `activites.json.gz` s'il est présent, sinon avec le générateur), supprime la collection existante (`--drop`, index compris) puis importe le fichier. Il servira aussi de « remise à zéro » en cas de fausse manœuvre.

```bash
cat > ~/BD511/ch04/importer-activites.sh <<'EOF'
#!/usr/bin/env bash
# importer-activites.sh - BD511 ch.4 : (re)crée la collection BD511.activites dans son état initial
#   1 000 000 documents, aucun index secondaire (seulement l'index _id_).
#   Si activites.json est absent ou altéré, le décompresse depuis activites.json.gz (archive du TP)
#   ou, à défaut, le régénère ; puis l'importe. Durée : environ 1 minute.
# Usage : bash ~/BD511/ch04/importer-activites.sh
set -euo pipefail
cd "$HOME/BD511/ch04/donnees"

if ! sha256sum --quiet --check SHA256SUMS >/dev/null 2>&1; then
  if [[ -f activites.json.gz ]]; then
    echo "== Décompression de activites.json.gz (jeu de données fourni avec le TP)"
    gunzip -c activites.json.gz > activites.json
  else
    echo "== Génération de activites.json"
    python3 ../generer_activites.py
  fi
  sha256sum --check SHA256SUMS
fi

echo "== Import dans BD511.activites (la collection est d'abord supprimée, index compris)"
mongoimport --uri "mongodb://127.0.0.1:27017/?appName=BD511-import" \
  --db BD511 --collection activites --drop \
  --writeConcern '{w: "majority"}' --numInsertionWorkers 2 \
  --file activites.json

echo "== Contrôle"
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-import" --eval '
  const n = db.activites.countDocuments();
  const index = db.activites.getIndexes().map(i => i.name).join(", ");
  print(`BD511.activites : ${n} documents ; index : ${index}`);'
EOF
bash ~/BD511/ch04/importer-activites.sh
```

Résultat attendu (horodatages et progression variables, l'import dure de 25 à 60 secondes) :

```text
== Import dans BD511.activites (la collection est d'abord supprimée, index compris)
2026-10-22T17:12:47.773+0200	connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
2026-10-22T17:12:47.785+0200	dropping: `BD511.activites`
2026-10-22T17:12:50.785+0200	[###.....................] BD511.activites	22.6MB/179MB (12.6%)
…
2026-10-22T17:13:11.285+0200	[########################] BD511.activites	179MB/179MB (100.0%)
2026-10-22T17:13:11.285+0200	1000000 document(s) imported successfully. 0 document(s) failed to import.
== Contrôle
BD511.activites : 1000000 documents ; index : _id_
```

Les options de `mongoimport` sont celles du chapitre 3 : `w: "majority"` (l'écriture est confirmée de façon durable), et 2 *workers* d'insertion, un par vCPU. La collection n'a pour l'instant **qu'un seul index**, `_id_`, créé automatiquement par MongoDB.

### 1.5 Explorer la collection

Ouvrez le **terminal 2** et la session mongosh qui servira jusqu'à la fin du TP. Le paramètre `appName=BD511-tp4` identifie vos commandes dans le journal du serveur, à côté de celles de « l'application » (`BD511-appli`).

```bash
mongosh "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4"
```

```javascript
db.activites.countDocuments()
db.activites.findOne({ _id: ObjectId("659200fca5114c0000000000") })
db.activites.getIndexes()
```

Résultat attendu :

```text
1000000
{
  _id: ObjectId('659200fca5114c0000000000'),
  stagiaire_id: 'STG0245',
  formation_id: 'PY201',
  type: 'quiz',
  date: ISODate('2024-01-01T00:02:04.000Z'),
  appareil: 'ordinateur',
  duree_s: 973,
  score: 77
}
[ { v: 2, key: { _id: 1 }, name: '_id_' } ]
```

Mesurez le volume de la collection et la taille du cache de WiredTiger :

```javascript
const st = db.activites.stats()
print(`${st.count} documents de ${st.avgObjSize} octets en moyenne`)
print(`données : ${Math.round(st.size / 2 ** 20)} Mio non compressés, ${Math.round(st.storageSize / 2 ** 20)} Mio sur disque`)
print(`index   : ${st.nindexes} index, ${Math.round(st.totalIndexSize / 2 ** 20)} Mio`)
print(`cache WiredTiger : ${Math.round(db.serverStatus().wiredTiger.cache["maximum bytes configured"] / 2 ** 20)} Mio`)
```

Résultat attendu (taille sur disque et cache variables ; par défaut, le cache vaut 50 % de (RAM − 1 Go)) :

```text
1000000 documents de 142 octets en moyenne
données : 136 Mio non compressés, 33 Mio sur disque
index   : 1 index, 19 Mio
cache WiredTiger : 1435 Mio
```

La collection entière tient dans le cache : toutes les mesures du TP se font **sans lecture disque**. Sur un serveur dont les données dépassent le cache, un parcours complet coûterait en plus des milliers d'entrées/sorties.

Enfin, mesurez la **sélectivité** de chacun des critères de la requête de la page « Derniers quiz réussis » :

```javascript
db.activites.countDocuments({ formation_id: "BD511" })
db.activites.countDocuments({ formation_id: "BD511", type: "quiz" })
db.activites.countDocuments({ formation_id: "BD511", type: "quiz", score: { $gte: 80 } })
```

Résultat attendu :

```text
78523
15816
1742
```

| Critères cumulés | Documents | Part de la collection |
| --- | ---: | ---: |
| `formation_id: "BD511"` | 78 523 | 7,9 % |
| + `type: "quiz"` | 15 816 | 1,6 % |
| + `score: { $gte: 80 }` | 1 742 | 0,17 % |
| + tri par date décroissante, 10 premiers | **10** | 0,001 % |

La page n'a besoin que de **10 documents sur un million**. Gardez ces chiffres en tête : ils permettent de juger chaque plan d'exécution.

---

## Partie 2 – Diagnostic de la requête lente dans mongosh

### 2.1 Reproduire le symptôme

Le script suivant exécute la requête de la page, exactement comme le fait l'application, et affiche la page trois fois de suite pour mesurer la durée de chaque requête. Dans le terminal 1 :

```bash
cat > ~/BD511/ch04/requete-lente.js <<'EOF'
// requete-lente.js - BD511 ch.4 : requête de la page « Derniers quiz réussis » de la plate-forme
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-appli" ~/BD511/ch04/requete-lente.js
// appName identifie l'application dans le journal de mongod et dans db.currentOp().
// La page est affichée 3 fois de suite : la durée de chaque requête est mesurée côté client.
const formation = "BD511";
const requete = () => db.activites
  .find({ formation_id: formation, type: "quiz", score: { $gte: 80 } })
  .sort({ date: -1 })
  .limit(10)
  .toArray();

const durees = [];
let quiz = [];
for (let i = 0; i < 3; i++) {
  const debut = Date.now();
  quiz = requete();
  durees.push(Date.now() - debut);
}

print(`Derniers quiz réussis (score >= 80) - formation ${formation}`);
for (const q of quiz) {
  const date = q.date.toISOString().slice(0, 16).replace("T", " ");
  print(`  ${date}  ${q.stagiaire_id}  ${String(q.score).padStart(3)}  ${q.appareil}`);
}
print(`${quiz.length} quiz ; durée des 3 affichages : ${durees.join(" ms, ")} ms`);
EOF
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-appli" ~/BD511/ch04/requete-lente.js
```

Résultat attendu (durées variables) :

```text
Derniers quiz réussis (score >= 80) - formation BD511
  2026-10-15 17:48  STG0200   86  ordinateur
  2026-10-15 07:09  STG0158   85  ordinateur
  2026-10-14 13:14  STG0002   83  mobile
  2026-10-13 22:37  STG0136   81  ordinateur
  2026-10-13 20:11  STG0286   93  tablette
  2026-10-12 10:58  STG0086   84  ordinateur
  2026-10-11 21:12  STG0066   82  ordinateur
  2026-10-11 18:02  STG0010   81  mobile
  2026-10-11 16:09  STG0281   84  mobile
  2026-10-11 14:48  STG0296   82  ordinateur
10 quiz ; durée des 3 affichages : 689 ms, 467 ms, 440 ms
```

Près d'une demi-seconde pour afficher dix lignes, à chaque affichage : la répétition ne change rien, le problème ne vient ni du réseau ni d'un cache « froid ». Avec 50 formateurs qui consultent leur tableau de bord, le serveur passerait l'essentiel de son temps processeur sur cette seule requête.

### 2.2 Retrouver la requête dans le journal de `mongod`

Toute opération qui dure plus de **`slowms` = 100 ms** (valeur par défaut) est écrite dans le journal JSON du serveur, avec le message `Slow query`, même lorsque le profiler est désactivé. C'est souvent ainsi qu'un administrateur découvre une requête lente. Vérifiez le réglage dans le terminal 2 :

```javascript
db.getProfilingStatus()
```

Résultat attendu :

```text
{
  was: 0,
  slowms: 100,
  slowinprogms: Long('5000'),
  sampleRate: 1,
  ok: 1
}
```

`was: 0` : le profiler est désactivé ; `sampleRate: 1` : toutes les opérations lentes sont journalisées. Le profiler, la collection `system.profile` et l'analyse des journaux en volume sont traités au chapitre 8.

Dans le terminal 1, extrayez du journal les requêtes lentes de l'application, grâce à son `appName` :

```bash
sudo jq -c 'select(.msg == "Slow query" and .attr.appName == "BD511-appli")
  | {heure: .t["$date"][11:19], ns: .attr.ns, plan: .attr.planSummary, cles: .attr.keysExamined,
     docs: .attr.docsExamined, tri: .attr.hasSortStage, renvoyes: .attr.nreturned, ms: .attr.durationMillis}' \
  /var/log/mongodb/mongod.log | tail -n 3
```

Résultat attendu (heures et durées variables) :

```text
{"heure":"17:30:12","ns":"BD511.activites","plan":"COLLSCAN","cles":0,"docs":1000000,"tri":true,"renvoyes":10,"ms":688}
{"heure":"17:30:13","ns":"BD511.activites","plan":"COLLSCAN","cles":0,"docs":1000000,"tri":true,"renvoyes":10,"ms":466}
{"heure":"17:30:13","ns":"BD511.activites","plan":"COLLSCAN","cles":0,"docs":1000000,"tri":true,"renvoyes":10,"ms":439}
```

Le journal pose déjà le diagnostic :

| Champ du journal | Valeur | Signification |
| --- | --- | --- |
| `planSummary` | `COLLSCAN` | *collection scan* : aucun index n'a été utilisé, toute la collection a été parcourue |
| `keysExamined` | 0 | aucune entrée d'index lue |
| `docsExamined` | 1 000 000 | chaque document a été chargé puis comparé au filtre |
| `hasSortStage` | `true` | le tri par date a été fait en mémoire, après la lecture |
| `nreturned` | 10 | pour 10 documents renvoyés |
| `durationMillis` | ≈ 500 | durée côté serveur |

> L'entrée complète contient aussi la requête (`command`), son empreinte `queryShapeHash`, la clé du cache de plans `planCacheKey`, le temps processeur `cpuNanos`… Affichez la dernière en entier avec `sudo jq -c 'select(.msg == "Slow query" and .attr.appName == "BD511-appli")' /var/log/mongodb/mongod.log | tail -n 1 | jq .`

### 2.3 Le plan choisi : `explain("queryPlanner")`

Dans le terminal 2, définissez le filtre et le tri de la requête, puis demandez au planificateur **quel plan il choisirait**, sans exécuter la requête :

```javascript
const filtre = { formation_id: "BD511", type: "quiz", score: { $gte: 80 } }
const tri = { date: -1 }
const plan = db.activites.find(filtre).sort(tri).limit(10).explain("queryPlanner")
Object.keys(plan)
plan.queryPlanner.winningPlan
plan.queryPlanner.rejectedPlans
```

Résultat attendu :

```text
[
  'explainVersion',
  'queryPlanner',
  'queryShapeHash',
  'command',
  'serverInfo',
  'serverParameters',
  'ok'
]
{
  isCached: false,
  stage: 'SORT',
  sortPattern: { date: -1 },
  memLimit: 104857600,
  limitAmount: 10,
  type: 'simple',
  inputStage: {
    stage: 'COLLSCAN',
    filter: {
      '$and': [
        { formation_id: { '$eq': 'BD511' } },
        { type: { '$eq': 'quiz' } },
        { score: { '$gte': 80 } }
      ]
    },
    nss: 'BD511.activites',
    direction: 'forward'
  }
}
[]
```

Un plan est un **arbre d'étapes** (*stages*) : chaque étape reçoit les documents de son `inputStage` et transmet les siens à l'étape parente. Il se lit donc **de l'intérieur vers l'extérieur** :

1. `COLLSCAN` parcourt toute la collection dans l'ordre naturel (`direction: 'forward'`) et ne laisse passer que les documents conformes au `filter` ;
2. `SORT` trie ces documents par `date` décroissante (`sortPattern`) en ne gardant que les 10 premiers (`limitAmount`). Ce tri bloquant est fait en mémoire, dans la limite de `memLimit` = 104 857 600 octets (100 Mo) ; au-delà, MongoDB écrit des fichiers temporaires sur disque (`allowDiskUseByDefault`).

`rejectedPlans` est vide : sans index utilisable, le planificateur n'avait **aucune alternative**.

### 2.4 Les statistiques d'exécution : `explain("executionStats")`

Le mode `executionStats` **exécute** le plan gagnant et rapporte ce qu'il a coûté :

```javascript
const exec = db.activites.find(filtre).sort(tri).limit(10).explain("executionStats")
exec.executionStats
```

Résultat attendu (durées, `saveState` et `restoreState` variables) :

```text
{
  executionSuccess: true,
  nReturned: 10,
  executionTimeMillis: 497,
  totalKeysExamined: 0,
  totalDocsExamined: 1000000,
  executionStages: {
    isCached: false,
    stage: 'SORT',
    nReturned: 10,
    executionTimeMillisEstimate: 482,
    works: 1000012,
    advanced: 10,
    needTime: 1000001,
    needYield: 0,
    saveState: 25,
    restoreState: 25,
    isEOF: 1,
    sortPattern: { date: -1 },
    memLimit: 104857600,
    limitAmount: 10,
    type: 'simple',
    totalDataSizeSorted: 1806,
    usedDisk: false,
    spills: 0,
    spilledRecords: 0,
    spilledBytes: 0,
    spilledDataStorageSize: 0,
    peakTrackedMemBytes: 1820,
    inputStage: {
      stage: 'COLLSCAN',
      filter: {
        '$and': [
          { formation_id: { '$eq': 'BD511' } },
          { type: { '$eq': 'quiz' } },
          { score: { '$gte': 80 } }
        ]
      },
      nReturned: 1742,
      executionTimeMillisEstimate: 470,
      works: 1000001,
      advanced: 1742,
      needTime: 998258,
      needYield: 0,
      saveState: 25,
      restoreState: 25,
      isEOF: 1,
      nss: 'BD511.activites',
      direction: 'forward',
      docsExamined: 1000000
    }
  }
}
```

Les quatre indicateurs à regarder en premier :

| Indicateur | Valeur | Lecture |
| --- | ---: | --- |
| `nReturned` | 10 | documents renvoyés au client |
| `totalKeysExamined` | 0 | entrées d'index lues |
| `totalDocsExamined` | 1 000 000 | documents chargés et comparés au filtre |
| `executionTimeMillis` | ≈ 500 | durée côté serveur, choix du plan compris (hors réseau) |

Le **ratio documents examinés / documents renvoyés** vaut ici 1 000 000 / 10 = **100 000** : pour chaque document utile, le serveur en lit 100 000. Une requête bien indexée a un ratio proche de **1**.

Dans chaque étape : `works` compte les unités de travail, `advanced` les résultats transmis à l'étape parente, `needTime` les unités qui n'ont rien produit (document écarté par le filtre). L'étape `COLLSCAN` a transmis 1 742 documents (`advanced`) sur 1 000 000 lus : le filtre en a rejeté 998 258 (`needTime`). L'étape `SORT` n'a gardé que les 10 plus récents.

### 2.5 Les trois niveaux de détail d'`explain()`

| Mode | Exécute la requête ? | Contenu | Usage |
| --- | --- | --- | --- |
| `"queryPlanner"` (défaut) | non | plan gagnant et plans rejetés | vérifier sans risque l'index choisi, même en production |
| `"executionStats"` | oui, le plan gagnant | + statistiques d'exécution | mesurer le coût réel d'une requête |
| `"allPlansExecution"` | oui | + statistiques de la phase d'essai de **chaque** plan candidat | comprendre le choix du planificateur (partie 4.6) |

> En production, `executionStats` coûte autant que la requête elle-même : sur une requête de plusieurs secondes, commencez par `queryPlanner`. `explain()` ne lit ni n'alimente le cache de plans (partie 4.6).

### 2.6 Un résumé lisible des plans

Les sorties d'`explain()` sont longues. Le script suivant définit une fonction `resume()` qui extrait l'essentiel d'un plan et ajoute un diagnostic. Créez-le dans le terminal 1 :

```bash
cat > ~/BD511/ch04/explain-resume.js <<'EOF'
// explain-resume.js - BD511 ch.4 : résumé lisible d'un plan d'exécution (explain "executionStats")
// Chargement dans mongosh : load(process.env.HOME + "/BD511/ch04/explain-resume.js")
// Usage : resume(db.collection.find(filtre).sort(tri).limit(n))   ou   resume(resultatDeExplain)

// Étapes d'un plan, de la feuille (lecture des données) à la racine (envoi au client)
function etapesDuPlan(plan) {
  const etapes = [];
  for (let e = plan; e; e = e.inputStage || (e.inputStages && e.inputStages[0])) etapes.unshift(e);
  return etapes;
}

function formatCle(cle) {
  return "{ " + Object.entries(cle).map(([champ, sens]) => `${champ}: ${sens}`).join(", ") + " }";
}

function resume(requete) {
  const exp = typeof requete.explain === "function" ? requete.explain("executionStats") : requete;
  const qp = exp.queryPlanner;
  const etapes = etapesDuPlan(qp.winningPlan.queryPlan || qp.winningPlan);
  const s = exp.executionStats;
  const scan = etapes.find(e => e.stage === "IXSCAN");
  const triMemoire = etapes.some(e => e.stage === "SORT");
  const ratio = s.nReturned > 0 ? Math.round(s.totalDocsExamined / s.nReturned) : s.totalDocsExamined;
  const rejetes = qp.rejectedPlans.map(p => {
    const ix = etapesDuPlan(p.queryPlan || p).find(e => e.indexName);
    return ix ? ix.indexName : "COLLSCAN";
  });

  print(`Plan d'exécution       : ${etapes.map(e => e.stage).join(" → ")}`);
  print(`Index utilisé          : ${scan ? scan.indexName + " " + formatCle(scan.keyPattern) : "aucun"}`);
  print(`Tri en mémoire (SORT)  : ${triMemoire ? "oui" : "non"}`);
  print(`Documents renvoyés     : ${s.nReturned}`);
  print(`Clés d'index examinées : ${s.totalKeysExamined}`);
  print(`Documents examinés     : ${s.totalDocsExamined}`);
  print(`Examinés / renvoyés    : ${ratio}`);
  print(`Durée côté serveur     : ${s.executionTimeMillis} ms`);
  print(`Plans rejetés          : ${rejetes.length ? rejetes.join(", ") : "aucun"}`);

  const diagnostic = [];
  if (etapes.some(e => e.stage === "COLLSCAN"))
    diagnostic.push("COLLSCAN : toute la collection est lue, aucun index n'est utilisé.");
  if (triMemoire)
    diagnostic.push("SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).");
  if (ratio > 10)
    diagnostic.push(`ratio ${ratio} : la plupart des documents lus sont écartés ensuite.`);
  if (s.totalDocsExamined === 0 && s.nReturned > 0)
    diagnostic.push("requête couverte : résultats lus dans l'index, aucun document chargé.");
  if (diagnostic.length === 0)
    diagnostic.push("plan efficace : chaque document lu est renvoyé, sans tri en mémoire.");
  for (const d of diagnostic) print(`Diagnostic             : ${d}`);
}
EOF
```

Chargez-le dans la session mongosh (terminal 2) et appliquez-le à la requête :

```javascript
load(process.env.HOME + "/BD511/ch04/explain-resume.js")
resume(db.activites.find(filtre).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
true
Plan d'exécution       : COLLSCAN → SORT
Index utilisé          : aucun
Tri en mémoire (SORT)  : oui
Documents renvoyés     : 10
Clés d'index examinées : 0
Documents examinés     : 1000000
Examinés / renvoyés    : 100000
Durée côté serveur     : 650 ms
Plans rejetés          : aucun
Diagnostic             : COLLSCAN : toute la collection est lue, aucun index n'est utilisé.
Diagnostic             : SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).
Diagnostic             : ratio 100000 : la plupart des documents lus sont écartés ensuite.
```

Le plan affiché ici **dans l'ordre d'exécution** (`COLLSCAN → SORT`) est l'arbre de la partie 2.3 lu de la feuille vers la racine. Le diagnostic est posé : il faut un index qui évite le parcours complet **et** le tri en mémoire.

---

## Partie 3 – La vue Explain Plan de Compass

Compass présente le même plan d'exécution sous forme graphique. Gardez le terminal 2 ouvert : la session mongosh resservira à la partie 4.

### 3.1 Ouvrir la collection

1. Lancez **MongoDB Compass** (menu des applications ▸ **MongoDB Compass**, ou `nohup mongodb-compass > /dev/null 2>&1 &` dans le terminal 1).
2. Dans le panneau de gauche, section **CONNECTIONS**, survolez la connexion **BD511 - local** enregistrée au chapitre 2 et cliquez sur **CONNECT**.
3. Dépliez la base **BD511** et cliquez sur la collection **activites**.

> Si la connexion n'existe plus, recréez-la : **Add new connection**, champ **URI** `mongodb://127.0.0.1:27017/?directConnection=true`, champ **Name** `BD511 - local`, puis **Save & Connect**.

L'onglet **Documents** s'ouvre ; son badge indique **1M** documents et celui de l'onglet **Indexes** indique **1** index.

### 3.2 Saisir la requête de la page

1. Dans la barre de requête, cliquez dans le champ de filtre (`Type a query: { field: 'value' }`) et saisissez :

   ```text
   { formation_id: "BD511", type: "quiz", score: { $gte: 80 } }
   ```

2. Cliquez sur **Options** (à droite de la barre) : les champs **Project**, **Sort**, **Collation**, **Index Hint**, **Max Time MS** (60000 par défaut), **Skip** et **Limit** apparaissent.
3. Dans **Sort**, saisissez `{ date: -1 }` ; dans **Limit**, saisissez `10`.
4. Cliquez sur **Find**.

Le compteur affiche **1 – 10 of 10**. Le premier document est celui du stagiaire **STG0200**, daté du `2026-10-15T17:48:47`, avec un score de **86** : le même résultat que le script de la partie 2.1.

### 3.3 Lire le plan dans la vue Explain Plan

Cliquez sur **Explain** (à gauche de **Reset** et **Find**). La fenêtre **Explain Plan** s'ouvre sur la vue **Visual Tree** :

- l'arbre contient deux nœuds : **COLLSCAN** en bas (**Returned 1742**, **Documents Examined: 1000000**) et **SORT** au-dessus (**Returned 10**). La flèche montre le sens des données : de la lecture (en bas) vers le résultat (en haut) ;
- chaque nœud affiche son **Execution Time** en millisecondes dans un cercle (valeur variable) ;
- cliquez sur le chevron **>** devant **COLLSCAN** : le détail de l'étape s'affiche, dont le `filter` `$and` que le parcours applique à chaque document.

Le panneau **Query Performance Summary**, à droite, résume le plan :

| Ligne affichée | Valeur | Champ d'`explain()` correspondant |
| --- | --- | --- |
| *documents returned* | 10 | `executionStats.nReturned` |
| *documents examined* | 1000000 | `executionStats.totalDocsExamined` |
| *ms execution time* | ≈ 500 à 800 | `executionStats.executionTimeMillis` |
| **Is sorted in memory** | | présence d'une étape `SORT` |
| *index keys examined* | 0 | `executionStats.totalKeysExamined` |
| **No index available for this query.** | | étape `COLLSCAN` |

À côté du dernier message, un badge **INSIGHT** apparaît au survol de l'ampoule. Cliquez dessus : la bulle **Query executed without index** recommande de créer un index si la requête est fréquente, avec un bouton **Create index**. Ne l'utilisez pas maintenant (l'index sera conçu à la partie 4) et fermez la bulle avec la croix.

Cliquez enfin sur **Raw Output** : c'est la sortie brute d'`explain()`, la même qu'en partie 2.4 (`queryPlanner`, `winningPlan`, `executionStats`…). Revenez sur **Visual Tree**, puis fermez la fenêtre avec **Close**.

> Le bouton **Interpret**, en haut à droite, demande une explication en langage naturel à l'assistant d'IA de Compass ; il nécessite un compte MongoDB Atlas et n'est pas utilisé dans ce TP.

---

## Partie 4 – Créer l'index et comparer avant/après

### 4.1 Mesurer l'état « avant »

On ne corrige pas sans mesure de référence. Le script suivant exécute la requête une fois par index existant, en imposant l'index avec `hint()` (`{ $natural: 1 }` impose le parcours complet), puis sans contrainte (« choix du planificateur »). Pour chaque variante, il relève le plan, les clés et documents examinés, et la **médiane** de 5 exécutions complètes. Dans le terminal 1 :

```bash
cat > ~/BD511/ch04/comparer.js <<'EOF'
// comparer.js - BD511 ch.4 : compare les plans possibles de la requête lente, un par index existant
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" ~/BD511/ch04/comparer.js
// Chaque variante est imposée avec hint() ; la durée est la médiane de 5 exécutions complètes.
const filtre = { formation_id: "BD511", type: "quiz", score: { $gte: 80 } };
const tri = { date: -1 };
const LIMITE = 10;
const ESSAIS = 5;

function etapesDuPlan(plan) {
  const etapes = [];
  for (let e = plan; e; e = e.inputStage || (e.inputStages && e.inputStages[0])) etapes.unshift(e);
  return etapes;
}

function mesurer(indication) {
  const requete = () => {
    const curseur = db.activites.find(filtre).sort(tri).limit(LIMITE);
    return indication ? curseur.hint(indication) : curseur;
  };
  const exp = requete().explain("executionStats");
  const etapes = etapesDuPlan(exp.queryPlanner.winningPlan.queryPlan || exp.queryPlanner.winningPlan);
  const durees = [];
  for (let i = 0; i < ESSAIS; i++) {
    const debut = Date.now();
    requete().toArray();
    durees.push(Date.now() - debut);
  }
  durees.sort((a, b) => a - b);
  const scan = etapes.find(e => e.indexName);
  return {
    plan: etapes.map(e => e.stage).join(" → "),
    index: scan ? scan.indexName : "aucun (COLLSCAN)",
    cles: exp.executionStats.totalKeysExamined,
    docs: exp.executionStats.totalDocsExamined,
    renvoyes: exp.executionStats.nReturned,
    triMemoire: etapes.some(e => e.stage === "SORT") ? "oui" : "non",
    duree: durees[Math.floor(ESSAIS / 2)],
  };
}

const variantes = [["Sans index ($natural)", { $natural: 1 }]];
const masques = [];
for (const ix of db.activites.getIndexes()) {
  if (ix.name === "_id_") continue;
  if (ix.hidden) masques.push(ix.name);
  else variantes.push([ix.name, ix.name]);
}
variantes.push(["Choix du planificateur", null]);

print("Requête : find(" + EJSON.stringify(filtre) + ").sort(" + EJSON.stringify(tri) + ").limit(" + LIMITE + ")");
print("");
print("Variante (hint)".padEnd(27) + "Plan d'exécution".padEnd(25) + "Clés lues".padStart(10) +
      "Docs lus".padStart(10) + "  Tri mémoire" + "Durée".padStart(9));
let choix;
for (const [nom, indication] of variantes) {
  const m = mesurer(indication);
  if (indication === null) choix = m.index;
  print(nom.padEnd(27) + m.plan.padEnd(25) + String(m.cles).padStart(10) + String(m.docs).padStart(10) +
        "  " + m.triMemoire.padEnd(11) + `${m.duree} ms`.padStart(9));
}
print("");
print(`Index retenu par le planificateur : ${choix}`);
if (masques.length) print(`Index masqués (non testés) : ${masques.join(", ")}`);
EOF
cd ~/BD511/ch04
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" comparer.js | tee mesures-avant.txt
```

Résultat attendu (durées variables) :

```text
Requête : find({"formation_id":"BD511","type":"quiz","score":{"$gte":80}}).sort({"date":-1}).limit(10)

Variante (hint)            Plan d'exécution          Clés lues  Docs lus  Tri mémoire    Durée
Sans index ($natural)      COLLSCAN → SORT                   0   1000000  oui           465 ms
Choix du planificateur     COLLSCAN → SORT                   0   1000000  oui           480 ms

Index retenu par le planificateur : aucun (COLLSCAN)
```

Le fichier `mesures-avant.txt` conserve cette référence.

### 4.2 Premier essai : un index simple sur `formation_id`

Le réflexe le plus courant consiste à indexer le premier champ du filtre. Dans le terminal 2 :

```javascript
db.activites.createIndex({ formation_id: 1 }, { name: "formation" })
resume(db.activites.find(filtre).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
formation
Plan d'exécution       : IXSCAN → FETCH → SORT
Index utilisé          : formation { formation_id: 1 }
Tri en mémoire (SORT)  : oui
Documents renvoyés     : 10
Clés d'index examinées : 78523
Documents examinés     : 78523
Examinés / renvoyés    : 7852
Durée côté serveur     : 132 ms
Plans rejetés          : aucun
Diagnostic             : SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).
Diagnostic             : ratio 7852 : la plupart des documents lus sont écartés ensuite.
```

`createIndex()` renvoie le nom de l'index. Nommer explicitement ses index (option `name`) est une bonne pratique d'exploitation : le nom est court, stable et parlant dans `hint()`, `hideIndex()`, `dropIndex()` et dans les journaux (le nom automatique serait `formation_id_1`).

Le plan est passé de COLLSCAN à **IXSCAN** et la requête est environ quatre fois plus rapide, mais le compte n'y est pas :

- `IXSCAN` lit les **78 523** entrées d'index de la formation BD511 ;
- `FETCH` charge les 78 523 documents correspondants pour vérifier `type` et `score`, qui ne sont pas dans l'index ;
- `SORT` trie encore les 1 742 survivants en mémoire.

Un index n'est vraiment efficace que s'il écarte les documents **avant** l'étape `FETCH`, et s'il fournit l'**ordre** demandé.

### 4.3 Deuxième essai : un index composé dans l'ordre du filtre, créé dans Compass

Mettons tous les champs de la requête dans un index **composé**, dans l'ordre où ils apparaissent : les deux égalités, la plage sur `score`, puis le tri sur `date`. Créez-le dans Compass :

1. Ouvrez l'onglet **Indexes** de la collection `activites` et cliquez sur **Create Index**.
2. Dans la fenêtre **Create Index** (`BD511.activites`), section **Index fields** :
   - première ligne : dans **Select or type a field name**, choisissez `formation_id` ; dans **Select a type**, choisissez **1 (asc)** ;
   - cliquez sur **+** pour ajouter une ligne : `type`, **1 (asc)** ;
   - **+** : tapez `score` puis cliquez sur `score` dans la liste ou, s'il n'y figure pas, sur la proposition **Field: "score"** (Compass construit la liste à partir d'un échantillon de documents, et les vidéos et lectures n'ont pas de score), puis **1 (asc)** ;
   - **+** : `date`, **-1 (desc)**.
3. Dépliez **Options**, cochez **Index name** et saisissez `formation_type_score_date`.
4. Cliquez sur **Create Index**.

Pendant la construction (quelques secondes), la ligne de l'index affiche le statut **CREATING** et la mention **Building…**. Elle passe ensuite à **READY**, avec le type **REGULAR**, la propriété **COMPOUND** et une taille d'environ 14,6 MB. Le chevron devant le nom affiche les clés : `formation_id ↑`, `type ↑`, `score ↑`, `date ↓`.

Équivalent mongosh de cette création (pour information : ne le tapez pas, l'index existe déjà) :

```text
// Équivalent mongosh
db.activites.createIndex({ formation_id: 1, type: 1, score: 1, date: -1 }, { name: "formation_type_score_date" })
```

Revenez sur l'onglet **Documents** : la requête, le tri et la limite sont toujours dans la barre. Cliquez sur **Explain** :

- l'arbre contient maintenant trois nœuds, de bas en haut : **IXSCAN** (**Returned 1742**, **Index Name: formation_type_score_d…**, **Multi Key Index: no**), **SORT** (**Returned 10**) puis **FETCH** (**Returned 10**) ;
- le résumé indique **10 documents returned**, **10 documents examined**, **1742 index keys examined**, **Is sorted in memory**, et **Query used the following index:** suivi des clés `formation_id ↑ type ↑ score ↑ date ↓`.

Fermez la fenêtre. Dans le terminal 2, le résumé confirme :

```javascript
resume(db.activites.find(filtre).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
Plan d'exécution       : IXSCAN → SORT → FETCH
Index utilisé          : formation_type_score_date { formation_id: 1, type: 1, score: 1, date: -1 }
Tri en mémoire (SORT)  : oui
Documents renvoyés     : 10
Clés d'index examinées : 1742
Documents examinés     : 10
Examinés / renvoyés    : 1
Durée côté serveur     : 16 ms
Plans rejetés          : formation
Diagnostic             : SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).
```

Progrès net : le filtre est entièrement résolu **dans l'index** (1 742 clés lues, exactement le nombre de quiz réussis de BD511), et 10 documents seulement sont chargés, puisque le tri se fait sur les clés **avant** le `FETCH`. Le planificateur a d'ailleurs comparé les deux index et rejeté `formation`.

Mais il reste un tri en mémoire. Pour comprendre pourquoi, regardez l'**ordre des entrées** de cet index dans la plage `score >= 80`. Avec `hint()` et une projection limitée aux champs de l'index, les résultats sortent dans l'ordre de l'index :

```javascript
db.activites.find({ formation_id: "BD511", type: "quiz", score: 80 }, { _id: 0, score: 1, date: 1 }).hint("formation_type_score_date").limit(3)
db.activites.find({ formation_id: "BD511", type: "quiz", score: 81 }, { _id: 0, score: 1, date: 1 }).hint("formation_type_score_date").limit(3)
```

Résultat attendu :

```text
[
  { score: 80, date: ISODate('2026-10-10T10:19:18.000Z') },
  { score: 80, date: ISODate('2026-10-08T10:43:36.000Z') },
  { score: 80, date: ISODate('2026-10-03T22:06:50.000Z') }
]
[
  { score: 81, date: ISODate('2026-10-13T22:37:28.000Z') },
  { score: 81, date: ISODate('2026-10-11T18:02:22.000Z') },
  { score: 81, date: ISODate('2026-10-08T15:00:54.000Z') }
]
```

Les entrées sont triées par `score`, puis par `date` **à l'intérieur de chaque score** : les dates « repartent » du plus récent à chaque nouvelle valeur de score (80, 81, … 100). Sur l'ensemble de la plage, l'ordre des dates n'existe pas ; MongoDB doit donc lire **toute** la plage (1 742 clés) puis trier. Sur une plage plus large (un score ≥ 50, une formation plus suivie, des années d'historique), ce tri grossirait d'autant.

### 4.4 La règle ESR : Égalité, Tri, Plage

La règle **ESR** donne l'ordre des champs d'un index composé :

1. **E – Égalité** : d'abord les champs testés par égalité (`formation_id`, `type`). Ils délimitent un **bloc contigu** de l'index : toutes les entrées « BD511 / quiz » ;
2. **S – Tri (*Sort*)** : ensuite le champ de tri (`date`). À l'intérieur du bloc, les entrées sont alors **déjà dans l'ordre demandé** : plus de `SORT`, et le parcours peut s'arrêter dès que 10 résultats sont trouvés ;
3. **R – Plage (*Range*)** : enfin le champ testé par une plage (`score`). Il est vérifié sur la clé d'index pendant le parcours, sans charger le document.

Pour un tri sur un seul champ, le sens (`date: -1` ou `date: 1`) importe peu : un index se parcourt dans les deux sens. Il compte en revanche pour un tri sur plusieurs champs de sens opposés.

Créez l'index ESR dans le terminal 2, puis résumez le plan :

```javascript
db.activites.createIndex({ formation_id: 1, type: 1, date: -1, score: 1 }, { name: "formation_type_date_score" })
resume(db.activites.find(filtre).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
formation_type_date_score
Plan d'exécution       : IXSCAN → FETCH → LIMIT
Index utilisé          : formation_type_date_score { formation_id: 1, type: 1, date: -1, score: 1 }
Tri en mémoire (SORT)  : non
Documents renvoyés     : 10
Clés d'index examinées : 70
Documents examinés     : 10
Examinés / renvoyés    : 1
Durée côté serveur     : 1 ms
Plans rejetés          : formation_type_score_date, formation
Diagnostic             : plan efficace : chaque document lu est renvoyé, sans tri en mémoire.
```

C'est le plan idéal : `IXSCAN` parcourt le bloc « BD511 / quiz » du plus récent au plus ancien, écarte sur la clé elle-même les entrées dont le score est inférieur à 80, et s'arrête au 10ᵉ résultat (`LIMIT`). Il a lu **70 clés** (10 quiz réussis et 60 quiz ratés, écartés sans lecture du document) et chargé **10 documents** : ceux qui sont renvoyés.

Vérifiez l'ordre des entrées de ce nouvel index, toujours avec `hint()` :

```javascript
db.activites.find(filtre, { _id: 0, date: 1, score: 1 }).hint("formation_type_date_score").limit(4)
```

Résultat attendu :

```text
[
  { date: ISODate('2026-10-15T17:48:47.000Z'), score: 86 },
  { date: ISODate('2026-10-15T07:09:48.000Z'), score: 85 },
  { date: ISODate('2026-10-14T13:14:27.000Z'), score: 83 },
  { date: ISODate('2026-10-13T22:37:28.000Z'), score: 81 }
]
```

Les entrées sortent directement par date décroissante, quel que soit le score : ce sont les premiers résultats de la page.

Dans Compass, onglet **Documents**, cliquez à nouveau sur **Explain** :

- l'arbre devient, de bas en haut, **IXSCAN** (**Returned 10**, **Index Name: formation_type_date_sc…**) → **FETCH** (**Returned 10**) → **LIMIT** (**Returned 10**) ;
- le résumé indique **10 documents returned**, **10 documents examined**, **70 index keys examined**, **Is not sorted in memory**, et les clés `formation_id ↑ type ↑ date ↓ score ↑`.

Fermez la fenêtre.

### 4.5 Comparer avant et après

Relancez la mesure de référence dans le terminal 1 :

```bash
cd ~/BD511/ch04
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" comparer.js | tee mesures-apres.txt
```

Résultat attendu (durées variables) :

```text
Requête : find({"formation_id":"BD511","type":"quiz","score":{"$gte":80}}).sort({"date":-1}).limit(10)

Variante (hint)            Plan d'exécution          Clés lues  Docs lus  Tri mémoire    Durée
Sans index ($natural)      COLLSCAN → SORT                   0   1000000  oui           510 ms
formation                  IXSCAN → FETCH → SORT         78523     78523  oui           153 ms
formation_type_score_date  IXSCAN → SORT → FETCH          1742        10  oui             4 ms
formation_type_date_score  IXSCAN → FETCH → LIMIT           70        10  non             2 ms
Choix du planificateur     IXSCAN → FETCH → LIMIT           70        10  non             2 ms

Index retenu par le planificateur : formation_type_date_score
```

Puis réaffichez la page, comme le ferait l'application :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-appli" ~/BD511/ch04/requete-lente.js | tail -n 1
```

Résultat attendu (durées variables) :

```text
10 quiz ; durée des 3 affichages : 12 ms, 4 ms, 2 ms
```

Le premier affichage inclut le choix du plan et l'initialisation du client ; les suivants réutilisent le plan mis en cache (partie 4.6). Le journal de `mongod` le confirme : depuis la création de l'index, la page n'y apparaît plus, ses requêtes passant sous le seuil de 100 ms :

```bash
sudo jq -s -c '[.[] | select(.msg == "Slow query" and .attr.appName == "BD511-appli")]
  | group_by(.attr.planSummary) | map({plan: .[0].attr.planSummary, requetes_lentes: length})' \
  /var/log/mongodb/mongod.log
```

Résultat attendu (3 requêtes lentes par exécution du script de la partie 2.1) :

```text
[{"plan":"COLLSCAN","requetes_lentes":3}]
```

Faites la même comparaison dans Compass, grâce au champ **Index Hint** des options de requête :

1. onglet **Documents** : dans **Index Hint**, saisissez `{ $natural: 1 }`, puis cliquez sur **Explain** : vous retrouvez la vue « avant » (**COLLSCAN**, **1000000 documents examined**, **Is sorted in memory**) ;
2. remplacez le contenu d'**Index Hint** par `"formation_type_score_date"` (avec les guillemets) et cliquez sur **Explain** : **IXSCAN → SORT → FETCH**, **1742 index keys examined** ;
3. **videz** le champ **Index Hint** et cliquez sur **Explain** : vous retrouvez le plan ESR, choisi librement par le planificateur.

Bilan de l'optimisation :

| Indicateur | Avant (aucun index) | Après (index ESR) | Gain |
| --- | ---: | ---: | --- |
| Plan | COLLSCAN → SORT | IXSCAN → FETCH → LIMIT | |
| Clés d'index examinées | 0 | 70 | |
| Documents examinés | 1 000 000 | 10 | ÷ 100 000 |
| Examinés / renvoyés | 100 000 | 1 | ratio idéal |
| Tri en mémoire | oui | non | |
| Durée d'une requête (serveur) | ≈ 500 ms | ≈ 1 ms | ≈ × 500 |
| Coût | | un index d'environ 14 Mo à maintenir | partie 5 |

Surtout, la durée « après » **ne dépend plus de la taille de la collection** : avec dix fois plus d'activités, l'index ESR lirait toujours environ 70 clés et 10 documents, alors que le parcours complet serait dix fois plus long.

### 4.6 Comment le planificateur a choisi

Quand plusieurs index sont utilisables, le planificateur les met en **concurrence** : il exécute chaque plan candidat pendant une courte phase d'essai et retient celui qui produit le plus de résultats pour le moins de travail. Le mode `allPlansExecution` montre cette phase d'essai. Dans le terminal 2 :

```javascript
const tous = db.activites.find(filtre).sort(tri).limit(10).explain("allPlansExecution")
tous.executionStats.allPlansExecution.map(p => ({ index: etapesDuPlan(p.executionStages).find(e => e.indexName).indexName, travaux: p.executionStages.works, renvoyes: p.nReturned, cles: p.totalKeysExamined, docs: p.totalDocsExamined }))
```

Résultat attendu :

```text
[
  {
    index: 'formation_type_date_score',
    travaux: 70,
    renvoyes: 10,
    cles: 70,
    docs: 10
  },
  {
    index: 'formation_type_score_date',
    travaux: 70,
    renvoyes: 0,
    cles: 70,
    docs: 0
  },
  { index: 'formation', travaux: 70, renvoyes: 0, cles: 70, docs: 70 }
]
```

À travail égal (70 unités), l'index ESR a déjà livré ses 10 résultats ; les deux autres n'en ont livré aucun (l'un doit encore lire toute sa plage avant de trier, l'autre trier après avoir chargé tous les documents). L'index ESR gagne.

Le plan gagnant est ensuite mis en **cache** pour cette **forme de requête** (même filtre, même tri, même projection, quelles que soient les valeurs), afin de ne pas refaire la compétition à chaque exécution. La page a été affichée en partie 4.5 ; consultez le cache :

```javascript
db.activites.getPlanCache().list().map(e => ({ requete: e.createdFromQuery, actif: e.isActive, plan: etapesDuPlan(e.cachedPlan).map(x => x.indexName ? `${x.stage}(${x.indexName})` : x.stage).join(" → ") }))
```

Résultat attendu :

```text
[
  {
    requete: {
      query: { formation_id: 'BD511', type: 'quiz', score: { '$gte': 80 } },
      sort: { date: -1 },
      projection: {}
    },
    actif: true,
    plan: 'IXSCAN(formation_type_date_score) → FETCH → LIMIT'
  }
]
```

Le cache d'une collection est vidé à chaque création, suppression ou masquage d'index, et au redémarrage de `mongod` ; on peut aussi le vider avec `db.activites.getPlanCache().clear()`. Une entrée dont les performances se dégradent est désactivée et la compétition rejouée. `explain()`, lui, ignore le cache et ne l'alimente pas.

### 4.7 Pour aller plus loin : la requête couverte

Si la page n'a besoin que de la date et du score, une **projection** limitée aux champs de l'index évite même le chargement des documents :

```javascript
resume(db.activites.find(filtre, { _id: 0, date: 1, score: 1 }).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
Plan d'exécution       : IXSCAN → PROJECTION_COVERED → LIMIT
Index utilisé          : formation_type_date_score { formation_id: 1, type: 1, date: -1, score: 1 }
Tri en mémoire (SORT)  : non
Documents renvoyés     : 10
Clés d'index examinées : 70
Documents examinés     : 0
Examinés / renvoyés    : 0
Durée côté serveur     : 1 ms
Plans rejetés          : formation_type_score_date, formation
Diagnostic             : requête couverte : résultats lus dans l'index, aucun document chargé.
```

L'étape `FETCH` a disparu au profit de `PROJECTION_COVERED` : la requête est **couverte** par l'index (*covered query*), `totalDocsExamined` vaut 0. Conditions : tous les champs du filtre **et** de la projection sont dans l'index, et `_id` est exclu explicitement (`_id: 0`), puisqu'il ne fait pas partie de cet index.

---

## Partie 5 – Gérer les index en exploitation

La requête est corrigée, mais la collection porte maintenant trois index secondaires. Un index n'est pas gratuit : il occupe de la mémoire et du disque, et **chaque écriture** doit le mettre à jour. Cette partie apprend à mesurer ce coût et à nettoyer sans risque.

### 5.1 Lister et mesurer les index

Dans le terminal 2 :

```javascript
db.activites.getIndexes()
for (const [nom, octets] of Object.entries(db.activites.stats().indexSizes)) print(nom.padEnd(27), (octets / 2 ** 20).toFixed(1), "Mio")
```

Résultat attendu (tailles variables à quelques dixièmes près) :

```text
[
  { v: 2, key: { _id: 1 }, name: '_id_' },
  { v: 2, key: { formation_id: 1 }, name: 'formation' },
  {
    v: 2,
    key: { formation_id: 1, type: 1, score: 1, date: -1 },
    name: 'formation_type_score_date'
  },
  {
    v: 2,
    key: { formation_id: 1, type: 1, date: -1, score: 1 },
    name: 'formation_type_date_score'
  }
]
_id_                        19.4 Mio
formation                   5.4 Mio
formation_type_score_date   14.0 Mio
formation_type_date_score   13.6 Mio
```

Les index pèsent ensemble plus de 50 Mio, davantage que les données compressées sur disque. WiredTiger compresse les index par **préfixe** (les valeurs répétées en tête de clé, comme `"BD511"` ou `"quiz"`, ne sont stockées qu'une fois par page), d'où la taille modeste de l'index `formation`. Pour de bonnes performances, les index utilisés doivent tenir dans le cache WiredTiger avec les documents fréquemment lus : c'est le *working set* (chapitre 8).

Dans Compass, cliquez sur l'onglet **Indexes** (badge **4**), puis sur **Refresh**. Chaque ligne affiche le nom et la définition (**Name & Definition**, chevron pour voir les clés), le **Type** (**REGULAR**), la **Size**, l'**Usage** (nombre d'utilisations depuis une date), les **Properties** (**UNIQUE** pour `_id_`, **COMPOUND** pour les index composés) et le **Status** (**READY**). Au survol d'une ligne apparaissent à droite deux icônes : **Hide Index** (œil barré) et **Drop Index** (corbeille).

### 5.2 Mesurer le coût en écriture

Le script suivant insère 200 000 activités dans deux collections de test : l'une avec le seul index `_id_`, l'autre avec les mêmes index secondaires que `activites`. Chaque mesure est répétée trois fois et la meilleure est retenue, pour limiter l'effet des activités de fond du serveur (points de contrôle WiredTiger…). Dans le terminal 1 (environ 20 secondes) :

```bash
cat > ~/BD511/ch04/cout-ecriture.js <<'EOF'
// cout-ecriture.js - BD511 ch.4 : mesure le coût des index secondaires sur les insertions
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" ~/BD511/ch04/cout-ecriture.js
// Copie 200 000 activités dans deux collections de test : l'une avec le seul index _id_,
// l'autre avec les mêmes index secondaires que BD511.activites. Chaque mesure est répétée 3 fois
// et la meilleure est retenue (la moins perturbée) ; les collections de test sont supprimées à la fin.
const NOMBRE = 200000;
const ESSAIS = 3;
const indexSecondaires = db.activites.getIndexes().filter(ix => ix.name !== "_id_");

function chronometrer(nom, index) {
  const cible = db.getCollection(nom);
  cible.drop();
  db.createCollection(nom);
  for (const ix of index) cible.createIndex(ix.key, { name: ix.name });
  const debut = Date.now();
  db.activites.aggregate([
    { $limit: NOMBRE },
    { $merge: { into: nom, whenMatched: "fail", whenNotMatched: "insert" } },
  ]);
  const duree = Date.now() - debut;
  cible.drop();
  return duree;
}

const mesuresSans = [], mesuresAvec = [];
for (let i = 0; i < ESSAIS; i++) {
  mesuresSans.push(chronometrer("essai_sans_index", []));
  mesuresAvec.push(chronometrer("essai_avec_index", indexSecondaires));
}
const sans = Math.min(...mesuresSans);
const avec = Math.min(...mesuresAvec);
const noms = indexSecondaires.map(ix => ix.name).join(", ") || "aucun";
print(`Insertion de ${NOMBRE} activités, meilleur de ${ESSAIS} essais`);
print(`Index secondaires de BD511.activites : ${noms}`);
print("  index _id_ seul".padEnd(42) + `: ${String(sans).padStart(6)} ms`);
print(`  _id_ + ${indexSecondaires.length} index secondaire(s)`.padEnd(42) + `: ${String(avec).padStart(6)} ms`);
print("Surcoût dû aux index secondaires".padEnd(42) + `: x ${(avec / sans).toFixed(1)}`);
EOF
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" ~/BD511/ch04/cout-ecriture.js
```

Résultat attendu (durées variables ; le surcoût se situe généralement entre × 2,5 et × 3,5) :

```text
Insertion de 200000 activités, meilleur de 3 essais
Index secondaires de BD511.activites : formation, formation_type_score_date, formation_type_date_score
  index _id_ seul                         :   1204 ms
  _id_ + 3 index secondaire(s)            :   3330 ms
Surcoût dû aux index secondaires          : x 2.8
```

Chaque insertion écrit le document **et** une entrée dans chaque index ; les mises à jour d'un champ indexé et les suppressions paient le même prix. Trois index pour une seule requête, c'est deux de trop.

### 5.3 Observer l'utilisation des index

L'étape d'agrégation `$indexStats` compte les utilisations de chaque index depuis sa création ou depuis le dernier démarrage de `mongod` :

```javascript
db.activites.aggregate([
  { $indexStats: {} },
  { $project: { _id: 0, index: "$name", utilisations: "$accesses.ops", depuis: "$accesses.since" } },
  { $sort: { index: 1 } }
])
```

Résultat attendu (les compteurs et les dates dépendent de vos manipulations) :

```text
[
  {
    index: '_id_',
    utilisations: Long('1'),
    depuis: ISODate('2026-10-22T15:12:47.839Z')
  },
  {
    index: 'formation',
    utilisations: Long('5'),
    depuis: ISODate('2026-10-22T15:15:07.673Z')
  },
  {
    index: 'formation_type_date_score',
    utilisations: Long('23'),
    depuis: ISODate('2026-10-22T15:15:14.154Z')
  },
  {
    index: 'formation_type_score_date',
    utilisations: Long('5'),
    depuis: ISODate('2026-10-22T15:15:10.666Z')
  }
]
```

Ici, les utilisations de `formation` et `formation_type_score_date` viennent uniquement de nos `hint()` et `explain()`. En production, ces compteurs sont remis à zéro au redémarrage et propres à chaque membre d'un replica set : observez-les sur **tous** les membres et sur un **cycle d'activité complet** (fin de mois, traitements trimestriels…) avant de conclure qu'un index est inutile. La colonne **Usage** de Compass affiche la même information.

### 5.4 Masquer avant de supprimer

Deux index sont candidats à la suppression :

- **`formation`** est **redondant** : son unique champ est le **préfixe** (premier champ) des deux index composés, qui peuvent servir toutes les requêtes qu'il sert ;
- **`formation_type_score_date`** est rejeté par le planificateur pour la page des quiz et ne sert aucune autre requête de l'application.

Supprimer un index est instantané, mais le reconstruire sur une grosse collection peut prendre des heures. Un index **masqué** (*hidden*) est ignoré par le planificateur mais **reste maintenu** à chaque écriture : on peut le réactiver instantanément, sans reconstruction. On masque donc d'abord, on observe l'application, puis on supprime. (L'index `_id_` ne peut pas être masqué ; un index unique masqué continue d'imposer l'unicité ; `hint()` refuse un index masqué.)

**a) Masquer `formation_type_score_date` dans Compass.** Onglet **Indexes** : survolez la ligne `formation_type_score_date` et cliquez sur l'icône **Hide Index**. La fenêtre **Hiding `formation_type_score_date`** explique que l'index ne sera plus visible du planificateur et qu'il pourra être réaffiché ; cliquez sur **Confirm**. La ligne affiche la propriété **HIDDEN** et l'icône devient **Unhide Index**.

Équivalent mongosh (pour information : ne le tapez pas) :

```text
// Équivalent mongosh
db.activites.hideIndex("formation_type_score_date")
```

**b) Vérifier que la page n'est pas affectée.** Dans le terminal 2 :

```javascript
resume(db.activites.find(filtre).sort(tri).limit(10))
```

Résultat attendu (durée variable) :

```text
Plan d'exécution       : IXSCAN → FETCH → LIMIT
Index utilisé          : formation_type_date_score { formation_id: 1, type: 1, date: -1, score: 1 }
Tri en mémoire (SORT)  : non
Documents renvoyés     : 10
Clés d'index examinées : 70
Documents examinés     : 10
Examinés / renvoyés    : 1
Durée côté serveur     : 1 ms
Plans rejetés          : formation
Diagnostic             : plan efficace : chaque document lu est renvoyé, sans tri en mémoire.
```

Même plan ; l'index masqué ne figure même plus parmi les plans rejetés.

**c) Masquer `formation` dans mongosh** et vérifier qu'une requête sur la seule formation, comme le comptage des activités d'une formation, utilise le **préfixe** de l'index ESR :

```javascript
db.activites.hideIndex("formation")
db.activites.getIndexes().filter(ix => ix.hidden).map(ix => ix.name)
const comptage = db.activites.explain().count({ formation_id: "IA101" }).queryPlanner.winningPlan.inputStage
({ etape: comptage.stage, index: comptage.indexName })
```

Résultat attendu :

```text
{ hidden_old: false, hidden_new: true, ok: 1 }
[ 'formation', 'formation_type_score_date' ]
{ etape: 'COUNT_SCAN', index: 'formation_type_date_score' }
```

Le comptage reste un `COUNT_SCAN` : il compte les entrées d'index sans lire un seul document, grâce au préfixe `formation_id` de l'index ESR. Dans Compass, cliquez sur **Refresh** : `formation` porte aussi la propriété **HIDDEN**.

**d) Supprimer les deux index.** En production, on attendrait ici un cycle d'activité complet. Supprimez `formation_type_score_date` dans **Compass** : survolez la ligne, cliquez sur **Drop Index** ; la fenêtre **Drop Index** demande de saisir le nom de l'index pour confirmer (*Type "formation_type_score_date" to confirm your action*) ; saisissez-le et cliquez sur **Drop**.

Équivalent mongosh (pour information : ne le tapez pas) :

```text
// Équivalent mongosh
db.activites.dropIndex("formation_type_score_date")
```

Supprimez `formation` dans **mongosh** :

```javascript
db.activites.dropIndex("formation")
db.activites.getIndexes().map(ix => ix.name)
```

Résultat attendu :

```text
{ nIndexesWas: 3, ok: 1 }
[ '_id_', 'formation_type_date_score' ]
```

Mesurez à nouveau le coût en écriture (terminal 1) :

```bash
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp4" ~/BD511/ch04/cout-ecriture.js
```

Résultat attendu (durées variables ; le surcoût se situe généralement entre × 1,4 et × 2) :

```text
Insertion de 200000 activités, meilleur de 3 essais
Index secondaires de BD511.activites : formation_type_date_score
  index _id_ seul                         :   1038 ms
  _id_ + 1 index secondaire(s)            :   1756 ms
Surcoût dû aux index secondaires          : x 1.7
```

Le surcoût des écritures a nettement baissé, et la page des quiz est toujours servie par le plan optimal.

### 5.5 Construire un index sur une collection en service

Deuxième demande de l'équipe applicative : la page **« Mon activité »** d'un stagiaire affiche ses 20 dernières activités :

```javascript
resume(db.activites.find({ stagiaire_id: "STG0042" }).sort({ date: -1 }).limit(20))
```

Résultat attendu (durée variable) :

```text
Plan d'exécution       : COLLSCAN → SORT
Index utilisé          : aucun
Tri en mémoire (SORT)  : oui
Documents renvoyés     : 20
Clés d'index examinées : 0
Documents examinés     : 1000000
Examinés / renvoyés    : 50000
Durée côté serveur     : 485 ms
Plans rejetés          : aucun
Diagnostic             : COLLSCAN : toute la collection est lue, aucun index n'est utilisé.
Diagnostic             : SORT : l'index ne fournit pas l'ordre demandé, tri en mémoire (sur disque au-delà de 100 Mo).
Diagnostic             : ratio 50000 : la plupart des documents lus sont écartés ensuite.
```

D'après la règle ESR, il faut l'égalité puis le tri, sans plage : l'index `{ stagiaire_id: 1, date: -1 }`. Sur une collection en service, une construction d'index dure de quelques secondes à plusieurs heures ; il faut savoir la **suivre**. Le script suivant interroge `$currentOp` toutes les demi-secondes. Dans le terminal 1, créez-le, lancez la construction en arrière-plan (`&`) et suivez-la :

```bash
cat > ~/BD511/ch04/suivre-construction.js <<'EOF'
// suivre-construction.js - BD511 ch.4 : suit les constructions d'index en cours ($currentOp)
// Usage : mongosh --quiet "mongodb://127.0.0.1:27017/admin?appName=BD511-tp4" ~/BD511/ch04/suivre-construction.js
// Affiche la phase et l'avancement toutes les 0,5 s, jusqu'à la fin de la construction (2 minutes au plus).
let dejaVu = false;
let dernier = "";
for (let i = 0; i < 240; i++) {
  const ops = db.getSiblingDB("admin").aggregate([
    { $currentOp: {} },
    { $match: { desc: /^IndexBuildsCoordinator/, "command.createIndexes": { $exists: true } } },
  ]).toArray();
  if (ops.length === 0) {
    if (dejaVu) { print("Construction terminée."); break; }
    if (i === 10) { print("Aucune construction d'index en cours (déjà terminée ?)."); break; }
  }
  for (const op of ops) {
    dejaVu = true;
    const phase = (op.msg || "").split(" Index Build:")[0];   // msg répète la phase avec l'avancement
    const avancement = op.progress ? `${Math.floor(100 * op.progress.done / op.progress.total)} %` : "";
    const ligne = `${op.ns}  ${op.command.indexes.map(ix => ix.name).join(",")}  ${phase}  ${avancement}`;
    if (ligne !== dernier) print(`${new Date().toTimeString().slice(0, 8)}  ${ligne}`);
    dernier = ligne;
  }
  sleep(500);
}
EOF
cd ~/BD511/ch04
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-build" \
  --eval 'db.activites.createIndex({ stagiaire_id: 1, date: -1 }, { name: "stagiaire_date" })' &
mongosh --quiet "mongodb://127.0.0.1:27017/admin?appName=BD511-tp4" suivre-construction.js
wait
```

Résultat attendu (heures, pourcentages et numéro de tâche variables) :

```text
[1] 24518
17:19:50  BD511.activites  stagiaire_date  Index Build: scanning collection  24 %
17:19:51  BD511.activites  stagiaire_date  Index Build: scanning collection  68 %
17:19:51  BD511.activites  stagiaire_date  Index Build: scanning collection  
17:19:53  BD511.activites  stagiaire_date  Index Build: inserting keys from external sorter into index  64 %
stagiaire_date
Construction terminée.
[1]+  Done                    mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-build" --eval 'db.activites.createIndex({ stagiaire_id: 1, date: -1 }, { name: "stagiaire_date" })'
```

> Si le script affiche « Aucune construction d'index en cours (déjà terminée ?) », la construction a été plus rapide que le démarrage du suivi : c'est normal sur une VM rapide, le journal ci-dessous en garde la trace.

La construction se déroule en trois phases :

1. **parcours de la collection** (*scanning collection*) : les clés sont extraites de chaque document et triées en mémoire, dans la limite de `maxIndexBuildMemoryUsageMegabytes` (200 Mo) ; au-delà, le tri déborde dans des fichiers temporaires du sous-répertoire `_tmp` de `dbPath` (la ligne sans pourcentage correspond à la fin de ce tri) ;
2. **insertion des clés triées** dans l'arbre B de l'index (*inserting keys from external sorter*) ;
3. **validation** : application des écritures reçues pendant la construction, puis publication de l'index.

Pendant les deux premières phases, les lectures et écritures de l'application continuent : la collection n'est verrouillée en exclusif que brièvement, au début et à la fin (construction dite *hybride*).

Le journal de `mongod` retrace chaque étape :

```bash
sudo jq -c 'select(.msg | startswith("Index build"))
  | {heure: .t["$date"][11:19], msg,
     index: (.attr.firstIndex.name // .attr.index // .attr.properties.name // .attr.indexesBuilt),
     methode: .attr.method, memoireMaxMo: .attr.maxTemporaryMemoryUsageMB,
     docs: .attr.totalRecords, cles: .attr.keysInserted, ms: .attr.durationMillis, action: .attr.action}
  | with_entries(select(.value != null))' /var/log/mongodb/mongod.log | tail -n 11
```

Résultat attendu (heures et durées variables) :

```text
{"heure":"17:19:50","msg":"Index build: registering","index":"stagiaire_date"}
{"heure":"17:19:50","msg":"Index build: starting","index":"stagiaire_date","methode":"hybrid","memoireMaxMo":200}
{"heure":"17:19:50","msg":"Index build: waiting for index build to complete"}
{"heure":"17:19:51","msg":"Index build: collection scan done","docs":1000000,"ms":1180}
{"heure":"17:19:54","msg":"Index build: inserted keys from external sorter into index","index":"stagiaire_date","cles":1000000,"ms":2512}
{"heure":"17:19:54","msg":"Index build: skipping vote for commit readiness"}
{"heure":"17:19:54","msg":"Index build: waiting for next action before completing final phase"}
{"heure":"17:19:54","msg":"Index build: received signal","action":"Single-phase commit"}
{"heure":"17:19:54","msg":"Index build: done building","index":"stagiaire_date"}
{"heure":"17:19:54","msg":"Index build: completed successfully","index":["stagiaire_date"]}
{"heure":"17:19:54","msg":"Index build: completed"}
```

Les messages *skipping vote for commit readiness* et *Single-phase commit* sont propres à une instance seule. Contrôlez enfin les deux paramètres qui encadrent les constructions (terminal 2), puis le plan de la page :

```javascript
db.adminCommand({ getParameter: 1, maxIndexBuildMemoryUsageMegabytes: 1, indexBuildMinAvailableDiskSpaceMB: 1 })
resume(db.activites.find({ stagiaire_id: "STG0042" }).sort({ date: -1 }).limit(20))
```

Résultat attendu (durée variable) :

```text
{
  indexBuildMinAvailableDiskSpaceMB: Long('500'),
  maxIndexBuildMemoryUsageMegabytes: 200,
  ok: 1
}
Plan d'exécution       : IXSCAN → FETCH → LIMIT
Index utilisé          : stagiaire_date { stagiaire_id: 1, date: -1 }
Tri en mémoire (SORT)  : non
Documents renvoyés     : 20
Clés d'index examinées : 20
Documents examinés     : 20
Examinés / renvoyés    : 1
Durée côté serveur     : 0 ms
Plans rejetés          : aucun
Diagnostic             : plan efficace : chaque document lu est renvoyé, sans tri en mémoire.
```

- `maxIndexBuildMemoryUsageMegabytes` (200 Mo par commande `createIndexes`) : mémoire de tri d'une construction ; jusqu'à 3 constructions simultanées (`maxNumActiveUserIndexBuilds`) ;
- `indexBuildMinAvailableDiskSpaceMB` (500 Mo) : une construction est interrompue si l'espace libre du volume de données passe sous ce seuil, pour ne pas saturer le disque.

**Sur un replica set (chapitre 6).** Une construction d'index est répliquée : elle se déroule **simultanément** sur tous les membres porteurs de données, et le primaire ne publie l'index qu'une fois atteint le quorum de validation `commitQuorum` (par défaut `"votingMembers"`, tous les membres votants). Si un membre votant est injoignable, la construction attend son retour. Pour un index très volumineux, on peut préférer une construction **tournante** (*rolling*) : un membre à la fois, en commençant par les secondaires, chacun redémarré temporairement hors du replica set, puis bascule du primaire. Cette procédure réduit l'impact sur l'application, au prix d'une résilience moindre pendant l'opération.

Dans Compass, une construction lancée depuis l'onglet **Indexes** apparaît avec le statut **CREATING** et la mention **Building…**, comme en partie 4.3.

Quittez la session mongosh du terminal 2 :

```javascript
exit
```

---

## Partie 6 – Bilan

### 6.1 Contrôle final

Le script suivant vérifie l'état attendu de la collection et des plans d'exécution :

```bash
cat > ~/BD511/ch04/verifier-ch04.sh <<'EOF'
#!/usr/bin/env bash
# verifier-ch04.sh - BD511 ch.4 : contrôle de l'état final de BD511.activites (index et plans)
# Usage : bash ~/BD511/ch04/verifier-ch04.sh
set -u
mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-verif" --eval '
let ok = 0, ko = 0;
function res(cond, libelle, detail) {
  print(`  [${cond ? "OK" : "KO"}] ${libelle}${detail === undefined ? "" : " : " + detail}`);
  cond ? ok++ : ko++;
}
function etapes(exp) {
  const liste = [];
  for (let e = exp.queryPlanner.winningPlan; e; e = e.inputStage) liste.unshift(e);
  return liste;
}
const index = Object.fromEntries(db.activites.getIndexes().map(ix => [ix.name, ix]));
const cle = nom => index[nom] ? EJSON.stringify(index[nom].key) : "absent";

print("== Collection BD511.activites");
res(db.activites.countDocuments() === 1000000, "1 000 000 activités", db.activites.countDocuments());
res(cle("formation_type_date_score") === EJSON.stringify({ formation_id: 1, type: 1, date: -1, score: 1 }),
    "Index ESR formation_type_date_score", cle("formation_type_date_score"));
res(cle("stagiaire_date") === EJSON.stringify({ stagiaire_id: 1, date: -1 }), "Index stagiaire_date", cle("stagiaire_date"));
res(!index.formation && !index.formation_type_score_date, "Index redondants supprimés (formation, formation_type_score_date)");
res(Object.values(index).every(ix => !ix.hidden), "Aucun index masqué");
res(db.getCollectionNames().every(n => !n.startsWith("essai_")), "Aucune collection de test essai_*");

print("== Plans d'\''exécution");
let e = db.activites.find({ formation_id: "BD511", type: "quiz", score: { $gte: 80 } }).sort({ date: -1 }).limit(10).explain("executionStats");
let plan = etapes(e).map(x => x.stage).join(" → ");
res(plan === "IXSCAN → FETCH → LIMIT" && e.executionStats.totalDocsExamined === 10,
    "Page « Derniers quiz réussis » sans tri en mémoire", `${plan}, ${e.executionStats.totalKeysExamined} clés, ${e.executionStats.totalDocsExamined} documents`);
e = db.activites.find({ stagiaire_id: "STG0042" }).sort({ date: -1 }).limit(20).explain("executionStats");
plan = etapes(e).map(x => x.stage).join(" → ");
res(plan === "IXSCAN → FETCH → LIMIT" && e.executionStats.totalDocsExamined === 20,
    "Page « Mon activité » sans tri en mémoire", `${plan}, ${e.executionStats.totalKeysExamined} clés, ${e.executionStats.totalDocsExamined} documents`);

print("");
print(`Bilan : ${ok} OK, ${ko} KO`);
if (ko > 0) quit(1);
'
EOF
bash ~/BD511/ch04/verifier-ch04.sh
```

Résultat attendu :

```text
== Collection BD511.activites
  [OK] 1 000 000 activités : 1000000
  [OK] Index ESR formation_type_date_score : {"formation_id":1,"type":1,"date":-1,"score":1}
  [OK] Index stagiaire_date : {"stagiaire_id":1,"date":-1}
  [OK] Index redondants supprimés (formation, formation_type_score_date)
  [OK] Aucun index masqué
  [OK] Aucune collection de test essai_*
== Plans d'exécution
  [OK] Page « Derniers quiz réussis » sans tri en mémoire : IXSCAN → FETCH → LIMIT, 70 clés, 10 documents
  [OK] Page « Mon activité » sans tri en mémoire : IXSCAN → FETCH → LIMIT, 20 clés, 20 documents

Bilan : 8 OK, 0 KO
```

La collection `activites` et ses deux index servent de point de départ au chapitre 5.

### 6.2 Ce qu'il faut retenir

- **Une méthode en cinq temps** : *mesurer* (durée, journal `Slow query`), *expliquer* (`explain()`, Explain Plan), *indexer* (règle ESR), *vérifier* (comparaison avant/après, mêmes mesures), *nettoyer* (index redondants masqués puis supprimés).
- **Trois signaux d'alerte** dans un plan : `COLLSCAN`, une étape `SORT`, un ratio documents examinés / renvoyés très supérieur à 1.
- **Le passage COLLSCAN → IXSCAN ne suffit pas** : l'index simple réduisait le travail mais laissait 78 523 documents à charger et un tri en mémoire.
- **Règle ESR** : Égalité, puis Tri, puis Plage. L'ordre des champs d'un index composé change tout : mêmes champs, 1 742 clés lues et un tri d'un côté, 70 clés et aucun tri de l'autre.
- **Le planificateur met les plans en concurrence**, puis met le gagnant en cache par forme de requête ; `explain()` ne lit ni n'alimente ce cache.
- **Un index a un coût** : mémoire, disque, et surtout écritures (près de × 3 avec trois index ici). Chaque index doit servir une requête identifiée.
- **Masquer avant de supprimer** : un index masqué se réactive instantanément ; un index supprimé se reconstruit.

### 6.3 Récapitulatif des bonnes pratiques de production appliquées

| Domaine | Réglage ou pratique | Partie |
| --- | --- | --- |
| Détection | seuil `slowms` à 100 ms (défaut), profiler désactivé, requêtes lentes lues dans le journal JSON avec `jq` | 0.3, 2.2 |
| Traçabilité | `appName` distinct par application et par outil, pour filtrer le journal et `$currentOp` | 2.1, 2.2, 5.5 |
| Analyse | `explain("queryPlanner")` sans risque en production ; `executionStats` exécute la requête | 2.3 à 2.5 |
| Conception | index conçus à partir des requêtes de l'application, champs ordonnés selon ESR, index nommés explicitement | 4.2 à 4.4 |
| Validation | comparaison avant/après chiffrée et conservée (`mesures-avant.txt`, `mesures-apres.txt`) | 4.1, 4.5 |
| Sobriété | suppression des index redondants (préfixes) ou jamais choisis ; coût en écriture mesuré | 5.2, 5.4 |
| Changement sûr | `hideIndex()` puis observation sur un cycle complet et sur tous les membres, avant `dropIndex()` | 5.3, 5.4 |
| Construction | suivi par `$currentOp` et journal ; mémoire de tri (200 Mo) et espace disque minimal (500 Mo) ; sur replica set, `commitQuorum` ou construction tournante | 5.5 |
| Dimensionnement | index utilisés et données fréquemment lues dans le cache WiredTiger (*working set*) | 1.5, 5.1 |

### 6.4 Les autres types d'index (aperçu)

Ce TP a utilisé des index simples et composés. Les autres types vus en cours, illustrés sur les données de la formation (aucune de ces commandes n'est à exécuter ici) :

| Type | Exemple | Usage |
| --- | --- | --- |
| Multikey | `db.formations.createIndex({ tags: 1 })` | champ tableau : une entrée d'index par élément (créé automatiquement multikey) |
| Texte | `db.formations.createIndex({ titre: "text", tags: "text" })` | recherche plein texte avec `$text` (un seul index texte par collection) |
| Géospatial | `db.centres.createIndex({ position: "2dsphere" })` | requêtes de proximité sur des coordonnées GeoJSON |
| Haché | `db.activites.createIndex({ stagiaire_id: "hashed" })` | répartition uniforme des données d'un cluster shardé (chapitre 7) |
| TTL | `db.sessions_web.createIndex({ derniere_activite: 1 }, { expireAfterSeconds: 3600 })` | suppression automatique des documents expirés (attention : il **supprime** des données) |
| Unique | `db.stagiaires.createIndex({ email: 1 }, { unique: true })` | interdit les doublons |
| Partiel | `db.activites.createIndex({ formation_id: 1, score: -1 }, { partialFilterExpression: { score: { $exists: true } } })` | n'indexe que les documents utiles (ici les quiz et labs), index plus petit |
| Wildcard | `db.evenements.createIndex({ "attributs.$**": 1 })` | champs imprévisibles d'un sous-document |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `sha256sum -c` affiche `activites.json: FAILED` | fichier tronqué ou généré par un script modifié | `rm ~/BD511/ch04/donnees/activites.json`, recopiez `generer_activites.py` (1.2) puis relancez `importer-activites.sh` |
| `load(...)` : `Uncaught Error: ENOENT: no such file or directory, open '…/explain-resume.js'` | `explain-resume.js` pas encore créé | créez-le (partie 2.6), puis relancez `load(...)` |
| `ReferenceError: resume is not defined` ou `filtre is not defined` | nouvelle session mongosh | rechargez le script et redéfinissez `filtre` et `tri` (partie 2.3) |
| `MongoServerError[BadValue]: hint provided does not correspond to an existing index` | nom d'index erroné, index supprimé ou masqué | `db.activites.getIndexes()` ; un index masqué ne peut pas être imposé par `hint()` |
| `MongoServerError[IndexOptionsConflict]: Index already exists with a different name: …` | la même clé existe déjà sous un autre nom, par exemple créée dans Compass sans nom | `db.activites.getIndexes()` ; supprimez l'index existant ou gardez son nom |
| `MongoServerError[IndexKeySpecsConflict]: An existing index has the same name as the requested index…` | même nom, clés différentes | supprimez l'index de ce nom ou choisissez un autre nom |
| Aucune ligne `Slow query` dans le journal (2.2) | requête plus rapide que 100 ms (VM très rapide) ou `slowms` modifié | `db.getProfilingStatus()` ; `sudo systemctl restart mongod` rétablit les valeurs par défaut |
| `jq: error: Could not open /var/log/mongodb/mongod.log: Permission denied` | journal lisible par l'utilisateur `mongodb` seulement | préfixez la commande par `sudo` |
| Compass : bouton **Create Index** grisé | une ligne d'**Index fields** est incomplète (champ ou type vide) | complétez ou supprimez la ligne avec **−** |
| Compass : `score` absent de la liste des champs | champ absent des documents échantillonnés par Compass | tapez `score` puis cliquez sur **Field: "score"** |
| Compass : l'Explain Plan ne montre pas le plan attendu | champ **Index Hint** encore rempli, ou index pas encore **READY** | videz **Index Hint**, cliquez sur **Refresh** dans l'onglet **Indexes** |
| `dropIndex()` répond `{ nIndexesWas: …, ok: 1 }` mais l'index semble encore là, ou n'existait plus | avec MongoDB 8.3, `dropIndex()` ne signale pas d'erreur pour un nom inexistant (faute de frappe, index déjà supprimé dans Compass) | vérifiez toujours avec `db.activites.getIndexes().map(ix => ix.name)` |
| `suivre-construction.js` : « Aucune construction d'index en cours » | la construction s'est terminée avant le démarrage du suivi | normal sur une VM rapide : consultez le journal (5.5) |
| Erreur `Index build failed ... available disk space` | espace libre du volume de données inférieur à 500 Mo | libérez de l'espace sur `/var/lib/mongodb` (ou agrandissez le volume, chapitre 2) |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `~/BD511/ch04/00-prerequis.sh` | Contrôle de l'environnement | 0.3 |
| `~/BD511/ch04/generer_activites.py` | Générateur déterministe du jeu de données (bibliothèque standard) | 1.2 |
| `~/BD511/ch04/donnees/activites.json` | 1 000 000 activités, Extended JSON, un document par ligne (généré, 180 Mo) | 1.2 |
| `~/BD511/ch04/donnees/activites.json.gz` | Le même fichier, compressé (20 Mo) : fourni dans l'archive, facultatif | 1.2, 1.4 |
| `~/BD511/ch04/donnees/SHA256SUMS` | Somme de contrôle du fichier de données | 1.3 |
| `~/BD511/ch04/importer-activites.sh` | (Re)création de la collection dans son état initial | 1.4 |
| `~/BD511/ch04/requete-lente.js` | Requête de la page « Derniers quiz réussis » (application) | 2.1, 4.5 |
| `~/BD511/ch04/explain-resume.js` | Fonctions `resume()` et `etapesDuPlan()` pour mongosh | 2.6 |
| `~/BD511/ch04/comparer.js` | Comparaison des plans et durées, une variante par index | 4.1, 4.5 |
| `~/BD511/ch04/mesures-avant.txt`, `mesures-apres.txt` | Mesures de référence avant et après optimisation | 4.1, 4.5 |
| `~/BD511/ch04/cout-ecriture.js` | Mesure du coût des index sur les insertions | 5.2, 5.4 |
| `~/BD511/ch04/suivre-construction.js` | Suivi d'une construction d'index par `$currentOp` | 5.5 |
| `~/BD511/ch04/verifier-ch04.sh` | Contrôle final | 6.1 |
| Base `BD511`, collection `activites` | 1 000 000 documents ; index `_id_`, `formation_type_date_score`, `stagiaire_date` | 1.4 à 5.5 |

## Annexe C – Rattrapage

Tous les fichiers du TP (scripts, `SHA256SUMS` et jeu de données compressé) sont fournis dans l'archive `BD511_CH04_fichiers.zip` : son contenu `home/BD511/ch04/` se copie dans `~/BD511/ch04/`.

**Repartir de l'état initial** (début de la partie 2 ou de la partie 4), dans le terminal 1 :

```bash
bash ~/BD511/ch04/importer-activites.sh
```

**Démarrer directement la partie 4** : après la remise à l'état initial, ouvrez la session mongosh du terminal 2 (partie 1.5) et préparez-la :

```javascript
load(process.env.HOME + "/BD511/ch04/explain-resume.js")
const filtre = { formation_id: "BD511", type: "quiz", score: { $gte: 80 } }
const tri = { date: -1 }
```

**Démarrer directement la partie 5** : préparez la session comme ci-dessus, puis créez les trois index de la partie 4 :

```javascript
db.activites.createIndex({ formation_id: 1 }, { name: "formation" })
db.activites.createIndex({ formation_id: 1, type: 1, score: 1, date: -1 }, { name: "formation_type_score_date" })
db.activites.createIndex({ formation_id: 1, type: 1, date: -1, score: 1 }, { name: "formation_type_date_score" })
```

## Annexe D – Références

- Analyse des requêtes : [Explain Results](https://www.mongodb.com/docs/manual/reference/explain-results/), [Query Plans](https://www.mongodb.com/docs/manual/core/query-plans/) (planificateur et cache de plans), [Query Optimization](https://www.mongodb.com/docs/manual/core/query-optimization/) (requêtes couvertes)
- Index composés : [Compound Indexes](https://www.mongodb.com/docs/manual/core/indexes/index-types/index-compound/), [The ESR (Equality, Sort, Range) Guideline](https://www.mongodb.com/docs/manual/tutorial/equality-sort-range-guideline/)
- Gestion des index : [Hidden Indexes](https://www.mongodb.com/docs/manual/core/index-hidden/), [$indexStats](https://www.mongodb.com/docs/manual/reference/operator/aggregation/indexStats/), [Index Builds on Populated Collections](https://www.mongodb.com/docs/manual/core/index-creation/)
- Compass : [View Query Performance](https://www.mongodb.com/docs/compass/current/query-plan/), [Manage Indexes](https://www.mongodb.com/docs/compass/current/indexes/)
- Journal et requêtes lentes : [Log Messages](https://www.mongodb.com/docs/manual/reference/log-messages/), [Database Profiler](https://www.mongodb.com/docs/manual/tutorial/manage-the-database-profiler/)
- Modélisation : [Data Modeling](https://www.mongodb.com/docs/manual/data-modeling/)
