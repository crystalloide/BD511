#!/usr/bin/env python3
"""generer_donnees.py - BD511 ch.9 : génère le catalogue et l'historique des commandes de la boutique en ligne.

Deux fichiers JSON (un document par ligne, format Extended JSON de MongoDB) dans le répertoire indiqué :
  articles.json   20 000 articles : stock initial, stock restant, prix ;
  commandes.json 400 000 commandes passées depuis le 01/01/2025 : article, quantité, montant.
Pour chaque article, stockInitial = stock + somme des quantités commandées : c'est l'invariant que la
sauvegarde devra préserver. Le générateur est déterministe (graine fixe) : il produit toujours exactement
les mêmes fichiers, dont les sommes de contrôle figurent dans donnees/SHA256SUMS.
Usage : python3 ~/BD511/ch09/generer_donnees.py ~/BD511/ch09/donnees
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

NB_ARTICLES, NB_COMMANDES, NB_CLIENTS = 20_000, 400_000, 50_000
CATEGORIES = ["livres", "musique", "jeux", "informatique", "maison", "jardin", "sport", "jouets"]
DEBUT = datetime(2025, 1, 1, tzinfo=timezone.utc)
DUREE_S = int((datetime(2026, 10, 1, tzinfo=timezone.utc) - DEBUT).total_seconds())

alea = random.Random(511)
dossier = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
dossier.mkdir(parents=True, exist_ok=True)

prix = [round(alea.uniform(2, 300), 2) for _ in range(NB_ARTICLES)]
commande_par_article = [0] * NB_ARTICLES
instants = sorted(alea.randrange(DUREE_S) for _ in range(NB_COMMANDES))   # commandes numérotées dans l'ordre chronologique

with open(dossier / "commandes.json", "w", encoding="utf-8") as f:
    for numero, instant in enumerate(instants, start=1):
        a = alea.randrange(NB_ARTICLES)
        quantite = alea.choice([1, 1, 1, 1, 2, 2, 3, 4, 5])
        commande_par_article[a] += quantite
        date = (DEBUT + timedelta(seconds=instant)).strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write(json.dumps({"_id": numero, "date": {"$date": date}, "client": f"C{1 + alea.randrange(NB_CLIENTS):05d}",
                            "article": f"ART{a + 1:05d}", "quantite": quantite,
                            "montant": round(quantite * prix[a], 2)}, separators=(",", ":")) + "\n")

with open(dossier / "articles.json", "w", encoding="utf-8") as f:
    for a in range(NB_ARTICLES):
        stock = alea.randrange(200, 2000)                       # stock restant aujourd'hui
        f.write(json.dumps({"_id": f"ART{a + 1:05d}", "libelle": f"Article {a + 1}",
                            "categorie": CATEGORIES[a % len(CATEGORIES)], "prix": prix[a],
                            "stockInitial": stock + commande_par_article[a], "stock": stock},
                           separators=(",", ":")) + "\n")

print(f"{NB_ARTICLES} articles, {NB_COMMANDES} commandes, {sum(commande_par_article)} unités commandées")
