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
    db = client["bd511"]
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
