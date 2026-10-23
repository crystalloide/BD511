#!/usr/bin/env python3
# BD511 – TP chapitre 5 – Étape 3.5 : synthèse des authentifications du journal mongod
# Usage : sudo python3 ~/tp05-securite/scripts/tp3_journal_auth.py [--echecs] [nombre_de_lignes]
#   --echecs : n'affiche que les authentifications refusées
# Seules les entrées du composant ACCESS « Successfully authenticated » (id 5286306)
# et « Failed to authenticate » (id 5286307) du journal JSON sont prises en compte.
# [spéculative] : tentative faite dès le « hello » initial du driver ; en cas d'échec, le driver
# recommence de façon explicite, d'où deux lignes pour une même tentative refusée.
import json, sys

JOURNAL = "/var/log/mongodb/mongod.log"
args = sys.argv[1:]
echecs_seuls = "--echecs" in args
nombres = [a for a in args if a.isdigit()]
NB = int(nombres[0]) if nombres else 15

succes, echecs, lignes = 0, 0, []
with open(JOURNAL, encoding="utf-8", errors="replace") as f:
    for brut in f:
        if '"c":"ACCESS"' not in brut:
            continue
        try:
            e = json.loads(brut)
        except ValueError:
            continue
        if e.get("id") not in (5286306, 5286307):
            continue
        reussi = e["id"] == 5286306
        succes, echecs = succes + reussi, echecs + (not reussi)
        if echecs_seuls and reussi:
            continue
        a = e.get("attr", {})
        quand = e["t"]["$date"][:19].replace("T", " ")
        lignes.append(f"{quand}  {'SUCCÈS' if reussi else 'ÉCHEC '}  {(a.get('user') or '—'):<13} "
                      f"db={a.get('db', '?'):<9} {a.get('mechanism', '?'):<14} "
                      f"{a.get('client', '?'):<16} {'[spéculative] ' if a.get('isSpeculative') else ''}"
                      f"{a.get('error', '')}")

print(f"Journal : {succes} authentification(s) réussie(s), {echecs} refusée(s). "
      f"{min(NB, len(lignes))} dernière(s) ligne(s){' (échecs uniquement)' if echecs_seuls else ''} :")
print("\n".join(lignes[-NB:]))
