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
