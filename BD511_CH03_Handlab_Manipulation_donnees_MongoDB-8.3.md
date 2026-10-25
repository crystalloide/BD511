# BD511 – Chapitre 3 – Handlab : manipulation des données avec mongosh, Compass et PyMongo

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 3 – Manipulation des données : mongosh, Compass et drivers |
| **Durée indicative** | 2 h 30 |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop préparée au chapitre 2 : `mongod` actif, mongosh, Database Tools et Compass installés |
| **Versions vérifiées le 22/10/2026** | MongoDB Community Server **8.3.13** · mongosh **2.13.0** · Database Tools **100.19.1** · Compass **1.53.0** · Python **3.12** (Ubuntu 24.04) · PyMongo **4.19.0** · dnspython **2.9.0** · pip **26.2.2** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. importer un jeu de données JSON et CSV avec `mongoimport` en maîtrisant les types, et l'exporter avec `mongoexport` ;
2. interroger une collection avec `find` dans mongosh : critères, documents imbriqués, tableaux, types BSON, curseurs, puis modifier et supprimer des documents ;
3. réaliser les mêmes manipulations dans MongoDB Compass et construire un premier pipeline d'agrégation ;
4. créer et manipuler des documents depuis un programme Python avec PyMongo.

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Vérification de l'environnement et configuration de mongosh | 10 min |
| 1 | Import (JSON, CSV) et export du jeu de données | 20 min |
| 2 | Requêtes `find`, types, curseurs, mises à jour et suppressions dans mongosh | 50 min |
| 3 | Mêmes manipulations dans Compass et premier pipeline d'agrégation | 35 min |
| 4 | Création et manipulation de documents en Python avec PyMongo | 30 min |
| 5 | Bilan | 5 min |

## Conventions

- Les commandes **bash** s'exécutent dans un terminal de la VM (`Ctrl` + `Alt` + `T`) avec votre compte habituel ; `sudo` est indiqué quand des droits d'administration sont nécessaires.
- Les commandes **mongosh** se tapent à l'invite `BD511>` ; tapez-les une par une (ou collez un bloc entier : mongosh les exécute dans l'ordre).
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'` ou `sudo tee fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Le jeu de données est généré de façon déterministe : les nombres de documents, les montants et les identifiants sont **identiques** sur toutes les VM. Seuls varient les horodatages, les identifiants de connexion et les `ObjectId` créés pendant le TP.
- Tous les fichiers du TP sont générés dans `~/BD511/ch03` ; l'annexe B en donne la liste.

> **Note formateur.** Le script `importer.sh` (partie 1.8) remet la base `BD511` dans son état initial en quelques secondes. Les parties 3 et 4 commencent par lui : un stagiaire en retard peut ainsi les aborder même s'il n'a pas terminé la partie précédente.

---

## Partie 0 – Vérification de l'environnement

### 0.1 Créer l'espace de travail et installer le module `venv` de Python

La partie 4 utilise un environnement virtuel Python. Sur Ubuntu, le module `venv` est fourni par un paquet séparé, absent de l'installation par défaut :

```bash
mkdir -p ~/BD511/ch03/donnees ~/BD511/ch03/python
sudo apt-get update
sudo apt-get install -y python3-venv jq
```

### 0.2 Contrôler l'installation du chapitre 2

Relancez d'abord le contrôle des réglages de production réalisé à la fin du chapitre 2 :

```bash
sudo bash ~/BD511/ch02/check-mongodb.sh | tail -n 1
```

Résultat attendu :

```text
Bilan : 26 OK, 0 KO
```

Si le script est absent ou signale des points KO, reprenez le handlab du chapitre 2 avant de continuer.

Générez ensuite le contrôle propre à ce chapitre (outils clients, Python, accès au dépôt PyPI) et exécutez-le :

```bash
cat > ~/BD511/ch03/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.3 : vérifie l'environnement avant le TP
# Usage : bash ~/BD511/ch03/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Serveur et outils MongoDB"
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "Serveur MongoDB $v"; else nok "Serveur MongoDB 8.3 attendu (trouvé : ${v:-absent})"; fi
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=BD511-prerequis" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1
then ok "Connexion à mongodb://127.0.0.1:27017"; else nok "Connexion impossible à mongodb://127.0.0.1:27017"; fi
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
v=$(dpkg-query -W -f='${Version}' mongodb-compass 2>/dev/null)
if [[ -n $v ]]; then ok "MongoDB Compass $v"; else nok "Compass absent (chapitre 2, partie 4)"; fi

echo "== Python"
v=$(python3 -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])' 2>/dev/null)
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null
then ok "Python $v (PyMongo 4.19 exige 3.11 ou plus récent)"; else nok "Python 3.11 ou plus récent requis (trouvé : ${v:-absent})"; fi
if dpkg-query -W -f='${Status}' python3-venv 2>/dev/null | grep -q 'ok installed'
then ok "Paquet python3-venv installé"; else nok "python3-venv absent : sudo apt-get install -y python3-venv"; fi
if curl -sSf -m 10 -o /dev/null https://pypi.org/simple/pymongo/
then ok "Accès au dépôt PyPI"; else nok "PyPI injoignable : vérifiez l'accès Internet (proxy ?)"; fi

echo
if (( ko == 0 )); then echo "Résultat : environnement prêt pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch03/00-prerequis.sh
```

Résultat attendu :

```text
== Serveur et outils MongoDB
  [OK] Serveur MongoDB v8.3.13
  [OK] Service mongod actif
  [OK] Connexion à mongodb://127.0.0.1:27017
  [OK] mongosh 2.13.0
  [OK] Database Tools 100.19.1
  [OK] MongoDB Compass 1.53.0
== Python
  [OK] Python 3.12.3 (PyMongo 4.19 exige 3.11 ou plus récent)
  [OK] Paquet python3-venv installé
  [OK] Accès au dépôt PyPI

Résultat : environnement prêt pour le TP.
```

Vérifiez enfin qu'aucune version corrective plus récente de MongoDB 8.3 n'est publiée (veille de versions) :

```bash
apt-cache policy mongodb-org-server | head -n 3
```

Résultat attendu tant que 8.3.13 est la dernière version (les paquets sont en attente depuis le chapitre 2, une mise à niveau se planifie) :

```text
mongodb-org-server:
  Installed: 8.3.13
  Candidate: 8.3.13
```

### 0.3 Configurer mongosh pour l'exploitation

mongosh lit au démarrage un fichier de configuration global, `/etc/mongosh.conf` (format YAML), qui s'applique à tous les comptes de la machine. Sur un serveur de production, on l'utilise pour imposer quelques règles :

- `forceDisableTelemetry: true` : aucune donnée d'usage n'est envoyée à MongoDB, et les utilisateurs ne peuvent pas réactiver l'envoi ;
- `historyLength` : taille de l'historique des commandes (`~/.mongodb/mongosh/mongosh_repl_history`) ;
- `redactHistory: "remove-redact"` : les commandes sensibles (création d'utilisateur avec mot de passe…) ne sont pas conservées et les valeurs potentiellement sensibles (URI avec identifiants, adresses e-mail…) sont masquées dans l'historique. Ce réglage prendra tout son sens au chapitre 5.

```bash
sudo tee /etc/mongosh.conf > /dev/null <<'EOF'
# /etc/mongosh.conf - configuration globale de mongosh pour tous les comptes (BD511)
mongosh:
  # Aucune donnée d'usage envoyée à MongoDB, non modifiable par les utilisateurs
  forceDisableTelemetry: true
  # Historique plus long, sans les commandes sensibles (mots de passe, URI avec identifiants...)
  historyLength: 2000
  redactHistory: "remove-redact"
EOF
mongosh --quiet --eval 'print(config.get("enableTelemetry"), config.get("historyLength"), config.get("redactHistory"))'
```

Résultat attendu :

```text
false 2000 remove-redact
```

> Les réglages personnels (`config.set(...)` dans mongosh) sont enregistrés dans `~/.mongodb/mongosh/config` et l'emportent sur le fichier global, sauf `forceDisableTelemetry`.

---

## Partie 1 – Import et export du jeu de données

### 1.1 Générer les fichiers de données

Le jeu de données du TP décrit l'activité **fictive** d'un organisme de formation, dans la base `BD511` :

| Collection | Contenu | Format source | Particularités |
| --- | --- | --- | --- |
| `formations` | 24 formations (le catalogue du chapitre 2) | tableau JSON | tableaux, documents imbriqués (`sessions`), `Decimal128` |
| `stagiaires` | 300 stagiaires | CSV | adresse imbriquée, codes postaux à zéro initial, dates, booléens, cellules vides |
| `inscriptions` | 1 202 inscriptions à des sessions | JSON, un document par ligne | `ObjectId`, dates, montants `Decimal128`, évaluations parfois absentes, nulles ou saisies en texte |

Les fichiers sont produits par un script Python qui n'utilise que la bibliothèque standard. Son générateur pseudo-aléatoire est déterministe : tout le monde obtient exactement les mêmes données, ce que la somme de contrôle de l'étape suivante vérifie.

```bash
cat > ~/BD511/ch03/generer_donnees.py <<'EOF'
#!/usr/bin/env python3
"""generer_donnees.py - BD511 ch.3 : génère le jeu de données du TP (bibliothèque standard uniquement).

Fichiers produits dans le répertoire courant :
  formations.json     24 formations, tableau JSON (Extended JSON)    -> mongoimport --jsonArray
  stagiaires.csv      300 stagiaires, CSV avec ligne d'en-tête         -> mongoimport --type csv
  stagiaires.fields   types des colonnes du CSV                         -> mongoimport --columnsHaveTypes
  inscriptions.json   inscriptions, un document Extended JSON par ligne -> mongoimport

Toutes les données sont fictives. Le générateur pseudo-aléatoire est déterministe :
les fichiers sont identiques sur toutes les machines et avec toutes les versions de Python 3,
ce qui permet de comparer vos résultats avec ceux du handlab.
"""
import csv
import json
import unicodedata
from datetime import datetime, timedelta, timezone

M64 = 0xFFFFFFFFFFFFFFFF
UTC = timezone.utc
REFERENCE = datetime(2026, 10, 19, tzinfo=UTC)    # « aujourd'hui » pour le jeu de données
FIN_ANCIEN_LMS = datetime(2024, 4, 1, tzinfo=UTC)  # avant cette date : notes migrées en texte


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

    def choix(self, sequence):
        return sequence[self.entier(0, len(sequence) - 1)]

    def pourcent(self, p):
        return self.entier(1, 100) <= p

    def echantillon(self, sequence, k):
        pool = list(sequence)
        for i in range(k):
            j = self.entier(i, len(pool) - 1)
            pool[i], pool[j] = pool[j], pool[i]
        return pool[:k]


# Catalogue du chapitre 2 (une formation par ligne, Extended JSON)
FORMATIONS_NDJSON = """\
{"_id":"BD511","titre":"NoSQL MongoDB : mise en œuvre et administration","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-10-18T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-16T09:00:00Z"},"ville":"Paris","places":12,"inscrits":9},{"debut":{"$date":"2026-12-14T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":4},{"debut":{"$date":"2027-01-25T09:00:00Z"},"ville":"À distance","places":12,"inscrits":2}],"tags":["mongodb","nosql","administration","replica set","sharding"],"note_moyenne":4.7}
{"_id":"BD512","titre":"MongoDB pour les développeurs","domaine":"Bases de données","niveau":"Fondamental","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-09-02T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-23T09:00:00Z"},"ville":"Paris","places":12,"inscrits":11},{"debut":{"$date":"2027-02-08T09:00:00Z"},"ville":"Nantes","places":10,"inscrits":3}],"tags":["mongodb","développement","agrégation","drivers"],"note_moyenne":4.5}
{"_id":"BD513","titre":"Apache Cassandra : architecture et exploitation","domaine":"Bases de données","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2290.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-06-15T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Paris","places":8,"inscrits":5}],"tags":["cassandra","nosql","cql","haute disponibilité"],"prerequis":["BD511"]}
{"_id":"BD514","titre":"Redis : cache, structures de données et haute disponibilité","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-05-20T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-30T09:00:00Z"},"ville":"À distance","places":14,"inscrits":7}],"tags":["redis","clé-valeur","cache","sentinel"],"note_moyenne":4.4}
{"_id":"BD515","titre":"Neo4j et le langage Cypher","domaine":"Bases de données","niveau":"Fondamental","duree_jours":2,"prix_ht":{"$numberDecimal":"1390.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-03-11T00:00:00Z"},"sessions":[],"tags":["neo4j","graphes","cypher"]}
{"_id":"BD516","titre":"Elastic Stack : Elasticsearch, Logstash et Kibana","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-10-05T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-09T09:00:00Z"},"ville":"Paris","places":12,"inscrits":10},{"debut":{"$date":"2027-01-18T09:00:00Z"},"ville":"Toulouse","places":10,"inscrits":1}],"tags":["elasticsearch","logstash","kibana","recherche"],"note_moyenne":4.6}
{"_id":"BD520","titre":"PostgreSQL : administration","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2590.00"},"modalites":["présentiel","classe virtuelle","intra-entreprise"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-08-28T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-01T09:00:00Z"},"ville":"Paris","places":12,"inscrits":12},{"debut":{"$date":"2027-03-08T09:00:00Z"},"ville":"Lille","places":10,"inscrits":0}],"tags":["postgresql","sql","administration","sauvegarde"],"note_moyenne":4.8}
{"_id":"BG601","titre":"Hadoop et HDFS : les fondamentaux","domaine":"Big Data","niveau":"Fondamental","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-04-02T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-16T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":6}],"tags":["hadoop","hdfs","yarn"]}
{"_id":"BG602","titre":"Apache Spark avancé","domaine":"Big Data","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2390.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-07-21T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"À distance","places":12,"inscrits":8}],"tags":["spark","dataframe","streaming","optimisation"],"prerequis":["BG601"],"note_moyenne":4.6}
{"_id":"BG603","titre":"Apache Kafka : streaming d'événements","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-09-14T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-02T09:00:00Z"},"ville":"Paris","places":12,"inscrits":12},{"debut":{"$date":"2027-01-11T09:00:00Z"},"ville":"Bordeaux","places":10,"inscrits":5}],"tags":["kafka","événements","streaming","event sourcing"],"note_moyenne":4.7}
{"_id":"BG604","titre":"Apache NiFi : conception de flux de données","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1590.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-02-17T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-02-15T09:00:00Z"},"ville":"À distance","places":12,"inscrits":3}],"tags":["nifi","ingestion","etl"]}
{"_id":"BG605","titre":"Apache Airflow : orchestration de pipelines","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1590.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-07-19T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-10T09:00:00Z"},"ville":"Paris","places":12,"inscrits":4}],"tags":["airflow","orchestration","dag","python"],"note_moyenne":4.3}
{"_id":"BG606","titre":"Apache Hive : entrepôt de données sur Hadoop","domaine":"Big Data","niveau":"Avancé","duree_jours":2,"prix_ht":{"$numberDecimal":"1690.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-01T00:00:00Z"},"sessions":[],"tags":["hive","hiveql","tez","llap"],"prerequis":["BG601"]}
{"_id":"IA101","titre":"IA générative : panorama et usages","domaine":"Intelligence artificielle","niveau":"Fondamental","duree_jours":1,"prix_ht":{"$numberDecimal":"790.00"},"modalites":["classe virtuelle","intra-entreprise"],"certifiante":false,"mise_a_jour":{"$date":"2026-09-30T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-05T09:00:00Z"},"ville":"À distance","places":20,"inscrits":17},{"debut":{"$date":"2026-12-03T09:00:00Z"},"ville":"À distance","places":20,"inscrits":6}],"tags":["ia générative","llm","prompt"],"note_moyenne":4.5}
{"_id":"IA102","titre":"IA agentique : conception d'applications multi-agents avec des LLM","domaine":"Intelligence artificielle","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-10T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-14T09:00:00Z"},"ville":"Paris","places":10,"inscrits":7}],"tags":["agents","langgraph","rag","llm"],"prerequis":["IA101","PY201"]}
{"_id":"IA103","titre":"Machine learning avec Python","domaine":"Intelligence artificielle","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2690.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-06-03T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-23T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":10},{"debut":{"$date":"2027-02-01T09:00:00Z"},"ville":"Paris","places":12,"inscrits":3}],"tags":["machine learning","scikit-learn","python"],"prerequis":["PY201"],"note_moyenne":4.6}
{"_id":"DO301","titre":"Docker : conteneuriser ses applications","domaine":"DevOps","niveau":"Fondamental","duree_jours":2,"prix_ht":{"$numberDecimal":"1390.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-08-12T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-12T09:00:00Z"},"ville":"Paris","places":12,"inscrits":8},{"debut":{"$date":"2026-12-17T09:00:00Z"},"ville":"Marseille","places":10,"inscrits":2}],"tags":["docker","conteneurs","compose"],"note_moyenne":4.6}
{"_id":"DO302","titre":"Kubernetes : déploiement et exploitation","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2690.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"mise_a_jour":{"$date":"2026-09-22T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-01T09:00:00Z"},"ville":"À distance","places":12,"inscrits":9}],"tags":["kubernetes","orchestration","helm"],"prerequis":["DO301"],"note_moyenne":4.7}
{"_id":"DO303","titre":"Ansible : automatisation de l'infrastructure","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-05-06T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-01-20T09:00:00Z"},"ville":"Rennes","places":10,"inscrits":4}],"tags":["ansible","automatisation","infrastructure as code"]}
{"_id":"DO304","titre":"Supervision avec Prometheus et Grafana","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-12T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-26T09:00:00Z"},"ville":"Paris","places":12,"inscrits":6}],"tags":["prometheus","grafana","alerting","supervision"],"note_moyenne":4.5}
{"_id":"SY401","titre":"Administration Linux : les fondamentaux","domaine":"Systèmes","niveau":"Fondamental","duree_jours":5,"prix_ht":{"$numberDecimal":"2490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-01-14T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-02T09:00:00Z"},"ville":"Paris","places":12,"inscrits":11},{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":5},{"debut":{"$date":"2027-01-11T09:00:00Z"},"ville":"À distance","places":14,"inscrits":3}],"tags":["linux","bash","systemd","administration"],"note_moyenne":4.4}
{"_id":"SY402","titre":"Linux : performances et optimisation","domaine":"Systèmes","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-04-28T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-02-22T09:00:00Z"},"ville":"Paris","places":8,"inscrits":2}],"tags":["linux","performances","noyau","sysctl"],"prerequis":["SY401"]}
{"_id":"PY201","titre":"Python : les fondamentaux","domaine":"Programmation","niveau":"Fondamental","duree_jours":4,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-07-01T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-09T09:00:00Z"},"ville":"À distance","places":16,"inscrits":14},{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Nantes","places":10,"inscrits":6}],"tags":["python","programmation"],"note_moyenne":4.8}
{"_id":"PY202","titre":"Python pour l'analyse de données","domaine":"Programmation","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"1790.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-08-25T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-01-25T09:00:00Z"},"ville":"À distance","places":16,"inscrits":5}],"tags":["python","pandas","visualisation"],"prerequis":["PY201"]}
"""

PRENOMS = ["Alice", "Antoine", "Camille", "Chloé", "Claire", "David", "Élise", "Emma", "Éric", "Fatima",
           "François", "Hugo", "Inès", "Isabelle", "Jean", "Julie", "Karim", "Laura", "Léa", "Louis",
           "Lucas", "Manon", "Marc", "Marie", "Mathieu", "Nadia", "Nicolas", "Noémie", "Olivier", "Pauline",
           "Philippe", "Rachid", "Romain", "Sarah", "Sophie", "Stéphanie", "Thomas", "Valérie", "Yanis", "Zoé"]
NOMS = ["Bernard", "Blanc", "Bonnet", "Boyer", "Chevalier", "David", "Dubois", "Dumont", "Dupont", "Durand",
        "Fabre", "Faure", "Fontaine", "Fournier", "Garcia", "Gauthier", "Girard", "Guerin", "Henry", "Lambert",
        "Laurent", "Lefebvre", "Leroy", "Martin", "Martinez", "Mercier", "Michel", "Morel", "Moreau", "Muller",
        "Nguyen", "Perrin", "Petit", "Renard", "Robert", "Roche", "Rousseau", "Roux", "Simon", "Vincent"]
ENTREPRISES = ["Acme Data", "Brioche & Co", "Cap Horizon", "Datavolt", "Eolys", "Fjordia Assurances",
               "Galathée Santé", "Hexaplan", "Irisbank", "Jadis Retail", "Kapteyn Industrie", "Lumenia Média"]
FONCTIONS = ["Administrateur systèmes", "Administrateur de bases de données", "Architecte", "Chef de projet",
             "Data engineer", "Développeur", "Ingénieur DevOps"]
VILLES = [("Paris", "75011"), ("Paris", "75015"), ("Lyon", "69003"), ("Marseille", "13008"),
          ("Toulouse", "31000"), ("Nantes", "44000"), ("Bordeaux", "33000"), ("Lille", "59000"),
          ("Strasbourg", "67000"), ("Rennes", "35000"), ("Grenoble", "38000"), ("Montpellier", "34000"),
          ("Nice", "06000"), ("Bourg-en-Bresse", "01000"), ("Laon", "02000"), ("Gap", "05000"),
          ("Charleville-Mézières", "08000"), ("Ajaccio", "20000"), ("Annecy", "74000"), ("Dijon", "21000")]
VILLES_SESSIONS = ["Paris", "Paris", "Lyon", "Lyon", "Nantes", "Bordeaux", "Toulouse", "Lille", "À distance", "À distance"]
COMMENTAIRES = ["Très bon formateur, TP concrets.", "Rythme un peu soutenu le dernier jour.",
                "Contenu à jour, conforme au programme.", "Les labs ont parfois été lents à démarrer.",
                "Excellente formation, je recommande.", "Il manquait des exemples sur notre cas d'usage.",
                "Bon équilibre entre théorie et pratique.", "Support de cours très clair."]
MOTIFS = ["report à la demande de l'entreprise", "effectif insuffisant", "indisponibilité du stagiaire",
          "changement de priorités du projet"]
NOTES = [5] * 40 + [4] * 35 + [3] * 15 + [2] * 7 + [1] * 3


def ascii_minuscule(texte):
    sans_accents = unicodedata.normalize("NFKD", texte).encode("ascii", "ignore").decode()
    return "".join(c if c.isalnum() else "-" for c in sans_accents.lower()).strip("-")


def ejson_date(d):
    return {"$date": d.strftime("%Y-%m-%dT%H:%M:%SZ")}


def ejson_decimal(centimes):
    return {"$numberDecimal": f"{centimes // 100}.{centimes % 100:02d}"}


def lire_date(texte):
    return datetime.strptime(texte, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def generer_stagiaires(alea, nombre=300):
    stagiaires, emails = [], set()
    for i in range(1, nombre + 1):
        prenom, nom = alea.choix(PRENOMS), alea.choix(NOMS)
        entreprise = alea.choix(ENTREPRISES)
        base = f"{ascii_minuscule(prenom)}.{ascii_minuscule(nom)}"
        email, n = f"{base}@{ascii_minuscule(entreprise)}.example", 2
        while email in emails:
            email, n = f"{base}{n}@{ascii_minuscule(entreprise)}.example", n + 1
        emails.add(email)
        ville, code_postal = alea.choix(VILLES)
        tirage = alea.entier(1, 100)
        chiffres = [alea.entier(0, 99) for _ in range(4)]
        prefixe = alea.choix(["06", "07"])
        if tirage <= 70:
            telephone = prefixe + "".join(f" {c:02d}" for c in chiffres)
        elif tirage <= 85:
            telephone = prefixe + "".join(f"{c:02d}" for c in chiffres)
        else:
            telephone = ""
        stagiaires.append({
            "_id": f"STG{i:04d}", "nom": nom, "prenom": prenom, "email": email, "entreprise": entreprise,
            "fonction": alea.choix(FONCTIONS), "adresse.ville": ville, "adresse.code_postal": code_postal,
            "telephone": telephone, "actif": "true" if alea.pourcent(92) else "false",
            "inscrit_le": None, "annees_experience": alea.entier(0, 30),
        })
    return stagiaires


def generer_inscriptions(alea, formations, stagiaires):
    inscrits_possibles = [s["_id"] for s in stagiaires[:285]]  # STG0286 à STG0300 : prospects sans inscription
    premieres = {}
    inscriptions = []
    compteur = 0
    lundi = datetime(2024, 1, 8, 9, tzinfo=UTC)
    for f in formations:
        # Sessions passées (générées) puis sessions futures (celles du catalogue du chapitre 2)
        sessions = []
        for _ in range(alea.entier(4, 7)):
            debut = lundi + timedelta(weeks=alea.entier(0, 141))
            ville = alea.choix(VILLES_SESSIONS)
            sessions.append((debut, ville, alea.entier(4, 10), True))
        for s in f["sessions"]:
            sessions.append((lire_date(s["debut"]["$date"]), s["ville"], s["inscrits"], False))
        sessions.sort(key=lambda s: s[0])
        prix_centimes = int(f["prix_ht"]["$numberDecimal"].replace(".", ""))
        for debut, ville, effectif, passee in sessions:
            for stagiaire_id in alea.echantillon(inscrits_possibles, effectif):
                compteur += 1
                jour = debut - timedelta(days=alea.entier(7, 90))
                date_inscription = jour.replace(hour=alea.entier(7, 17), minute=alea.entier(0, 59))
                doc = {
                    "_id": None,
                    "stagiaire_id": stagiaire_id,
                    "formation_id": f["_id"],
                    "session": {"debut": ejson_date(debut), "ville": ville,
                                "modalite": "classe virtuelle" if ville == "À distance" else "présentiel"},
                    "date_inscription": ejson_date(date_inscription),
                }
                if passee:
                    doc["statut"] = "annulée" if alea.pourcent(12) else "terminée"
                else:
                    doc["statut"] = "en attente" if alea.pourcent(25) else "confirmée"
                remise = alea.choix([5, 10, 15, 20]) if alea.pourcent(15) else 0
                doc["prix_ht"] = ejson_decimal(prix_centimes * (100 - remise) // 100)
                if remise:
                    doc["remise_pct"] = remise
                tirage = alea.entier(1, 100)
                if tirage <= 15 and f.get("eligible_cpf"):
                    doc["financement"] = "CPF"
                elif tirage <= 40:
                    doc["financement"] = "OPCO"
                elif tirage <= 50:
                    doc["financement"] = "personnel"
                else:
                    doc["financement"] = "entreprise"
                if doc["statut"] == "terminée":
                    jours = f["duree_jours"]
                    presences = [True] * jours
                    if alea.pourcent(10):
                        presences[alea.entier(0, jours - 1)] = False
                    doc["presences"] = presences
                    tirage = alea.entier(1, 100)
                    if tirage <= 80:
                        note = alea.choix(NOTES)
                        valeur = note - 0.5 if note > 1 and alea.pourcent(10) else note
                        if date_inscription < FIN_ANCIEN_LMS and valeur == note:
                            valeur = str(note)          # données migrées de l'ancien LMS : note en texte
                        evaluation = {"note": valeur, "le": ejson_date(debut + timedelta(days=jours - 1, hours=7))}
                        if alea.pourcent(35):
                            evaluation["commentaire"] = alea.choix(COMMENTAIRES)
                        doc["evaluation"] = evaluation
                    elif tirage <= 92:
                        doc["evaluation"] = None        # questionnaire envoyé, sans réponse
                elif doc["statut"] == "annulée":
                    doc["annulation"] = {"le": ejson_date(debut - timedelta(days=alea.entier(1, 6))),
                                         "motif": alea.choix(MOTIFS)}
                secondes = int(date_inscription.timestamp())
                doc["_id"] = {"$oid": f"{secondes:08x}b5110c3000{compteur:06x}"}
                inscriptions.append(doc)
                if stagiaire_id not in premieres or date_inscription < premieres[stagiaire_id]:
                    premieres[stagiaire_id] = date_inscription
    inscriptions.sort(key=lambda d: d["_id"]["$oid"])
    return inscriptions, premieres


def main():
    alea = Alea(511)
    formations = [json.loads(ligne) for ligne in FORMATIONS_NDJSON.splitlines() if ligne.strip()]
    stagiaires = generer_stagiaires(alea)
    inscriptions, premieres = generer_inscriptions(alea, formations, stagiaires)
    for s in stagiaires:
        if s["_id"] in premieres:
            date = premieres[s["_id"]] - timedelta(days=alea.entier(0, 30))
        else:
            date = REFERENCE - timedelta(days=alea.entier(5, 120))
        s["inscrit_le"] = date.strftime("%Y-%m-%d")

    with open("formations.json", "w", encoding="utf-8") as sortie:
        sortie.write("[\n" + ",\n".join(json.dumps(f, ensure_ascii=False, separators=(",", ":"))
                                       for f in formations) + "\n]\n")
    colonnes = list(stagiaires[0].keys())
    with open("stagiaires.csv", "w", encoding="utf-8", newline="") as sortie:
        ecrivain = csv.DictWriter(sortie, fieldnames=colonnes, lineterminator="\n")
        ecrivain.writeheader()
        ecrivain.writerows(stagiaires)
    types = {"actif": "boolean()", "inscrit_le": "date(2006-01-02)", "annees_experience": "int32()"}
    with open("stagiaires.fields", "w", encoding="utf-8") as sortie:
        sortie.write("".join(f"{c}.{types.get(c, 'string()')}\n" for c in colonnes))
    with open("inscriptions.json", "w", encoding="utf-8") as sortie:
        for doc in inscriptions:
            sortie.write(json.dumps(doc, ensure_ascii=False, separators=(",", ":")) + "\n")
    print(f"formations.json   : {len(formations)} formations")
    print(f"stagiaires.csv    : {len(stagiaires)} stagiaires")
    print(f"inscriptions.json : {len(inscriptions)} inscriptions")


if __name__ == "__main__":
    main()
EOF
cd ~/BD511/ch03/donnees
python3 ../generer_donnees.py
```

Résultat attendu :

```text
formations.json   : 24 formations
stagiaires.csv    : 300 stagiaires
inscriptions.json : 1202 inscriptions
```

Vérifiez que vos fichiers sont identiques aux fichiers de référence :

```bash
cat > ~/BD511/ch03/donnees/SHA256SUMS <<'EOF'
cafeaac3d6e29a87de27a9076c171ff43f363405a24eb0726b2a15e5685a0362  formations.json
74b753a7440ea0c29efe3c28180ff1c8f9e45d7e064e0531410f064f8bc555a5  inscriptions.json
cec5f4a1804665934d5bc771899a46fdd600ce44848fa22a9aafa9c2be61027e  stagiaires.csv
1f7828c0aeb0995a15f4dc392e2ae3863e9a141c982279706ab1bb87cffb2d1a  stagiaires.fields
EOF
sha256sum --check ~/BD511/ch03/donnees/SHA256SUMS
```

Résultat attendu :

```text
formations.json: OK
inscriptions.json: OK
stagiaires.csv: OK
stagiaires.fields: OK
```

Un `FAILED` signale une erreur de copie du script : recopiez le bloc `generer_donnees.py` en entier et relancez la génération.

### 1.2 Examiner les fichiers

```bash
cd ~/BD511/ch03/donnees
head -n 3 stagiaires.csv
cat stagiaires.fields
head -n 1 inscriptions.json
```

Résultat attendu :

```text
_id,nom,prenom,email,entreprise,fonction,adresse.ville,adresse.code_postal,telephone,actif,inscrit_le,annees_experience
STG0001,Lambert,Karim,karim.lambert@kapteyn-industrie.example,Kapteyn Industrie,Chef de projet,Marseille,13008,0688172857,true,2024-06-25,12
STG0002,Guerin,Chloé,chloe.guerin@galathee-sante.example,Galathée Santé,Chef de projet,Bourg-en-Bresse,01000,06 12 31 62 33,true,2025-03-24,8
_id.string()
nom.string()
prenom.string()
email.string()
entreprise.string()
fonction.string()
adresse.ville.string()
adresse.code_postal.string()
telephone.string()
actif.boolean()
inscrit_le.date(2006-01-02)
annees_experience.int32()
{"_id":{"$oid":"6527e434b5110c3000000480"},"stagiaire_id":"STG0186","formation_id":"PY202","session":{"debut":{"$date":"2024-01-08T09:00:00Z"},"ville":"Lyon","modalite":"présentiel"},"date_inscription":{"$date":"2023-10-12T12:19:00Z"},"statut":"terminée","prix_ht":{"$numberDecimal":"1790.00"},"financement":"entreprise","presences":[true,true,true],"evaluation":{"note":"4","le":{"$date":"2024-01-10T16:00:00Z"},"commentaire":"Rythme un peu soutenu le dernier jour."}}
```

Observations :

- Dans le CSV, les noms de colonnes `adresse.ville` et `adresse.code_postal` contiennent un point : `mongoimport` en fera un **document imbriqué** `adresse`.
- Le CSV ne porte aucune information de type : `01000`, `true` ou `2025-03-24` ne sont que du texte. Le fichier `stagiaires.fields` décrit le type attendu de chaque colonne.
- Les fichiers JSON utilisent le format **Extended JSON**, qui conserve les types BSON que le JSON ne connaît pas :

| Notation Extended JSON | Type BSON | Exemple |
| --- | --- | --- |
| `{"$oid": "…"}` | ObjectId | identifiant de l'inscription |
| `{"$date": "2024-01-08T09:00:00Z"}` | Date (UTC) | début de session |
| `{"$numberDecimal": "1790.00"}` | Decimal128 | montant exact, sans erreur d'arrondi |
| nombre entier / décimal | Int32 / Double | `3`, `4.5` |

### 1.3 Importer un tableau JSON : `formations`

Le fichier `formations.json` contient un **tableau** JSON ; l'option `--jsonArray` l'indique à `mongoimport`. L'option `--drop` vide la collection avant l'import (elle remplace ici la collection créée au chapitre 2 par un contenu identique), et `appName` identifie l'outil dans le journal du serveur.

```bash
cd ~/BD511/ch03/donnees
URI="mongodb://127.0.0.1:27017/?appName=BD511-import"
mongoimport --uri "$URI" --db BD511 --collection formations --drop --jsonArray --file formations.json
```

Résultat attendu (les horodatages varient) :

```text
2026-10-22T16:32:50.389+0200	connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
2026-10-22T16:32:50.390+0200	dropping: `BD511.formations`
2026-10-22T16:32:50.399+0200	24 document(s) imported successfully. 0 document(s) failed to import.
```

### 1.4 Importer des documents JSON ligne à ligne : `inscriptions`

Sans `--jsonArray`, `mongoimport` attend un document par ligne. Le *write concern* `majority` (valeur par défaut des Database Tools, précisée ici explicitement) n'acquitte chaque lot qu'une fois écrit sur la majorité des membres d'un replica set. Sur notre instance autonome, il se comporte comme un acquittement simple ; le garder explicite rend le script valable tel quel après le passage en replica set (chapitre 6).

```bash
mongoimport --uri "$URI" --db BD511 --collection inscriptions --drop --writeConcern '{w: "majority"}' --file inscriptions.json
```

Résultat attendu :

```text
… connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
… dropping: `BD511.inscriptions`
… 1202 document(s) imported successfully. 0 document(s) failed to import.
```

### 1.5 Importer le CSV sans typage : `stagiaires_brut`

Importez d'abord le CSV « naïvement », en vous contentant de la ligne d'en-tête :

```bash
mongoimport --uri "$URI" --db BD511 --collection stagiaires_brut --drop --type csv --headerline --file stagiaires.csv
mongosh --quiet "mongodb://127.0.0.1:27017/BD511" --eval 'db.stagiaires_brut.findOne({ _id: "STG0002" })'
```

Résultat attendu :

```text
… connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
… dropping: `BD511.stagiaires_brut`
… 300 document(s) imported successfully. 0 document(s) failed to import.
{
  _id: 'STG0002',
  nom: 'Guerin',
  prenom: 'Chloé',
  email: 'chloe.guerin@galathee-sante.example',
  entreprise: 'Galathée Santé',
  fonction: 'Chef de projet',
  adresse: { ville: 'Bourg-en-Bresse', code_postal: 1000 },
  telephone: '06 12 31 62 33',
  actif: 'true',
  inscrit_le: '2025-03-24',
  annees_experience: 8
}
```

**Autre exemple de document importé** 
```bash
mongosh --quiet "mongodb://127.0.0.1:27017/BD511" --eval 'db.stagiaires_brut.findOne({ _id: "STG0001" })'
```

L'import « fonctionne » donc apparemment, mais les données sont dégradées. Sans indication, `mongoimport` convertit en nombre tout ce qui ressemble à un nombre, et laisse le reste en texte :

- le code postal `01000` est devenu l'**entier** `1000` : le zéro initial est perdu ;
- les numéros de téléphone saisis sans espace (`0688172857`) sont aussi devenus des entiers sans zéro initial ;
- `actif` et `inscrit_le` sont restés des **chaînes** : une requête sur `actif: true` ou sur une plage de dates ne les trouvera pas ;
- les cellules vides sont devenues des chaînes vides `""`.

Vous mesurerez l'effet de ces erreurs de type dans la partie 2.8.

### 1.6 Importer le CSV avec typage : `stagiaires`

En production, on décrit le type de chaque colonne. Le fichier `stagiaires.fields` associe un type à chaque colonne (`string()`, `boolean()`, `int32()`, `date(2006-01-02)` où `2006-01-02` est le modèle de date au format du langage Go). Comme il remplace la ligne d'en-tête, on retire celle-ci du CSV avec `tail -n +2` et on transmet les lignes à `mongoimport` par l'entrée standard :

```bash
tail -n +2 stagiaires.csv | mongoimport --uri "$URI" --db BD511 --collection stagiaires --drop --type csv \
  --columnsHaveTypes --fieldFile stagiaires.fields --ignoreBlanks --parseGrace stop
mongosh --quiet "mongodb://127.0.0.1:27017/BD511" --eval 'db.stagiaires.findOne({ _id: "STG0002" })'
```

Résultat attendu :

```text
… connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
… dropping: `BD511.stagiaires`
… 300 document(s) imported successfully. 0 document(s) failed to import.
{
  _id: 'STG0002',
  nom: 'Guerin',
  prenom: 'Chloé',
  email: 'chloe.guerin@galathee-sante.example',
  entreprise: 'Galathée Santé',
  fonction: 'Chef de projet',
  adresse: { ville: 'Bourg-en-Bresse', code_postal: '01000' },
  telephone: '06 12 31 62 33',
  actif: true,
  inscrit_le: ISODate('2025-03-24T00:00:00.000Z'),
  annees_experience: 8
}
```

Les options utilisées sont celles que l'on retient pour un import de production :

| Option | Rôle |
| --- | --- |
| `--columnsHaveTypes` + `--fieldFile` | type explicite de chaque colonne, plus aucune conversion implicite |
| `--ignoreBlanks` | une cellule vide n'ajoute pas de champ (au lieu d'un `""`) |
| `--parseGrace stop` | arrêt à la première valeur non convertible, au lieu de l'ignorer en silence |
| `--writeConcern '{w: "majority"}'` | écriture confirmée par la majorité des membres (valeur par défaut, à garder) |
| `--stopOnError` | arrêt à la première erreur d'écriture (doublon de `_id`…) |
| `--drop` / `--mode upsert` | remplacer toute la collection, ou mettre à jour les documents existants |
| `--numInsertionWorkers` | nombre d'insertions parallèles, pour les gros volumes |

### 1.7 Exporter avec `mongoexport`

Exportez au format CSV les stagiaires de l'entreprise *Acme Data*, triés par identifiant. Pour un export CSV, la liste des champs est obligatoire ; la notation pointée désigne un champ imbriqué :

```bash
mongoexport --uri "$URI" --db BD511 --collection stagiaires --type csv \
  --fields _id,nom,prenom,entreprise,adresse.ville,adresse.code_postal \
  --query '{"entreprise": "Acme Data"}' --sort '{"_id": 1}' --out acme-data.csv
head -n 4 acme-data.csv
```

Résultat attendu :

```text
… connected to: mongodb://127.0.0.1:27017/?appName=BD511-import
… exported 23 records
_id,nom,prenom,entreprise,adresse.ville,adresse.code_postal
STG0013,Simon,Stéphanie,Acme Data,Annecy,74000
STG0027,Laurent,Yanis,Acme Data,Dijon,21000
STG0045,Muller,Lucas,Acme Data,Bordeaux,33000
```

Exportez ensuite une inscription au format JSON, d'abord dans le format par défaut (*relaxed*), puis dans le format *canonical*, qui conserve le type exact de chaque nombre et de chaque date :

```bash
mongoexport --uri "$URI" --db BD511 --collection inscriptions --quiet --limit 1 \
  --query '{"stagiaire_id": "STG0002", "statut": "terminée"}' --sort '{"_id": 1}'
mongoexport --uri "$URI" --db BD511 --collection inscriptions --quiet --limit 1 \
  --query '{"stagiaire_id": "STG0002", "statut": "terminée"}' --sort '{"_id": 1}' --jsonFormat canonical
```

Résultat attendu :

```text
{"_id":{"$oid":"67e17370b5110c3000000059"},"stagiaire_id":"STG0002","formation_id":"BD512","session":{"debut":{"$date":"2025-05-19T09:00:00Z"},"ville":"Lyon","modalite":"présentiel"},"date_inscription":{"$date":"2025-03-24T15:00:00Z"},"statut":"terminée","prix_ht":{"$numberDecimal":"1990.00"},"financement":"entreprise","presences":[true,true,true],"evaluation":{"note":3,"le":{"$date":"2025-05-21T16:00:00Z"}}}
{"_id":{"$oid":"67e17370b5110c3000000059"},"stagiaire_id":"STG0002","formation_id":"BD512","session":{"debut":{"$date":{"$numberLong":"1747645200000"}},"ville":"Lyon","modalite":"présentiel"},"date_inscription":{"$date":{"$numberLong":"1742828400000"}},"statut":"terminée","prix_ht":{"$numberDecimal":"1990.00"},"financement":"entreprise","presences":[true,true,true],"evaluation":{"note":{"$numberInt":"3"},"le":{"$date":{"$numberLong":"1747843200000"}}}}
```

> **À retenir.** Un export CSV perd les types (tout redevient texte) ; un export JSON *canonical* est le plus fidèle pour un échange entre bases MongoDB. Pour une **sauvegarde**, on utilise `mongodump` (format BSON), étudié au chapitre 9.

### 1.8 Générer le script de (ré)import

Le script `importer.sh` regroupe les imports précédents. Il vérifie d'abord la somme de contrôle des fichiers, puis remet les quatre collections dans leur état initial. Vous l'utiliserez au début des parties 3 et 4.

```bash
cat > ~/BD511/ch03/importer.sh <<'EOF'
#!/usr/bin/env bash
# importer.sh - BD511 ch.3 : (ré)importe le jeu de données du TP dans la base BD511
# Usage : bash ~/BD511/ch03/importer.sh
set -euo pipefail

DONNEES="$HOME/BD511/ch03/donnees"
URI="mongodb://127.0.0.1:27017/?appName=BD511-import"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers de données différents de la référence : relancez la partie 1.1." >&2; exit 1; }

# Options communes : écriture confirmée par la majorité, arrêt à la première erreur, collection vidée avant import.
commun=(--uri "$URI" --db BD511 --drop --writeConcern '{w: "majority"}' --stopOnError --quiet)

mongoimport "${commun[@]}" --collection formations --jsonArray --file formations.json
mongoimport "${commun[@]}" --collection inscriptions --file inscriptions.json
mongoimport "${commun[@]}" --collection stagiaires_brut --type csv --headerline --file stagiaires.csv
tail -n +2 stagiaires.csv | mongoimport "${commun[@]}" --collection stagiaires --type csv \
  --columnsHaveTypes --fieldFile stagiaires.fields --ignoreBlanks --parseGrace stop

mongosh --quiet "mongodb://127.0.0.1:27017/BD511?appName=BD511-import" --eval '
  for (const nom of ["formations", "inscriptions", "stagiaires", "stagiaires_brut"]) {
    print(nom.padEnd(16) + ": " + db.getCollection(nom).countDocuments() + " documents");
  }'
EOF
bash ~/BD511/ch03/importer.sh
```

Résultat attendu :

```text
formations      : 24 documents
inscriptions    : 1202 documents
stagiaires      : 300 documents
stagiaires_brut : 300 documents
```

---

## Partie 2 – Manipuler les données dans mongosh

### 2.1 Se connecter avec une chaîne de connexion

Une chaîne de connexion (URI) décrit en une ligne le serveur, la base par défaut et les options du client :

```text
mongodb://127.0.0.1:27017/BD511?appName=BD511-tp3
└────┬───┘└──────┬──────┘ └─┬─┘ └───────┬───────┘
  schéma     hôte:port    base       options
```

```bash
mongosh "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp3"
```

L'invite `BD511>` indique la base courante. mongosh a complété l'URI avec ses options par défaut :

```javascript
db
db.getMongo()
```

Résultat attendu :

```text
BD511
mongodb://127.0.0.1:27017/BD511?appName=BD511-tp3&directConnection=true&serverSelectionTimeoutMS=2000
```

```bash
exit
```

L'option `appName` est précieuse en exploitation : le nom de l'application apparaît dans le journal du serveur et dans les opérations en cours. Dans un **second terminal** (`Ctrl` + `Maj` + `T`), retrouvez votre connexion dans le journal JSON de `mongod` :


```bash
sudo jq -c 'select(.msg == "client metadata" and .attr.doc.application.name == "BD511-tp3")
  | {date: .t["$date"], client: .attr.remote, app: .attr.doc.application.name, driver: .attr.doc.driver.name}' \
  /var/log/mongodb/mongod.log | tail -n 1
```

Résultat attendu (date et port client variables) :

```text
{"date":"2026-10-22T16:32:18.660+02:00","client":"127.0.0.1:51584","app":"BD511-tp3","driver":"nodejs|mongosh"}
```

### 2.2 Naviguer et utiliser l'aide intégrée

```bash
mongosh "mongodb://127.0.0.1:27017/BD511?appName=BD511-tp3"
```

```javascript
show dbs
show collections
use admin
show collections
use BD511
```

Résultat attendu (tailles variables) :

```text
admin    40.00 KiB
BD511    32.00 KiB
config  108.00 KiB
local    72.00 KiB
formations
inscriptions
stagiaires
stagiaires_brut
switched to db admin
system.version
switched to db BD511
```

L'aide est contextuelle. Tapez successivement les commandes suivantes et parcourez les listes affichées :

| Commande | Affiche |
| --- | --- |
| `help` | les commandes du shell (`use`, `show`, `exit`…) |
| `db.help()` | les méthodes de la base courante (`createCollection`, `stats`, `dropDatabase`…) |
| `db.inscriptions.help()` | les méthodes d'une collection (`find`, `insertOne`, `updateMany`…) |
| `db.inscriptions.find().help()` | les méthodes d'un curseur (`sort`, `limit`, `batchSize`…) |

La touche `Tab` complète les noms de collections et de méthodes ; les flèches haut/bas parcourent l'historique.

### 2.3 Commandes d'administration courantes

```javascript
db.version()
db.inscriptions.countDocuments()
db.inscriptions.estimatedDocumentCount()
db.inscriptions.dataSize()
db.currentOp({ appName: "BD511-tp3" }).inprog.map(op => ({ opid: op.opid, op: op.op, client: op.client, appName: op.appName }))
```

Résultat attendu (`opid` et port client variables, la liste peut contenir une ou deux opérations) :

```text
8.3.13
1202
1202
374181
[
  {
    opid: 87051,
    op: 'command',
    client: '127.0.0.1:51566',
    appName: 'BD511-tp3'
  }
]
```

- `countDocuments()` compte les documents qui correspondent à un filtre (il lit les données) ; `estimatedDocumentCount()` lit les métadonnées de la collection : instantané, mais sans filtre possible.
- `dataSize()` donne la taille des documents (non compressés) en octets.
- `db.currentOp()` liste les opérations en cours ; filtrée par `appName`, elle montre ici la vôtre. Ce diagnostic est approfondi au chapitre 8.

### 2.4 L'environnement JavaScript

mongosh est un interpréteur JavaScript complet : variables, boucles et fonctions permettent d'automatiser des tâches d'administration.

```javascript
const noms = db.getCollectionNames().sort()
for (const nom of noms) { print(nom.padEnd(16), db.getCollection(nom).countDocuments()) }
function compterPar(collection, champ) { return db.getCollection(collection).aggregate([{ $group: { _id: "$" + champ, n: { $sum: 1 } } }, { $sort: { _id: 1 } }]).toArray() }
compterPar("formations", "domaine")
compterPar("inscriptions", "statut")
```

Résultat attendu :

```text
formations       24
inscriptions     1202
stagiaires       300
stagiaires_brut  300

[Function: compterPar]
[
  { _id: 'Bases de données', n: 7 },
  { _id: 'Big Data', n: 6 },
  { _id: 'DevOps', n: 4 },
  { _id: 'Intelligence artificielle', n: 3 },
  { _id: 'Programmation', n: 2 },
  { _id: 'Systèmes', n: 2 }
]
[
  { _id: 'annulée', n: 129 },
  { _id: 'confirmée', n: 168 },
  { _id: 'en attente', n: 52 },
  { _id: 'terminée', n: 853 }
]
```

### 2.5 Créer des documents : `insertOne` et `insertMany`

Les bases et les collections sont créées **implicitement**, à la première écriture. Travaillez dans une base de test :

```javascript
use bac_a_sable
show collections
db.essais.insertOne({ nom: "premier essai", cree_le: new Date(), tags: ["test", "mongosh"] })
show collections
db.essais.insertMany([{ _id: 1, nom: "un" }, { _id: 2, nom: "deux" }, { _id: 3, nom: "trois" }])
```

Résultat attendu :

```text
switched to db bac_a_sable

{
  acknowledged: true,
  insertedId: ObjectId('6ada1e73a28eb64c114c8c3b')
}
essais
{ acknowledged: true, insertedIds: { '0': 1, '1': 2, '2': 3 } }
```

- `show collections` n'affiche rien avant la première insertion : la base `bac_a_sable` et la collection `essais` n'existent qu'à partir de là.
- Sans `_id` fourni, le client génère un `ObjectId` (valeur différente sur votre VM) ; sinon, la valeur fournie est utilisée et doit être unique.

Un `insertMany` est **ordonné** par défaut : il s'arrête à la première erreur. Avec `{ ordered: false }`, il poursuit et rapporte toutes les erreurs.

```javascript
db.essais.insertMany([{ _id: 4, nom: "quatre" }, { _id: 2, nom: "doublon" }, { _id: 5, nom: "cinq" }])
db.essais.find({ _id: { $type: "number" } }).sort({ _id: 1 })
db.essais.insertMany([{ _id: 5, nom: "cinq" }, { _id: 2, nom: "doublon" }, { _id: 6, nom: "six" }], { ordered: false })
db.essais.countDocuments()
```

Résultat attendu (extraits) :

```text
Uncaught:
MongoBulkWriteError: E11000 duplicate key error collection: bac_a_sable.essais index: _id_ dup key: { _id: 2 }
Result: BulkWriteResult {
  insertedCount: 1,
  …
  insertedIds: { '0': 4 }
}
…
[
  { _id: 1, nom: 'un' },
  { _id: 2, nom: 'deux' },
  { _id: 3, nom: 'trois' },
  { _id: 4, nom: 'quatre' }
]
Uncaught:
MongoBulkWriteError: E11000 duplicate key error collection: bac_a_sable.essais index: _id_ dup key: { _id: 2 }
Result: BulkWriteResult {
  insertedCount: 2,
  …
  insertedIds: { '0': 5, '2': 6 }
}
…
7
```

Le premier lot s'est arrêté au doublon (`5` n'a pas été inséré) ; le second, non ordonné, a inséré `5` et `6` malgré l'erreur. Supprimez la base de test et revenez sur `BD511` :

```javascript
db.dropDatabase()
use BD511
```

Résultat attendu :

```text
{ ok: 1, dropped: 'bac_a_sable' }
switched to db BD511
```

### 2.6 Lire des documents : `find`, opérateurs, projection, tri

`find(filtre, projection)` renvoie un curseur ; `findOne` renvoie le premier document. La projection choisit les champs renvoyés (`_id` est inclus sauf si `_id: 0`).

> **Bonne pratique.** Sans `sort`, l'ordre des résultats n'est pas garanti : il peut varier d'une exécution à l'autre. Les requêtes de ce TP trient donc toujours les listes affichées.

```javascript
db.formations.findOne({ _id: "BD511" }, { titre: 1, duree_jours: 1, prix_ht: 1 })
db.formations.find({ prix_ht: { $gte: 2400 } }, { titre: 1, prix_ht: 1 }).sort({ prix_ht: -1, _id: 1 })
db.formations.find({ domaine: { $in: ["DevOps", "Systèmes"] }, duree_jours: { $lte: 3 } }, { duree_jours: 1 }).sort({ _id: 1 })
```

Résultat attendu :

```text
{
  _id: 'BD511',
  titre: 'NoSQL MongoDB : mise en œuvre et administration',
  duree_jours: 3,
  prix_ht: Decimal128('2190.00')
}
[
  {
    _id: 'DO302',
    titre: 'Kubernetes : déploiement et exploitation',
    prix_ht: Decimal128('2690.00')
  },
  {
    _id: 'IA103',
    titre: 'Machine learning avec Python',
    prix_ht: Decimal128('2690.00')
  },
  {
    _id: 'BD520',
    titre: 'PostgreSQL : administration',
    prix_ht: Decimal128('2590.00')
  },
  {
    _id: 'IA102',
    titre: "IA agentique : conception d'applications multi-agents avec des LLM",
    prix_ht: Decimal128('2490.00')
  },
  {
    _id: 'SY401',
    titre: 'Administration Linux : les fondamentaux',
    prix_ht: Decimal128('2490.00')
  }
]
[
  { _id: 'DO301', duree_jours: 2 },
  { _id: 'DO303', duree_jours: 3 },
  { _id: 'DO304', duree_jours: 2 },
  { _id: 'SY402', duree_jours: 3 }
]
```

Plusieurs critères séparés par des virgules forment un **ET** implicite. Les opérateurs `$or`, `$nin`, `$exists`, les plages de dates et les expressions régulières complètent les critères :

```javascript
db.inscriptions.countDocuments({ formation_id: "BD511", statut: "terminée" })
db.inscriptions.countDocuments({ $or: [{ financement: "CPF" }, { remise_pct: { $gte: 15 } }] })
db.inscriptions.countDocuments({ statut: { $nin: ["annulée", "en attente"] } })
db.inscriptions.countDocuments({ remise_pct: { $exists: true } })
db.inscriptions.countDocuments({ "session.debut": { $gte: ISODate("2026-01-01"), $lt: ISODate("2027-01-01") } })
db.inscriptions.distinct("financement")
db.formations.find({ titre: /^Apache/ }, { titre: 1 }).sort({ _id: 1 })
```

Résultat attendu :

```text
41
177
1021
202
556
[ 'CPF', 'OPCO', 'entreprise', 'personnel' ]
[
  {
    _id: 'BD513',
    titre: 'Apache Cassandra : architecture et exploitation'
  },
  { _id: 'BG602', titre: 'Apache Spark avancé' },
  { _id: 'BG603', titre: "Apache Kafka : streaming d'événements" },
  { _id: 'BG604', titre: 'Apache NiFi : conception de flux de données' },
  { _id: 'BG605', titre: 'Apache Airflow : orchestration de pipelines' },
  { _id: 'BG606', titre: 'Apache Hive : entrepôt de données sur Hadoop' }
]
```

`limit` et `skip` paginent un résultat trié. Affichez les pages 1 et 2 (4 documents par page) des stagiaires ayant terminé la formation BD511, de la session la plus récente à la plus ancienne :

```javascript
db.inscriptions.find({ formation_id: "BD511", statut: "terminée" }, { _id: 0, stagiaire_id: 1, "session.debut": 1 }).sort({ "session.debut": -1, stagiaire_id: 1 }).limit(4)
db.inscriptions.find({ formation_id: "BD511", statut: "terminée" }, { _id: 0, stagiaire_id: 1, "session.debut": 1 }).sort({ "session.debut": -1, stagiaire_id: 1 }).skip(4).limit(4)
```

Résultat attendu :

```text
[
  {
    stagiaire_id: 'STG0047',
    session: { debut: ISODate('2026-06-08T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0107',
    session: { debut: ISODate('2026-06-08T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0109',
    session: { debut: ISODate('2026-06-08T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0112',
    session: { debut: ISODate('2026-06-08T09:00:00.000Z') }
  }
]
[
  {
    stagiaire_id: 'STG0168',
    session: { debut: ISODate('2026-06-08T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0075',
    session: { debut: ISODate('2025-11-24T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0137',
    session: { debut: ISODate('2025-11-24T09:00:00.000Z') }
  },
  {
    stagiaire_id: 'STG0228',
    session: { debut: ISODate('2025-11-24T09:00:00.000Z') }
  }
]
```

Le second critère de tri (`stagiaire_id`) départage les ex aequo : sans lui, deux pages successives pourraient se recouvrir. Les dates sont stockées et affichées en **UTC** (`Z`).

### 2.7 Documents imbriqués et tableaux

La **notation pointée** (`"session.ville"`) interroge un champ imbriqué. Comparer un document imbriqué entier exige en revanche les mêmes champs, dans le même ordre :

```javascript
db.stagiaires.countDocuments({ "adresse.ville": "Lyon" })
db.inscriptions.countDocuments({ "session.ville": "À distance", statut: "confirmée" })
db.inscriptions.countDocuments({ session: { ville: "Lyon", modalite: "présentiel" } })
db.inscriptions.countDocuments({ "session.ville": "Lyon", "session.modalite": "présentiel" })
```

Résultat attendu :

```text
15
53
0
199
```

La troisième requête ne trouve rien : le sous-document `session` contient aussi le champ `debut`, il n'est donc jamais égal à `{ ville, modalite }`. Préférez la notation pointée.

Sur un tableau, un critère simple est vrai si **au moins un élément** le vérifie. `$size` teste la longueur, `$all` exige plusieurs valeurs :

```javascript
db.formations.find({ modalites: "intra-entreprise" }, { modalites: 1 }).sort({ _id: 1 })
db.formations.countDocuments({ modalites: { $size: 1 } })
db.formations.find({ tags: "python" }, { tags: 1 }).sort({ _id: 1 })
db.formations.find({ tags: { $all: ["python", "orchestration"] } }, { titre: 1 })
db.inscriptions.countDocuments({ presences: false })
```

Résultat attendu :

```text
[
  {
    _id: 'BD520',
    modalites: [ 'présentiel', 'classe virtuelle', 'intra-entreprise' ]
  },
  { _id: 'IA101', modalites: [ 'classe virtuelle', 'intra-entreprise' ] }
]
8
[
  { _id: 'BG605', tags: [ 'airflow', 'orchestration', 'dag', 'python' ] },
  {
    _id: 'IA103',
    tags: [ 'machine learning', 'scikit-learn', 'python' ]
  },
  { _id: 'PY201', tags: [ 'python', 'programmation' ] },
  { _id: 'PY202', tags: [ 'python', 'pandas', 'visualisation' ] }
]
[
  { _id: 'BG605', titre: 'Apache Airflow : orchestration de pipelines' }
]
88
```

La dernière requête compte les inscriptions comportant au moins **un jour d'absence** : une valeur `false` dans le tableau `presences`.

Pour un tableau de **documents**, `$elemMatch` impose que tous les critères portent sur **le même élément**. Recherchez les formations ayant une session à Paris avec au moins 10 inscrits :

```javascript
db.formations.find({ "sessions.ville": "Paris", "sessions.inscrits": { $gte: 10 } }, { _id: 1 }).sort({ _id: 1 }).toArray().map(f => f._id)
db.formations.find({ sessions: { $elemMatch: { ville: "Paris", inscrits: { $gte: 10 } } } }, { _id: 1 }).sort({ _id: 1 }).toArray().map(f => f._id)
db.formations.findOne({ _id: "IA103" }, { _id: 0, sessions: 1 })
```

Résultat attendu :

```text
[ 'BD512', 'BD516', 'BD520', 'BG603', 'IA103', 'SY401' ]
[ 'BD512', 'BD516', 'BD520', 'BG603', 'SY401' ]
{
  sessions: [
    {
      debut: ISODate('2026-11-23T09:00:00.000Z'),
      ville: 'Lyon',
      places: 10,
      inscrits: 10
    },
    {
      debut: ISODate('2027-02-01T09:00:00.000Z'),
      ville: 'Paris',
      places: 12,
      inscrits: 3
    }
  ]
}
```

IA103 est un faux positif de la première requête : la session de **Paris** a 3 inscrits, c'est celle de **Lyon** qui en a 10. Seul `$elemMatch` répond correctement à la question.

### 2.8 Requêtes sur les types BSON

Le schéma flexible de MongoDB autorise des types différents pour un même champ. C'est le cas de `evaluation.note`, dont une partie a été migrée d'un ancien outil sous forme de texte. L'opérateur `$type` filtre sur le type (`"int"`, `"double"`, `"string"`, `"date"`, `"bool"`, `"null"`, `"object"`, `"array"`, ou l'alias `"number"` pour tous les types numériques) :

```javascript
db.inscriptions.countDocuments({ "evaluation.note": { $type: "int" } })
db.inscriptions.countDocuments({ "evaluation.note": { $type: "double" } })
db.inscriptions.countDocuments({ "evaluation.note": { $type: "string" } })
db.inscriptions.countDocuments({ "evaluation.note": { $type: "number" } })
db.inscriptions.aggregate([{ $match: { evaluation: { $type: "object" } } }, { $group: { _id: { $type: "$evaluation.note" }, n: { $sum: 1 } } }, { $sort: { _id: 1 } }])
```

Résultat attendu :

```text
511
71
110
582
[
  { _id: 'double', n: 71 },
  { _id: 'int', n: 511 },
  { _id: 'string', n: 110 }
]
```

Conséquence directe : les comparaisons ne mélangent pas les types. Une requête numérique ignore les notes en texte, et une comparaison de chaînes ignore les nombres :

```javascript
db.inscriptions.countDocuments({ "evaluation.note": { $gte: 4 } })
db.inscriptions.countDocuments({ "evaluation.note": { $gte: "4" } })
```

Résultat attendu :

```text
408
86
```

Les 86 notes « 4 » et « 5 » saisies en texte manquent au premier comptage : vous les convertirez en partie 2.10.

**`null` ou champ absent ?** Un critère `champ: null` trouve les documents où le champ vaut `null` **et** ceux où il est absent. Pour les distinguer, utilisez `$type: "null"` ou `$exists` :

```javascript
db.inscriptions.countDocuments({ statut: "terminée", evaluation: null })
db.inscriptions.countDocuments({ statut: "terminée", evaluation: { $type: "null" } })
db.inscriptions.countDocuments({ statut: "terminée", evaluation: { $exists: false } })
```

Résultat attendu :

```text
161
90
71
```

90 questionnaires ont été envoyés sans réponse (`null`), 71 n'ont jamais été envoyés (champ absent) : 161 au total.

**Les erreurs de type de l'import CSV.** Comparez la collection importée sans typage et la collection typée :

```javascript
db.stagiaires_brut.findOne({ _id: "STG0002" }, { _id: 0, adresse: 1, telephone: 1, actif: 1, inscrit_le: 1 })
db.stagiaires.findOne({ _id: "STG0002" }, { _id: 0, adresse: 1, telephone: 1, actif: 1, inscrit_le: 1 })
db.stagiaires_brut.countDocuments({ "adresse.code_postal": "06000" })
db.stagiaires.countDocuments({ "adresse.code_postal": "06000" })
db.stagiaires_brut.countDocuments({ inscrit_le: { $gte: ISODate("2026-01-01") } })
db.stagiaires.countDocuments({ inscrit_le: { $gte: ISODate("2026-01-01") } })
db.stagiaires_brut.aggregate([{ $group: { _id: { $type: "$telephone" }, n: { $sum: 1 } } }, { $sort: { _id: 1 } }])
```

Résultat attendu :

```text
{
  adresse: { ville: 'Bourg-en-Bresse', code_postal: 1000 },
  telephone: '06 12 31 62 33',
  actif: 'true',
  inscrit_le: '2025-03-24'
}
{
  adresse: { ville: 'Bourg-en-Bresse', code_postal: '01000' },
  telephone: '06 12 31 62 33',
  actif: true,
  inscrit_le: ISODate('2025-03-24T00:00:00.000Z')
}
0
18
0
38
[ { _id: 'int', n: 37 }, { _id: 'string', n: 263 } ]
```

Dans `stagiaires_brut`, aucun des 18 stagiaires niçois (`06000`) n'est retrouvé, aucune date ne répond à une requête de date, et 37 numéros de téléphone ont perdu leur zéro initial.

**Nombres de types différents.** Les opérateurs de comparaison comparent en revanche tous les types numériques entre eux : un `Decimal128` se compare à un entier. Et chaque `ObjectId` embarque sa date de création :

```javascript
db.inscriptions.countDocuments({ prix_ht: { $lt: 1500 } })
db.inscriptions.countDocuments({ prix_ht: { $lt: NumberDecimal("1500") } })
const ins = db.inscriptions.findOne({ stagiaire_id: "STG0002" }, { date_inscription: 1 })
ins
ins._id.getTimestamp()
```

Résultat attendu :

```text
237
237

{
  _id: ObjectId('67e17370b5110c3000000059'),
  date_inscription: ISODate('2025-03-24T15:00:00.000Z')
}
ISODate('2025-03-24T15:00:00.000Z')
```

### 2.9 Les curseurs

`find()` ne renvoie pas les documents mais un **curseur** côté serveur, lu par **lots** (*batches*) : le premier lot contient 101 documents, les suivants sont demandés au fil de la lecture (commande `getMore`). Dans mongosh, l'affichage s'arrête après 20 documents (réglage `displayBatchSize`) et `it` affiche la suite :

```javascript
db.inscriptions.find({ statut: "terminée" }, { _id: 0, stagiaire_id: 1, formation_id: 1 }).sort({ _id: 1 })
it
```

Résultat attendu (deux pages de 20 documents, extraits) :

```text
[
  { stagiaire_id: 'STG0186', formation_id: 'PY202' },
  { stagiaire_id: 'STG0123', formation_id: 'PY202' },
  { stagiaire_id: 'STG0137', formation_id: 'BG601' },
  …
  { stagiaire_id: 'STG0049', formation_id: 'BG601' }
]
Type "it" for more
[
  { stagiaire_id: 'STG0072', formation_id: 'PY202' },
  { stagiaire_id: 'STG0268', formation_id: 'BG601' },
  …
  { stagiaire_id: 'STG0245', formation_id: 'PY202' }
]
Type "it" for more
```

Manipulez maintenant un curseur explicitement :

```javascript
const curseur = db.inscriptions.find({ statut: "terminée" }).sort({ _id: 1 })
curseur.hasNext()
curseur.next().stagiaire_id
curseur.objsLeftInBatch()
curseur.itcount()
curseur.hasNext()
const c2 = db.inscriptions.find({ statut: "terminée" }).sort({ _id: 1 }).batchSize(50)
c2.next().stagiaire_id
c2.objsLeftInBatch()
```

Résultat attendu :

```text

true
STG0186
100
852
false

STG0186
49
```

- Après le premier `next()`, il reste 100 documents dans le premier lot de 101.
- `itcount()` parcourt la **suite** du curseur : 852 documents (853 « terminée » moins celui déjà lu). Le curseur est alors épuisé.
- `batchSize(50)` réduit la taille des lots : il reste 49 documents dans le lot.

Les méthodes `map`, `toArray` et `forEach` parcourent tout le curseur :

```javascript
db.inscriptions.find({ formation_id: "BD515" }, { _id: 0, stagiaire_id: 1 }).sort({ stagiaire_id: 1 }).limit(3).map(i => i.stagiaire_id)
db.inscriptions.find({ formation_id: "BD515" }).toArray().length
let absences = 0
db.inscriptions.find({ presences: false }).forEach(i => { absences += i.presences.filter(p => !p).length })
absences
```

Résultat attendu :

```text
[ 'STG0011', 'STG0032', 'STG0052' ]
30


88
```

> **En production.** `toArray()` charge tout le résultat en mémoire côté client : à réserver aux petits résultats. Préférez un parcours (`forEach`, boucle) ou, mieux, faites calculer le serveur avec une agrégation (partie 2.12).

Côté serveur, un curseur inactif est fermé au bout de 10 minutes (paramètre `cursorTimeoutMillis`) ; `maxTimeMS()` borne la durée d'exécution d'une requête, une protection utile contre les requêtes trop longues :

```javascript
db.adminCommand({ getParameter: 1, cursorTimeoutMillis: 1 })
db.serverStatus().metrics.cursor.open.total
db.inscriptions.find({ statut: "terminée" }).maxTimeMS(2000).itcount()
```

Résultat attendu (le nombre de curseurs ouverts varie) :

```text
{ cursorTimeoutMillis: Long('600000'), ok: 1 }
Long('2')
853
```

### 2.10 Mettre à jour des documents

Les méthodes `updateOne` et `updateMany` prennent un **filtre** et des **opérateurs de mise à jour**. Le résultat indique combien de documents ont été trouvés (`matchedCount`) et réellement modifiés (`modifiedCount`).

**`$set`, `$inc`, `$currentDate`** : la stagiaire STG0002 déménage à Lyon, change de numéro, et son expérience augmente d'un an.

```javascript
db.stagiaires.updateOne({ _id: "STG0002" }, { $set: { telephone: "06 99 88 77 66", "adresse.ville": "Lyon", "adresse.code_postal": "69003" }, $inc: { annees_experience: 1 }, $currentDate: { maj_le: true } })
db.stagiaires.findOne({ _id: "STG0002" }, { _id: 0, telephone: 1, adresse: 1, annees_experience: 1, maj_le: 1 })
```

Résultat attendu (date `maj_le` variable) :

```text
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
{
  adresse: { ville: 'Lyon', code_postal: '69003' },
  telephone: '06 99 88 77 66',
  annees_experience: 9,
  maj_le: ISODate('2026-10-22T14:32:20.488Z')
}
```

**`$push` et `$addToSet`** sur un tableau : `$push` ajoute toujours (ici plusieurs valeurs avec `$each`), `$addToSet` n'ajoute que si la valeur est absente.

```javascript
db.formations.updateOne({ _id: "BD511" }, { $push: { tags: { $each: ["mongodb 8.3", "compass", "mongosh"] } } })
db.formations.updateOne({ _id: "BD511" }, { $addToSet: { tags: "compass" } })
db.formations.findOne({ _id: "BD511" }, { _id: 0, tags: 1 })
```

Résultat attendu :

```text
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 0,
  upsertedCount: 0
}
{
  tags: [
    'mongodb',
    'nosql',
    'administration',
    'replica set',
    'sharding',
    'mongodb 8.3',
    'compass',
    'mongosh'
  ]
}
```

**`$unset` et `updateMany`** : nettoyez les téléphones vides de la collection brute. En production, **comptez toujours** les documents visés avant un `updateMany` ou un `deleteMany` :

```javascript
db.stagiaires_brut.countDocuments({ telephone: "" })
db.stagiaires_brut.updateMany({ telephone: "" }, { $unset: { telephone: "" } })
db.stagiaires_brut.countDocuments({ telephone: { $exists: false } })
```

Résultat attendu :

```text
52
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 52,
  modifiedCount: 52,
  upsertedCount: 0
}
52
```

**Write concern explicite** : marquez pour relance les inscriptions en attente, en exigeant l'acquittement de la majorité dans un délai de 5 secondes.

```javascript
db.inscriptions.countDocuments({ statut: "en attente" })
db.inscriptions.updateMany({ statut: "en attente" }, { $set: { relance: true }, $currentDate: { relance_le: true } }, { writeConcern: { w: "majority", wtimeout: 5000 } })
```

Résultat attendu :

```text
52
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 52,
  modifiedCount: 52,
  upsertedCount: 0
}
```

**Mise à jour par pipeline** : un tableau d'étapes d'agrégation à la place des opérateurs permet de calculer la nouvelle valeur à partir de l'ancienne. Convertissez les notes saisies en texte en entiers :

```javascript
db.inscriptions.updateMany({ "evaluation.note": { $type: "string" } }, [{ $set: { "evaluation.note": { $toInt: "$evaluation.note" } } }])
db.inscriptions.countDocuments({ "evaluation.note": { $type: "string" } })
db.inscriptions.countDocuments({ "evaluation.note": { $gte: 4 } })
```

Résultat attendu :

```text
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 110,
  modifiedCount: 110,
  upsertedCount: 0
}
0
494
```

Les 86 bonnes notes saisies en texte sont maintenant comptées : 408 + 86 = 494.

**`upsert`** : mettre à jour le document s'il existe, le créer sinon. `$setOnInsert` ne s'applique qu'à la création. Exécutée deux fois, l'opération ne crée pas de doublon : elle est **idempotente**, une propriété précieuse pour les traitements rejoués après incident.

```javascript
const nouvelle = { $set: { nom: "Moreau", prenom: "Inès", email: "ines.moreau@acme-data.example", entreprise: "Acme Data", actif: true }, $setOnInsert: { inscrit_le: new Date(), annees_experience: 4 } }
db.stagiaires.updateOne({ _id: "STG0301" }, nouvelle, { upsert: true })
db.stagiaires.updateOne({ _id: "STG0301" }, nouvelle, { upsert: true })
db.stagiaires.findOne({ _id: "STG0301" })
```

Résultat attendu (date `inscrit_le` variable) :

```text

{
  acknowledged: true,
  insertedId: 'STG0301',
  matchedCount: 0,
  modifiedCount: 0,
  upsertedCount: 1
}
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 0,
  upsertedCount: 0
}
{
  _id: 'STG0301',
  actif: true,
  annees_experience: 4,
  email: 'ines.moreau@acme-data.example',
  entreprise: 'Acme Data',
  inscrit_le: ISODate('2026-10-22T14:32:20.675Z'),
  nom: 'Moreau',
  prenom: 'Inès'
}
```

**`replaceOne`** remplace tout le document, à l'exception de `_id` : les champs non fournis disparaissent.

```javascript
db.stagiaires.replaceOne({ _id: "STG0301" }, { nom: "Moreau", prenom: "Inès", email: "ines.moreau@acme-data.example" })
db.stagiaires.findOne({ _id: "STG0301" })
```

Résultat attendu :

```text
{
  acknowledged: true,
  insertedId: null,
  matchedCount: 1,
  modifiedCount: 1,
  upsertedCount: 0
}
{
  _id: 'STG0301',
  nom: 'Moreau',
  prenom: 'Inès',
  email: 'ines.moreau@acme-data.example'
}
```

### 2.11 Supprimer des documents

Supprimez la stagiaire de test, puis purgez les inscriptions annulées de plus de deux ans, après les avoir comptées. Enfin, supprimez la collection brute, devenue inutile :

```javascript
db.stagiaires.deleteOne({ _id: "STG0301" })
db.inscriptions.countDocuments({ statut: "annulée", "session.debut": { $lt: ISODate("2025-01-01") } })
db.inscriptions.deleteMany({ statut: "annulée", "session.debut": { $lt: ISODate("2025-01-01") } })
db.inscriptions.countDocuments()
db.stagiaires_brut.drop()
show collections
```

Résultat attendu :

```text
{ acknowledged: true, deletedCount: 1 }
48
{ acknowledged: true, deletedCount: 48 }
1154
true
formations
inscriptions
stagiaires
```

> `deleteMany({})` supprime tous les documents mais conserve la collection et ses index ; `drop()` supprime la collection entière, index compris, et rend l'espace disque immédiatement.

### 2.12 Aperçu du framework d'agrégation

Un pipeline d'agrégation est une suite d'**étapes** ; chacune transforme le flux de documents produit par la précédente. Le calcul est fait par le serveur, sans transférer les documents au client.

Nombre d'inscriptions par statut (`$group`, `$sort`) :

```javascript
db.inscriptions.aggregate([
  { $group: { _id: "$statut", inscriptions: { $sum: 1 } } },
  { $sort: { inscriptions: -1 } }
])
```

Résultat attendu :

```text
[
  { _id: 'terminée', inscriptions: 853 },
  { _id: 'confirmée', inscriptions: 168 },
  { _id: 'annulée', inscriptions: 81 },
  { _id: 'en attente', inscriptions: 52 }
]
```

Chiffre d'affaires HT des formations réalisées, par année (`$match`, expression `$year`, somme de `Decimal128`) :

```javascript
db.inscriptions.aggregate([
  { $match: { statut: "terminée" } },
  { $group: { _id: { $year: "$session.debut" }, ca_ht: { $sum: "$prix_ht" }, stagiaires: { $sum: 1 } } },
  { $sort: { _id: 1 } }
])
```

Résultat attendu :

```text
[
  { _id: 2024, ca_ht: Decimal128('530352.00'), stagiaires: 271 },
  { _id: 2025, ca_ht: Decimal128('483219.50'), stagiaires: 255 },
  { _id: 2026, ca_ht: Decimal128('639715.00'), stagiaires: 327 }
]
```

Les 5 formations au plus fort chiffre d'affaires (réalisé ou confirmé), avec leur titre lu dans la collection `formations` par une jointure `$lookup`, et une mise en forme par `$project` :

```javascript
db.inscriptions.aggregate([
  { $match: { statut: { $in: ["terminée", "confirmée"] } } },
  { $group: { _id: "$formation_id", ca_ht: { $sum: "$prix_ht" }, inscriptions: { $sum: 1 } } },
  { $sort: { ca_ht: -1 } },
  { $limit: 5 },
  { $lookup: { from: "formations", localField: "_id", foreignField: "_id", as: "formation" } },
  { $project: { _id: 0, code: "$_id", titre: { $first: "$formation.titre" }, inscriptions: "$inscriptions", ca_ht: "$ca_ht" } }
])
```

Résultat attendu :

```text
[
  {
    code: 'BG603',
    titre: "Apache Kafka : streaming d'événements",
    inscriptions: 55,
    ca_ht: Decimal128('119464.50')
  },
  {
    code: 'IA103',
    titre: 'Machine learning avec Python',
    inscriptions: 45,
    ca_ht: Decimal128('118360.00')
  },
  {
    code: 'BG601',
    titre: 'Hadoop et HDFS : les fondamentaux',
    inscriptions: 60,
    ca_ht: Decimal128('117310.50')
  },
  {
    code: 'BD512',
    titre: 'MongoDB pour les développeurs',
    inscriptions: 59,
    ca_ht: Decimal128('115619.00')
  },
  {
    code: 'BD520',
    titre: 'PostgreSQL : administration',
    inscriptions: 45,
    ca_ht: Decimal128('113183.00')
  }
]
```

`$lookup` est placé **après** `$limit` : la jointure n'est faite que pour 5 documents au lieu de plus d'un millier. L'ordre des étapes est la première optimisation d'un pipeline.

Quittez mongosh :

```javascript
exit
```

---

## Partie 3 – Les mêmes manipulations dans Compass

### 3.1 Repartir du jeu de données initial et se connecter

Remettez la base dans son état initial : vous pourrez ainsi comparer chaque résultat de Compass avec celui obtenu dans mongosh en partie 2.

```bash
bash ~/BD511/ch03/importer.sh
```

Résultat attendu :

```text
formations      : 24 documents
inscriptions    : 1202 documents
stagiaires      : 300 documents
stagiaires_brut : 300 documents
```

Lancez Compass (menu des applications ▸ **MongoDB Compass**, ou `nohup mongodb-compass > /dev/null 2>&1 &` dans un terminal). Dans la section **CONNECTIONS** du volet de gauche, cliquez sur la connexion **BD511 - local** enregistrée au chapitre 2.

> Si la connexion n'existe plus, recréez-la : **Add new connection**, champ **URI** `mongodb://127.0.0.1:27017/?directConnection=true`. Compass remplit alors automatiquement le champ **Name** avec `127.0.0.1:27017` : remplacez ce nom par `BD511 - local`, puis cliquez sur **Save & Connect**.

Dépliez la base **BD511** et cliquez sur la collection **inscriptions** : elle s'ouvre dans un onglet, avec les onglets **Documents**, **Aggregations**, **Schema**, **Indexes** et **Validation**. Chaque collection ouverte depuis le volet de gauche ajoute un onglet en haut de la fenêtre.

### 3.2 Interroger les collections

La barre de requête de l'onglet **Documents** accepte la même syntaxe que mongosh (clés sans guillemets, `ISODate(...)`, `NumberDecimal(...)`). Cliquez sur **Options** pour afficher les champs **Project**, **Sort**, **Collation**, **Index Hint**, **Max Time MS**, **Skip** et **Limit**, puis sur **Find** pour exécuter la requête (**Reset** l'efface). Le nombre de résultats s'affiche au-dessus des documents (`1 – 25 of 41`, par exemple).

Reproduisez les requêtes suivantes et vérifiez que vous retrouvez les résultats de la partie 2 :

| # | Collection | Filtre (barre de requête) | Options | Résultat attendu |
| --- | --- | --- | --- | --- |
| 1 | `formations` | `{ prix_ht: { $gte: 2400 } }` | Project `{ titre: 1, prix_ht: 1 }` · Sort `{ prix_ht: -1, _id: 1 }` | 5 documents, de DO302 à SY401 (2.6) |
| 2 | `inscriptions` | `{ formation_id: "BD511", statut: "terminée" }` | – | 41 documents |
| 3 | `inscriptions` | `{ $or: [{ financement: "CPF" }, { remise_pct: { $gte: 15 } }] }` | – | 177 documents |
| 4 | `inscriptions` | `{ "session.debut": { $gte: ISODate("2026-01-01"), $lt: ISODate("2027-01-01") } }` | – | 556 documents |
| 5 | `inscriptions` | `{ "session.ville": "À distance", statut: "confirmée" }` | – | 53 documents |
| 6 | `formations` | `{ sessions: { $elemMatch: { ville: "Paris", inscrits: { $gte: 10 } } } }` | Project `{ _id: 1 }` | 5 documents (sans IA103) |
| 7 | `inscriptions` | `{ "evaluation.note": { $type: "string" } }` | – | 110 documents |
| 8 | `inscriptions` | `{ statut: "terminée", evaluation: { $exists: false } }` | – | 71 documents |
| 9 | `inscriptions` | `{ formation_id: "BD511", statut: "terminée" }` | Project `{ _id: 0, stagiaire_id: 1, "session.debut": 1 }` · Sort `{ "session.debut": -1, stagiaire_id: 1 }` · Skip `4` · Limit `4` | STG0168, STG0075, STG0137, STG0228 (2.6, page 2) |

Quelques repères :

- Les icônes à droite de la barre d'outils basculent l'affichage des résultats en **liste**, en **JSON** (`{}`) ou en **tableau**.
- L'icône d'horloge, à gauche de la barre de requête, ouvre la fenêtre **Queries in BD511.inscriptions** : l'onglet **Recents** rappelle les dernières requêtes, l'onglet **Favorites** celles que vous avez enregistrées.
- Le champ **Max Time MS** vaut 60000 par défaut : Compass interrompt côté serveur toute requête de plus de 60 secondes, la même protection que `maxTimeMS()` en partie 2.9.

**Les curseurs dans Compass.** Compass affiche les documents par pages de 25 (liste déroulante à gauche du compteur : 25, 50, 75 ou 100). Les flèches **<** et **>** passent d'une page à l'autre : Compass relance alors la requête avec `skip` et `limit`, comme vous l'avez fait en partie 2.6. Avec le filtre de la requête 2, observez le compteur `1 – 25 of 41`, puis `26 – 41 of 41` sur la page suivante.

### 3.3 Visualiser les types avec l'onglet Schema

L'onglet **Schema** échantillonne la collection et affiche, pour chaque champ, ses types et la répartition de ses valeurs.

1. Ouvrez la collection **stagiaires_brut**, onglet **Schema**, puis cliquez sur **Analyze schema**. Le message `This report is based on a sample of 300 documents.` confirme que toute la collection a été lue.
2. Repérez les types détectés : `actif` est de type **string**, `inscrit_le` aussi ; dépliez `adresse` : `code_postal` est un **int32** ; `telephone` mélange **string** et **int32** (deux segments dans la barre de type).
3. Faites la même analyse sur **stagiaires** : `actif` est un **boolean**, `inscrit_le` une **date**, `adresse.code_postal` une **string**, et `telephone` une **string**, absente des documents dont la cellule était vide (option `--ignoreBlanks`).
4. Sur **inscriptions**, dépliez `evaluation` : `note` mélange **string**, **int32** et **double**, ce que vous avez mesuré avec `$type` en partie 2.8.

### 3.4 Modifier des documents

**Modifier un document.** Ouvrez **stagiaires**, filtrez sur `{ _id: "STG0002" }`, survolez le document et cliquez sur l'icône crayon (**Edit document**). Chaque champ devient modifiable et son type s'affiche à droite (`String`, `Object`, `Boolean`, `Date`, `Int32`) ; un clic sur le type ouvre la liste des types BSON. Remplacez la valeur de `telephone` par `06 99 88 77 66` et celle de `annees_experience` par `9` : la mention `Document modified.` apparaît. Cliquez sur **UPDATE**.

**Insérer un document.** Cliquez sur **ADD DATA** ▸ **Insert document**. La fenêtre **Insert Document** accepte la syntaxe de mongosh : sélectionnez son contenu (`Ctrl` + `A`), remplacez-le par le document ci-dessous, puis cliquez sur **Insert**. Le compteur de l'onglet **Documents** passe à 301.

```javascript
{ _id: "STG0301", nom: "Moreau", prenom: "Inès", email: "ines.moreau@acme-data.example", entreprise: "Acme Data", actif: true, inscrit_le: ISODate("2026-10-22T00:00:00Z"), annees_experience: 4 }
```

**Supprimer un document.** Filtrez sur `{ _id: "STG0301" }`, survolez le document et cliquez sur l'icône corbeille : la mention `Document flagged for deletion.` apparaît. Cliquez sur **DELETE**. Le compteur revient à 300.

**Mettre à jour en masse.** Ouvrez **inscriptions**, filtrez sur `{ statut: "en attente" }`, cliquez sur **Find**, puis sur **BULK** ▸ **Bulk update documents**. La fenêtre **Update 52 documents** reprend le filtre ; sélectionnez le contenu du champ **Update** (`Ctrl` + `A`) et remplacez-le par :

```javascript
{ $set: { relance: true } }
```

Cliquez sur **Update 52 documents** : le message `52 documents have been updated.` s'affiche.

Le même écran accepte une **mise à jour par pipeline**. Filtrez sur `{ "evaluation.note": { $type: "string" } }`, cliquez sur **Find** (110 documents), puis **BULK** ▸ **Bulk update documents**, et saisissez :

```javascript
[ { $set: { "evaluation.note": { $toInt: "$evaluation.note" } } } ]
```

Cliquez sur **Update 110 documents**, puis sur **Find** : la requête ne renvoie plus aucun document.

**Supprimer en masse.** Filtrez sur `{ statut: "annulée", "session.debut": { $lt: ISODate("2025-01-01") } }`, cliquez sur **Find** (48 documents), puis **BULK** ▸ **Bulk delete documents**. La fenêtre **Delete 48 documents** montre un aperçu de 5 documents ; cliquez sur **Delete 48 documents**, puis confirmez dans la fenêtre **Are you absolutely sure?** en cliquant de nouveau sur **Delete 48 documents**. Cliquez sur **Reset** puis **Find** : le compteur indique `1 – 25 of 1154`.

> **Prudence.** Comme en ligne de commande, vérifiez toujours le nombre de documents visés (affiché dans le titre des fenêtres **Update** et **Delete**) avant de valider une opération en masse : elle s'applique à **tous** les documents du filtre, pas seulement à ceux affichés.

### 3.5 Construire un premier pipeline d'agrégation

Vous allez calculer la **note moyenne et le nombre d'évaluations par domaine de formation**. Ce calcul combine les deux collections : la note est dans `inscriptions`, le domaine dans `formations`.

Dans la collection **inscriptions**, ouvrez l'onglet **Aggregations**. Vérifiez que le mode **STAGES** est sélectionné et que **PREVIEW** est activé. Pour chaque étape du tableau ci-dessous :

1. cliquez sur **Add stage** ;
2. dans la liste **Select** de la nouvelle étape, tapez le nom de l'opérateur (par exemple `$match`) puis **cliquez** sur l'opérateur proposé (la liste affiche aussi sa description) ;
3. sélectionnez tout le contenu de l'éditeur de l'étape (`Ctrl` + `A`) et remplacez-le par le contenu indiqué ;
4. observez l'aperçu à droite (`Output preview after $match stage (Sample of 10 documents)`) : il montre les documents produits par l'étape.

| Étape | Opérateur | Contenu de l'étape | Effet |
| --- | --- | --- | --- |
| 1 | `$match` | `{ "evaluation.note": { $type: "number" } }` | ne garde que les inscriptions notées |
| 2 | `$lookup` | `{ from: "formations", localField: "formation_id", foreignField: "_id", as: "formation" }` | ajoute un tableau `formation` contenant la formation suivie |
| 3 | `$group` | `{ _id: { $first: "$formation.domaine" }, note_moyenne: { $avg: "$evaluation.note" }, evaluations: { $sum: 1 } }` | un document par domaine |
| 4 | `$project` | `{ _id: 0, domaine: "$_id", note_moyenne: { $round: ["$note_moyenne", 2] }, evaluations: "$evaluations" }` | renomme et arrondit |
| 5 | `$sort` | `{ note_moyenne: -1 }` | meilleure note en premier |

Cliquez sur **Run** (en haut à droite). Compass exécute le pipeline complet et affiche `Showing 1 – 6` :

| domaine | note_moyenne | evaluations |
| --- | --- | --- |
| Intelligence artificielle | 4.14 | 82 |
| Systèmes | 4.02 | 65 |
| DevOps | 3.99 | 104 |
| Big Data | 3.96 | 181 |
| Bases de données | 3.89 | 188 |
| Programmation | 3.88 | 72 |

Le total des évaluations (692) inclut les 110 notes converties en 3.4. Avant cette conversion, l'étape 1 n'en retenait que 582.

**Pour réfléchir.** Cliquez sur **Edit** pour revenir au constructeur, puis désactivez l'étape 1 avec son interrupteur (à droite de la liste **Select**) et relancez **Run**. Les notes moyennes ne changent pas, mais le nombre d'« évaluations » augmente : `$avg` ignore les documents sans note, alors que `$sum: 1` compte tous les documents. Réactivez l'étape 1.

**Enregistrer le pipeline.** Cliquez sur **SAVE** ▸ **Save**, nommez-le `Note moyenne par domaine` et cliquez sur **Save**. Le pipeline apparaît dans **My Queries** (volet de gauche), d'où il peut être rouvert à tout moment.

**Le basculer en texte.** Cliquez sur **TEXT** : le pipeline complet s'affiche sous forme d'un tableau JSON modifiable, avec l'aperçu du résultat à droite. Revenez en mode **STAGES**.

**L'exporter en Python.** Cliquez sur **EXPORT CODE**. Dans la fenêtre **Export Pipeline To Language**, choisissez **Python** dans la liste de droite (**Exported Pipeline**) et cochez **Include Import Statements** et **Include Driver Syntax** : Compass génère le code PyMongo complet. Vous retrouverez ce pipeline dans le script de la partie 4.6. Cliquez sur **Close**.

### 3.6 Utiliser le shell intégré

Cliquez sur **Open MongoDB shell** (en haut à droite de l'onglet de la collection) : un onglet `mongosh: BD511 - local` s'ouvre, déjà positionné sur la base `BD511`. La ligne de saisie est préremplie avec `db["inscriptions"].find()` : effacez-la, puis exécutez :

```javascript
db.inscriptions.countDocuments()
db.inscriptions.countDocuments({ relance: true })
db.stagiaires.findOne({ _id: "STG0002" }, { _id: 0, telephone: 1, annees_experience: 1 })
```

Résultat attendu :

```text
1154
52
{ telephone: '06 99 88 77 66', annees_experience: 9 }
```

Les modifications faites dans l'interface graphique sont bien visibles en ligne de commande : Compass et mongosh ne sont que deux clients du même serveur.

---

## Partie 4 – Manipuler les documents en Python avec PyMongo

### 4.1 Repartir du jeu de données initial

```bash
bash ~/BD511/ch03/importer.sh
```

### 4.2 Créer l'environnement Python

Ubuntu 24.04 interdit d'installer des paquets Python dans le Python du système (`pip install` y échoue avec l'erreur `externally-managed-environment`) : on crée un **environnement virtuel** propre au projet, et on fige les versions des dépendances dans un fichier `requirements.txt` pour que l'installation soit reproductible sur tous les postes.

```bash
cd ~/BD511/ch03/python
python3 -m venv .venv
cat > requirements.txt <<'EOF'
# Versions figées : installation reproductible (même résultat sur tous les postes)
pymongo==4.19.0
dnspython==2.9.0
EOF
source .venv/bin/activate
python -m pip install --upgrade pip
pip install -r requirements.txt
pip --version
pip freeze
```

Résultat attendu (fin de la sortie ; l'invite du terminal est préfixée par `(.venv)`) :

```text
Successfully installed dnspython-2.9.0 pymongo-4.19.0
pip 26.2.2 from /home/<votre-compte>/BD511/ch03/python/.venv/lib/python3.12/site-packages/pip (python 3.12)
dnspython==2.9.0
pymongo==4.19.0
```

### 4.3 Paramétrer la connexion

La chaîne de connexion n'est jamais écrite dans le code : elle est lue dans la variable d'environnement `MONGODB_URI`. Le même programme peut ainsi viser la VM du TP, un serveur de recette ou la production, sans modification ; au chapitre 5, il suffira d'y ajouter des identifiants. Le fichier `BD511.env` définit cette variable, et la dernière commande la fait charger automatiquement à chaque activation de l'environnement virtuel :

```bash
cat > BD511.env <<'EOF'
# BD511.env - paramètres de connexion des scripts Python (à charger avec : source BD511.env)
#   appName           nom de l'application, visible dans le journal de mongod et dans currentOp
#   directConnection  connexion directe à une instance autonome (pas de découverte de replica set)
#   timeoutMS         délai maximal de chaque opération, recherche du serveur comprise (10 s)
#   w=majority        écriture confirmée par la majorité des membres (valeur sûre, explicite)
export MONGODB_URI="mongodb://127.0.0.1:27017/?appName=BD511-python&directConnection=true&timeoutMS=10000&w=majority"
EOF
echo 'source "$HOME/BD511/ch03/python/BD511.env"' >> .venv/bin/activate
deactivate
source .venv/bin/activate
echo "$MONGODB_URI"
```

Résultat attendu :

```text
mongodb://127.0.0.1:27017/?appName=BD511-python&directConnection=true&timeoutMS=10000&w=majority
```

Le module `connexion.py` crée le client. Il s'arrête avec un message explicite si la variable est absente, au lieu de se connecter avec une valeur par défaut :

```bash
cat > connexion.py <<'EOF'
"""connexion.py - BD511 ch.3 : création du client MongoDB partagé par les scripts du TP."""
import os
import sys

from pymongo import MongoClient


def get_client() -> MongoClient:
    """Crée le client à partir de MONGODB_URI (un seul client par processus : il gère son pool de connexions)."""
    uri = os.environ.get("MONGODB_URI")
    if not uri:
        sys.exit("MONGODB_URI n'est pas définie : exécutez « source ~/BD511/ch03/python/BD511.env ».")
    # tz_aware=True : les dates lues sont des datetime avec fuseau (UTC), jamais des dates « naïves »
    return MongoClient(uri, tz_aware=True)
EOF
```

Les bonnes pratiques de production appliquées par ce paramétrage :

| Pratique | Mise en œuvre |
| --- | --- |
| Un seul `MongoClient` par processus | le client gère lui-même un **pool** de connexions (100 au plus par défaut) ; en créer un par requête multiplie les connexions et dégrade les performances du serveur |
| Configuration hors du code | URI dans `MONGODB_URI`, arrêt immédiat si elle manque |
| Application identifiable | `appName=BD511-python`, visible dans le journal et dans `currentOp` |
| Délais bornés | `timeoutMS=10000` : aucune opération, recherche du serveur comprise, ne bloque plus de 10 s |
| Écritures durables | `w=majority` explicite |
| Dates sans ambiguïté | `tz_aware=True` : les dates lues sont en UTC avec fuseau ; on écrit des `datetime` en UTC |
| Montants exacts | `Decimal128` en base, `decimal.Decimal` en Python, jamais de `float` pour de l'argent |
| Libération des ressources | `with get_client() as client:` ferme le client et ses connexions en fin de bloc |
| Écritures réessayées | `retryWrites` et `retryReads` sont actifs par défaut : une écriture interrompue par une bascule de primaire est rejouée automatiquement (chapitre 6) |

### 4.4 Tester la connexion

```bash
cat > p1_connexion.py <<'EOF'
"""p1_connexion.py - BD511 ch.3 : test de connexion avec PyMongo."""
import sys

import pymongo
from pymongo.errors import PyMongoError

from connexion import get_client

with get_client() as client:
    try:
        client.admin.command("ping")
    except PyMongoError as erreur:
        sys.exit(f"Serveur injoignable : {erreur}")

    options = client.options
    print("PyMongo                :", pymongo.__version__)
    print("Serveur MongoDB        :", client.server_info()["version"])
    print("Bases                  :", ", ".join(client.list_database_names()))
    print("Pool de connexions max :", options.pool_options.max_pool_size)
    print("Délai des opérations   :", options.timeout, "s")
    print("Write concern          :", client.write_concern.document)

    db = client["BD511"]
    for nom in sorted(db.list_collection_names()):
        print(f"BD511.{nom:<16}: {db[nom].count_documents({})} documents")
EOF
python p1_connexion.py
```

Résultat attendu :

```text
PyMongo                : 4.19.0
Serveur MongoDB        : 8.3.13
Bases                  : admin, BD511, config, local
Pool de connexions max : 100
Délai des opérations   : 10.0 s
Write concern          : {'w': 'majority'}
BD511.formations      : 24 documents
BD511.inscriptions    : 1202 documents
BD511.stagiaires      : 300 documents
BD511.stagiaires_brut : 300 documents
```

### 4.5 Créer et manipuler des documents (CRUD)

Le script suivant enregistre une nouvelle stagiaire et ses inscriptions, les lit, les modifie, puis les supprime. Il commence par effacer les données d'une exécution précédente : il peut être relancé autant de fois que nécessaire.

```bash
cat > p2_crud.py <<'EOF'
"""p2_crud.py - BD511 ch.3 : création et manipulation de documents avec PyMongo."""
from datetime import datetime, timezone

from pymongo import DeleteOne, ReturnDocument, UpdateOne
from pymongo.errors import DuplicateKeyError

from connexion import get_client

STAGIAIRE = "STG0301"
FORMATIONS = ["BD511", "BD512", "DO301"]


def titre(texte):
    print(f"\n== {texte}")


with get_client() as client:
    db = client["BD511"]
    stagiaires, inscriptions = db["stagiaires"], db["inscriptions"]

    # Le script peut être relancé : on supprime d'abord les données d'une exécution précédente.
    inscriptions.delete_many({"stagiaire_id": STAGIAIRE})
    stagiaires.delete_many({"_id": {"$in": [STAGIAIRE, "STG0302"]}})

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
    resultat = stagiaires.insert_one(nouvelle)
    print("Stagiaire créée :", resultat.inserted_id)
    try:
        stagiaires.insert_one(nouvelle)
    except DuplicateKeyError as erreur:
        print("Deuxième insertion refusée : code", erreur.code, "- clé", erreur.details["keyValue"])

    titre("2. Création de plusieurs documents : insert_many")
    catalogue = {f["_id"]: f for f in db["formations"].find({"_id": {"$in": FORMATIONS}}, {"prix_ht": 1, "sessions": 1})}
    nouvelles = []
    for code in FORMATIONS:
        session = catalogue[code]["sessions"][0]          # première session à venir de la formation
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
    resultat = inscriptions.insert_many(nouvelles, ordered=False)
    print(len(resultat.inserted_ids), "inscriptions créées ; _id générés par le driver :",
          {type(i).__name__ for i in resultat.inserted_ids})

    titre("3. Lecture : find_one, find et curseur")
    s = stagiaires.find_one({"_id": STAGIAIRE}, {"_id": 0, "prenom": 1, "nom": 1, "inscrit_le": 1})
    print(f"{s['prenom']} {s['nom']}, inscrite le {s['inscrit_le']:%d/%m/%Y à %H:%M %Z}")
    curseur = (inscriptions.find({"stagiaire_id": STAGIAIRE}, {"formation_id": 1, "session": 1, "prix_ht": 1})
               .sort("session.debut", 1))
    for i in curseur:                                      # le curseur est itéré par lots, à la demande
        print(f"  {i['formation_id']}  {i['session']['debut']:%d/%m/%Y}  {i['session']['ville']:<12}"
              f"{i['prix_ht'].to_decimal():>9} € HT")
    print("Inscriptions de la stagiaire :", inscriptions.count_documents({"stagiaire_id": STAGIAIRE}))
    print("Formations à 2400 € HT ou plus :", [f["_id"] for f in
          db["formations"].find({"prix_ht": {"$gte": 2400}}, {"_id": 1}).sort([("prix_ht", -1), ("_id", 1)])])

    titre("4. Mises à jour")
    r = stagiaires.update_one({"_id": STAGIAIRE},
                              {"$set": {"telephone": "06 11 22 33 44"}, "$inc": {"annees_experience": 1},
                               "$currentDate": {"maj_le": True}})
    print("update_one  :", r.matched_count, "trouvé,", r.modified_count, "modifié")
    r = inscriptions.update_many({"stagiaire_id": STAGIAIRE, "statut": "en attente"}, {"$set": {"statut": "confirmée"}})
    print("update_many :", r.modified_count, "inscriptions confirmées")
    apres = stagiaires.find_one_and_update(
        {"_id": STAGIAIRE},
        {"$push": {"competences": {"$each": ["mongosh", "Compass", "PyMongo"]}}},
        projection={"_id": 0, "competences": 1, "annees_experience": 1},
        return_document=ReturnDocument.AFTER)
    print("find_one_and_update :", apres)
    for _ in range(2):                                     # un upsert rejoué ne crée pas de doublon
        r = stagiaires.update_one({"_id": "STG0302"},
                                  {"$set": {"nom": "Fabre", "prenom": "Hugo", "entreprise": "Datavolt"},
                                   "$setOnInsert": {"inscrit_le": datetime(2026, 10, 22, tzinfo=timezone.utc)}},
                                  upsert=True)
        print("upsert      : upserted_id =", r.upserted_id, "| trouvé :", r.matched_count)
    r = stagiaires.replace_one({"_id": "STG0302"}, {"nom": "Fabre", "prenom": "Hugo"})
    print("replace_one :", r.modified_count, "remplacé ->", stagiaires.find_one({"_id": "STG0302"}))

    titre("5. Écritures groupées : bulk_write")
    r = inscriptions.bulk_write([
        UpdateOne({"stagiaire_id": STAGIAIRE, "formation_id": "BD511"}, {"$set": {"financement": "OPCO"}}),
        UpdateOne({"stagiaire_id": STAGIAIRE, "formation_id": "BD512"}, {"$set": {"remise_pct": 10}}),
        DeleteOne({"stagiaire_id": STAGIAIRE, "formation_id": "DO301"}),
    ], ordered=False)
    print("bulk_write  :", r.modified_count, "modifiés,", r.deleted_count, "supprimé (un seul aller-retour réseau)")

    titre("6. Suppressions")
    r = inscriptions.delete_many({"stagiaire_id": STAGIAIRE})
    print("delete_many :", r.deleted_count, "inscriptions supprimées")
    r = stagiaires.delete_many({"_id": {"$in": [STAGIAIRE, "STG0302"]}})
    print("delete_many :", r.deleted_count, "stagiaires supprimés")
    print("Contrôle    :", stagiaires.count_documents({}), "stagiaires,", inscriptions.count_documents({}), "inscriptions")
EOF
python p2_crud.py
```

Résultat attendu :

```text

== 1. Création d'un document : insert_one
Stagiaire créée : STG0301
Deuxième insertion refusée : code 11000 - clé {'_id': 'STG0301'}

== 2. Création de plusieurs documents : insert_many
3 inscriptions créées ; _id générés par le driver : {'ObjectId'}

== 3. Lecture : find_one, find et curseur
Inès Moreau, inscrite le 22/10/2026 à 00:00 UTC
  DO301  12/11/2026  Paris         1390.00 € HT
  BD511  16/11/2026  Paris         2190.00 € HT
  BD512  23/11/2026  Paris         1990.00 € HT
Inscriptions de la stagiaire : 3
Formations à 2400 € HT ou plus : ['DO302', 'IA103', 'BD520', 'IA102', 'SY401']

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
Contrôle    : 300 stagiaires, 1202 inscriptions
```

Correspondance avec mongosh :

| mongosh | PyMongo | Remarque |
| --- | --- | --- |
| `insertOne`, `insertMany` | `insert_one`, `insert_many` | le driver génère les `ObjectId` côté client |
| `findOne`, `find` | `find_one`, `find` | `find` renvoie un curseur, parcouru par une boucle `for` |
| `countDocuments` | `count_documents` | le filtre est obligatoire (`{}` pour tout compter) |
| `sort({ a: 1, b: -1 })` | `sort([("a", 1), ("b", -1)])` | liste de couples : l'ordre des clés est garanti |
| `updateOne`, `updateMany`, `replaceOne` | `update_one`, `update_many`, `replace_one` | résultat : `matched_count`, `modified_count`, `upserted_id` |
| `findOneAndUpdate` | `find_one_and_update` | `ReturnDocument.AFTER` renvoie le document modifié |
| `bulkWrite` | `bulk_write` | plusieurs écritures en un seul aller-retour réseau |
| erreur `E11000` | `DuplicateKeyError` | exception à intercepter dans le code applicatif |

### 4.6 Exécuter un pipeline d'agrégation

Le premier pipeline de ce script est celui construit dans Compass (partie 3.5, **EXPORT CODE** ▸ **Python**). Comme la base a été réimportée en 4.1, le script commence par convertir à nouveau les notes saisies en texte ; relancé, il ne convertit plus rien. Le second pipeline reprend le classement par chiffre d'affaires de la partie 2.12 et convertit les montants `Decimal128` en `decimal.Decimal` pour les mettre en forme.

```bash
cat > p3_agregation.py <<'EOF'
"""p3_agregation.py - BD511 ch.3 : pipelines d'agrégation avec PyMongo."""
from connexion import get_client

with get_client() as client:
    inscriptions = client["BD511"]["inscriptions"]

    # Préalable : notes migrées en texte -> entiers (mise à jour par pipeline, sans effet si déjà faite)
    r = inscriptions.update_many({"evaluation.note": {"$type": "string"}},
                                 [{"$set": {"evaluation.note": {"$toInt": "$evaluation.note"}}}])
    print("Notes converties en entiers :", r.modified_count)

    # Pipeline construit dans Compass (EXPORT CODE > Python)
    pipeline = [
        {"$match": {"evaluation.note": {"$type": "number"}}},
        {"$lookup": {"from": "formations", "localField": "formation_id", "foreignField": "_id", "as": "formation"}},
        {"$group": {"_id": {"$first": "$formation.domaine"}, "note_moyenne": {"$avg": "$evaluation.note"},
                    "evaluations": {"$sum": 1}}},
        {"$project": {"_id": 0, "domaine": "$_id", "note_moyenne": {"$round": ["$note_moyenne", 2]},
                      "evaluations": "$evaluations"}},
        {"$sort": {"note_moyenne": -1}},
    ]
    print(f"\n{'Domaine':<27}{'Note':>6}{'Évaluations':>13}")
    for ligne in inscriptions.aggregate(pipeline):
        print(f"{ligne['domaine']:<27}{ligne['note_moyenne']:>6.2f}{ligne['evaluations']:>13}")

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
    print(f"\n{'Code':<7}{'Titre':<42}{'Inscr.':>7}{'CA HT (€)':>13}")
    for ligne in inscriptions.aggregate(pipeline):
        ca = ligne["ca_ht"].to_decimal()
        print(f"{ligne['code']:<7}{ligne['titre'][:40]:<42}{ligne['inscriptions']:>7}{ca:>13,.2f}".replace(",", " "))
EOF
python p3_agregation.py
```

Résultat attendu :

```text
Notes converties en entiers : 110

Domaine                      Note  Évaluations
Intelligence artificielle    4.14           82
Systèmes                     4.02           65
DevOps                       3.99          104
Big Data                     3.96          181
Bases de données             3.89          188
Programmation                3.88           72

Code   Titre                                      Inscr.    CA HT (€)
BG603  Apache Kafka : streaming d'événements          55   119 464.50
IA103  Machine learning avec Python                   45   118 360.00
BG601  Hadoop et HDFS : les fondamentaux              60   117 310.50
BD512  MongoDB pour les développeurs                  59   115 619.00
BD520  PostgreSQL : administration                    45   113 183.00
```

Les résultats sont identiques à ceux de Compass (3.5) et de mongosh (2.12).

### 4.7 Vérifier côté serveur et tester les protections

Grâce à `appName`, l'administrateur identifie l'application et la version de son driver dans le journal du serveur :

```bash
sudo jq -c 'select(.msg == "client metadata" and .attr.doc.application.name == "BD511-python")
  | {date: .t["$date"], client: .attr.remote, app: .attr.doc.application.name, driver: .attr.doc.driver}' \
  /var/log/mongodb/mongod.log | tail -n 1
```

Résultat attendu (date et port variables) :

```text
{"date":"2026-10-22T16:29:53.700+02:00","client":"127.0.0.1:41064","app":"BD511-python","driver":{"name":"PyMongo|c","version":"4.19.0|"}}
```

Vérifiez enfin le comportement en cas d'erreur de configuration, puis de serveur arrêté :

```bash
env -u MONGODB_URI python p1_connexion.py
sudo systemctl stop mongod
time python p1_connexion.py
sudo systemctl start mongod
```

Résultat attendu (extraits ; `time` affiche la durée avec une virgule ou un point selon la langue du système) :

```text
MONGODB_URI n'est pas définie : exécutez « source ~/BD511/ch03/python/BD511.env ».
Serveur injoignable : 127.0.0.1:27017: [Errno 111] Connection refused (…), Timeout: 9.99…s, …

real	0m10,7…s
```

Sans serveur, le script échoue proprement au bout de 10 secondes (`timeoutMS`), au lieu de rester bloqué. N'oubliez pas la dernière commande, qui redémarre `mongod`. Quittez l'environnement virtuel avec `deactivate`.

---

## Partie 5 – Bilan

### 5.1 Contrôle final

```bash
sudo bash ~/BD511/ch02/check-mongodb.sh | tail -n 1
bash ~/BD511/ch03/importer.sh
```

Résultat attendu :

```text
Bilan : 26 OK, 0 KO
formations      : 24 documents
inscriptions    : 1202 documents
stagiaires      : 300 documents
stagiaires_brut : 300 documents
```

L'instance a conservé ses réglages de production, et la base `BD511` est revenue dans son état initial : elle sert de point de départ au chapitre 4 (modélisation et indexation).

### 5.2 Ce qu'il faut retenir

- **Importer, c'est typer.** Sans description des colonnes, `mongoimport` devine les types d'un CSV et se trompe (codes postaux, téléphones, dates, booléens). En production : `--columnsHaveTypes` avec `--fieldFile`, `--ignoreBlanks`, `--parseGrace stop`, et un contrôle des résultats.
- **Extended JSON** conserve les types BSON ; le CSV les perd ; `mongodump` (chapitre 9) reste l'outil de sauvegarde.
- **`find` renvoie un curseur** lu par lots (101 documents, puis à la demande) ; triez toujours ce que vous paginez, bornez la durée avec `maxTimeMS`, évitez `toArray()` sur de gros volumes.
- **Notation pointée** pour les documents imbriqués, **`$elemMatch`** quand plusieurs critères portent sur le même élément d'un tableau.
- **`$type` et `$exists`** révèlent l'hétérogénéité d'un schéma flexible ; `champ: null` trouve aussi les champs absents.
- **Avant un `updateMany` ou un `deleteMany`**, comptez les documents visés ; préférez les opérations idempotentes (`upsert`, `$addToSet`, `$setOnInsert`) ; une mise à jour par pipeline corrige des données à partir de leur valeur actuelle.
- **Le pipeline d'agrégation** calcule côté serveur ; l'ordre des étapes compte (`$match` tôt, `$lookup` après `$limit`).
- **mongosh, Compass et PyMongo** sont trois clients du même serveur : un pipeline construit dans Compass s'exporte tel quel vers Python.
- **Côté application** : un seul `MongoClient`, configuration hors du code, `appName`, `timeoutMS`, `w=majority`, dépendances figées dans un environnement virtuel.

### 5.3 Récapitulatif des bonnes pratiques de production appliquées

| Domaine | Réglage ou pratique | Partie |
| --- | --- | --- |
| mongosh | `/etc/mongosh.conf` : télémétrie désactivée de force, historique expurgé des données sensibles | 0.3 |
| Import | typage explicite des CSV, `--ignoreBlanks`, `--parseGrace stop`, `--stopOnError`, `w: "majority"` | 1.6, 1.8 |
| Import | contrôle d'intégrité des fichiers (`sha256sum`) avant tout import | 1.1, 1.8 |
| Export | JSON *canonical* pour un échange fidèle entre bases | 1.7 |
| Requêtes | tri systématique, `maxTimeMS`, pas de `toArray()` sur de gros résultats | 2.6, 2.9 |
| Écritures | comptage préalable, `writeConcern` explicite, opérations idempotentes | 2.10, 2.11 |
| Compass | limite `Max Time MS` (60 s), contrôle du nombre de documents avant une opération en masse | 3.2, 3.4 |
| Python | environnement virtuel, versions figées, URI dans l'environnement, client unique, `appName`, `timeoutMS`, `w=majority`, dates UTC, `Decimal128` | 4.2 à 4.4 |
| Exploitation | identification des clients par `appName` dans le journal JSON et `currentOp` | 2.1, 2.3, 4.7 |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `sha256sum` affiche `FAILED` | Script `generer_donnees.py` incomplet ou modifié lors de la copie | Recopiez le bloc de la partie 1.1 en entier, relancez la génération puis le contrôle. |
| `mongoimport` : `Failed: type coercion failure in document #… for column …` | Une valeur du CSV ne correspond pas au type déclaré (`--parseGrace stop`) | Vérifiez `stagiaires.fields` et la ligne indiquée du CSV. |
| `mongoimport` : `E11000 duplicate key error` | Import répété sans `--drop` | Ajoutez `--drop`, ou utilisez `bash ~/BD511/ch03/importer.sh`. |
| `mongosh` : `MongoNetworkError: connect ECONNREFUSED 127.0.0.1:27017` | `mongod` arrêté | `sudo systemctl start mongod`, puis `systemctl status mongod`. |
| Vos nombres diffèrent de ceux du handlab | Base modifiée par une partie précédente, ou commandes exécutées dans un autre ordre | `bash ~/BD511/ch03/importer.sh`, puis reprenez la partie depuis son début. |
| `it` répond `no cursor` | La commande précédente n'était pas un `find`, ou le curseur est épuisé | Relancez le `find`, puis `it`. |
| `python3 -m venv` : `ensurepip is not available` | Paquet `python3-venv` absent | `sudo apt-get install -y python3-venv`, puis `rm -rf .venv` et recréez l'environnement. |
| `pip install` : `externally-managed-environment` | Environnement virtuel non activé | `source ~/BD511/ch03/python/.venv/bin/activate` |
| Python : `MONGODB_URI n'est pas définie` | Environnement non chargé dans ce terminal | `source ~/BD511/ch03/python/.venv/bin/activate` (qui charge `BD511.env`). |
| Python : `ModuleNotFoundError: No module named 'pymongo'` | Script lancé avec le Python du système | Activez l'environnement virtuel ; l'invite doit commencer par `(.venv)`. |
| Python : `ServerSelectionTimeoutError … Connection refused` au bout de 10 s | `mongod` arrêté | `sudo systemctl start mongod` |
| Compass : la connexion **BD511 - local** a disparu | Connexion non enregistrée au chapitre 2 | Recréez-la (partie 3.1) ; remplacez le nom proposé automatiquement. |
| Compass : la mauvaise étape est choisie dans **Select** | Touche `Entrée` pressée avant le filtrage de la liste | Rouvrez la liste, effacez le texte, tapez le nom de l'opérateur et **cliquez** dessus. |
| Compass : l'étape affiche `Stage value is invalid` | Contenu de l'étape incomplet ou accolade manquante | Sélectionnez tout le contenu de l'éditeur (`Ctrl` + `A`) et recollez la valeur du tableau 3.5. |
| Compass : fenêtre noire ou vide | Accélération graphique de la VM | Lancez `mongodb-compass --disable-gpu`. |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `/etc/mongosh.conf` | Configuration globale de mongosh | 0.3 |
| `~/BD511/ch03/00-prerequis.sh` | Contrôle de l'environnement | 0.2 |
| `~/BD511/ch03/generer_donnees.py` | Générateur déterministe du jeu de données | 1.1 |
| `~/BD511/ch03/donnees/formations.json` | 24 formations (tableau Extended JSON) | 1.1 |
| `~/BD511/ch03/donnees/stagiaires.csv` | 300 stagiaires (CSV) | 1.1 |
| `~/BD511/ch03/donnees/stagiaires.fields` | Types des colonnes du CSV | 1.1 |
| `~/BD511/ch03/donnees/inscriptions.json` | 1 202 inscriptions (Extended JSON, une par ligne) | 1.1 |
| `~/BD511/ch03/donnees/SHA256SUMS` | Sommes de contrôle de référence | 1.1 |
| `~/BD511/ch03/donnees/acme-data.csv` | Export CSV d'exemple | 1.7 |
| `~/BD511/ch03/importer.sh` | (Ré)import des quatre collections | 1.8 |
| `~/BD511/ch03/python/requirements.txt` | Dépendances Python figées | 4.2 |
| `~/BD511/ch03/python/.venv/` | Environnement virtuel Python | 4.2 |
| `~/BD511/ch03/python/BD511.env` | Chaîne de connexion (`MONGODB_URI`) | 4.3 |
| `~/BD511/ch03/python/connexion.py` | Création du client MongoDB | 4.3 |
| `~/BD511/ch03/python/p1_connexion.py` | Test de connexion | 4.4 |
| `~/BD511/ch03/python/p2_crud.py` | Opérations CRUD | 4.5 |
| `~/BD511/ch03/python/p3_agregation.py` | Pipelines d'agrégation | 4.6 |

## Annexe C – Références

- mongosh – configuration et fichier global : https://www.mongodb.com/docs/mongodb-shell/reference/configure-shell-settings-global/
- `mongoimport` : https://www.mongodb.com/docs/database-tools/mongoimport/
- `mongoexport` : https://www.mongodb.com/docs/database-tools/mongoexport/
- MongoDB Extended JSON (v2) : https://www.mongodb.com/docs/manual/reference/mongodb-extended-json/
- Opérateurs de requête : https://www.mongodb.com/docs/manual/reference/operator/query/
- Opérateur `$type` et alias de types BSON : https://www.mongodb.com/docs/manual/reference/operator/query/type/
- Curseurs et lots : https://www.mongodb.com/docs/manual/tutorial/iterate-a-cursor/
- Opérateurs de mise à jour : https://www.mongodb.com/docs/manual/reference/operator/update/
- Mises à jour par pipeline : https://www.mongodb.com/docs/manual/tutorial/update-documents-with-aggregation-pipeline/
- Framework d'agrégation : https://www.mongodb.com/docs/manual/aggregation/
- Compass – requêtes, documents et agrégations : https://www.mongodb.com/docs/compass/
- PyMongo : https://www.mongodb.com/docs/languages/python/pymongo-driver/current/
- Délai côté client (`timeoutMS`) : https://www.mongodb.com/docs/manual/core/timeout-mongodb-operations/
