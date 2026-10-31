#!/usr/bin/env python3
"""generer_ventes.py - BD511 ch.7 : génère le jeu de données des ventes, au format JSON (un document par ligne).

Le générateur est déterministe (graine fixe) : il produit toujours exactement le même fichier,
dont la somme de contrôle figure dans donnees/SHA256SUMS.
Usage : python3 ~/bd511/ch07/generer_ventes.py > ~/bd511/ch07/donnees/ventes.json
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

NB_VENTES = 200_000
NB_CLIENTS = 20_000
PAYS = {"EU": ["FR", "DE", "ES", "IT", "BE", "NL"], "AM": ["US", "CA", "BR", "MX"]}
CANAUX = [("web", 0.55), ("magasin", 0.35), ("telephone", 0.10)]
DEBUT = datetime(2025, 1, 1, tzinfo=timezone.utc)
FIN = datetime(2026, 10, 1, tzinfo=timezone.utc)

alea = random.Random(511)


def tirer(choix):
    """Tire une valeur selon les poids donnés."""
    x, cumul = alea.random(), 0.0
    for valeur, poids in choix:
        cumul += poids
        if x < cumul:
            return valeur
    return choix[-1][0]


# Chaque client a un pays fixe : 60 % en Europe (EU), 40 % dans les Amériques (AM).
clients = []
for i in range(1, NB_CLIENTS + 1):
    region = "EU" if alea.random() < 0.6 else "AM"
    pays = PAYS[region][int(alea.random() * len(PAYS[region]))]
    clients.append((f"C{i:05d}", region, pays))

# Les ventes sont numérotées dans l'ordre chronologique, du 01/01/2025 au 30/09/2026.
pas = (FIN - DEBUT).total_seconds() / NB_VENTES
sortie = sys.stdout
for n in range(1, NB_VENTES + 1):
    date = DEBUT + timedelta(seconds=int((n - 1) * pas + alea.random() * pas))
    client, region, pays = clients[int(alea.random() * NB_CLIENTS)]
    articles = 1 + int(alea.random() ** 2 * 8)
    vente = {
        "_id": n,
        "date": {"$date": date.strftime("%Y-%m-%dT%H:%M:%SZ")},
        "client": client,
        "region": region,
        "pays": pays,
        "canal": tirer(CANAUX),
        "articles": articles,
        "montant": round(articles * (5 + alea.random() * 95), 2),
    }
    sortie.write(json.dumps(vente, separators=(",", ":")) + "\n")
