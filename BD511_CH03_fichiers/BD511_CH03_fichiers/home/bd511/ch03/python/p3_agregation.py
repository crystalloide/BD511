"""p3_agregation.py - BD511 ch.3 : pipelines d'agrégation avec PyMongo."""
from connexion import get_client

with get_client() as client:
    inscriptions = client["bd511"]["inscriptions"]

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
