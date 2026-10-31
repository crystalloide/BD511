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
