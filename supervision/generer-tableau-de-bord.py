#!/usr/bin/env python3
"""generer-tableau-de-bord.py - BD511 ch.8 : génère le tableau de bord Grafana « BD511 – Charge MongoDB ».

Le tableau de bord est décrit panneau par panneau (titre, requêtes PromQL, unité), puis écrit au format JSON
de Grafana (modèle classique, schemaVersion 42) dans grafana/dashboards/bd511-mongodb.json.
Grafana le charge au démarrage (provisioning) et le relit toutes les 30 secondes.
Usage : python3 ~/BD511/supervision/generer-tableau-de-bord.py
"""
import json
import pathlib

SOURCE = {"type": "prometheus", "uid": "prometheus"}   # source de données provisionnée (uid fixe)
INTERVALLE = "$__rate_interval"                         # fenêtre des rate() calculée par Grafana
VERT, ORANGE, ROUGE = "green", "orange", "red"
panneaux = []


def requete(expr, legende, ref):
    return {"refId": ref, "datasource": SOURCE, "editorMode": "code", "expr": expr, "legendFormat": legende, "range": True}


def indicateur(titre, description, expr, x, unite, seuils, correspondances=None, decimales=None):
    """Panneau « stat » de la première ligne : une valeur, colorée selon des seuils."""
    defauts = {"unit": unite, "color": {"mode": "thresholds"}, "mappings": correspondances or [],
               "thresholds": {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in seuils]}}
    if decimales is not None:
        defauts["decimals"] = decimales
    panneaux.append({
        "id": len(panneaux) + 1, "type": "stat", "title": titre, "description": description, "datasource": SOURCE,
        "gridPos": {"h": 4, "w": 4, "x": x, "y": 0}, "targets": [requete(expr, "", "A")],
        "fieldConfig": {"defaults": defauts, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "area", "justifyMode": "auto", "orientation": "auto",
                    "textMode": "value", "wideLayout": True, "showPercentChange": False,
                    "percentChangeColorMode": "standard"}})


def courbes(titre, description, requetes, h, w, x, y, unite, logarithmique=False):
    """Panneau « timeseries » : une courbe par série renvoyée par les requêtes."""
    perso = {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10, "showPoints": "never", "spanNulls": False,
             "axisPlacement": "auto", "gradientMode": "none", "lineInterpolation": "linear",
             "stacking": {"mode": "none", "group": "A"}}
    defauts = {"unit": unite, "color": {"mode": "palette-classic"}, "custom": perso}
    if logarithmique:
        perso["scaleDistribution"] = {"type": "log", "log": 10}
    else:
        defauts["min"] = 0
    panneaux.append({
        "id": len(panneaux) + 1, "type": "timeseries", "title": titre, "description": description, "datasource": SOURCE,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [requete(e, l, chr(65 + i)) for i, (e, l) in enumerate(requetes)],
        "fieldConfig": {"defaults": defauts, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True, "calcs": []},
                    "tooltip": {"mode": "multi", "sort": "desc"}}})


CPU_VM = f"100 * (1 - sum(rate(mongodb_sys_cpu_idle_ms[{INTERVALLE}])) / (1000 * max(mongodb_sys_cpu_num_logical_cores)))"
OPERATIONS = 'legacy_op_type=~"query|insert|update|delete|getmore"'

# --- Ligne 1 : indicateurs -----------------------------------------------------------------------------
indicateur("MongoDB", "mongodb_up : 1 si l'exporteur joint mongod", 'mongodb_up{job="mongodb"}', 0, "none",
           [(ROUGE, None), (VERT, 1)],
           correspondances=[{"type": "value", "options": {"0": {"text": "Arrêté", "color": ROUGE, "index": 0},
                                                          "1": {"text": "En service", "color": VERT, "index": 1}}}])
indicateur("Opérations/s", "Lectures, insertions, mises à jour, suppressions et getMore par seconde (hors commandes)",
           f"sum(rate(mongodb_ss_opcounters{{{OPERATIONS}}}[{INTERVALLE}]))", 4, "ops", [(VERT, None)], decimales=1)
indicateur("Examinés par renvoyé", "Documents examinés pour un document renvoyé : proche de 1 quand les index sont adaptés",
           f"sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[{INTERVALLE}]))"
           f' / clamp_min(sum(rate(mongodb_ss_metrics_document{{doc_op_type="returned"}}[{INTERVALLE}])), 1)',
           8, "short", [(VERT, None), (ORANGE, 10), (ROUGE, 1000)], decimales=0)
indicateur("Latence des lectures", "Durée moyenne d'une lecture (opLatencies)",
           f'sum(rate(mongodb_ss_opLatencies_latency{{op_type="reads"}}[{INTERVALLE}]))'
           f' / clamp_min(sum(rate(mongodb_ss_opLatencies_ops{{op_type="reads"}}[{INTERVALLE}])), 1) / 1000',
           12, "ms", [(VERT, None), (ORANGE, 20), (ROUGE, 100)], decimales=1)
indicateur("Connexions", "Connexions clientes ouvertes", 'mongodb_ss_connections{conn_type="current"}', 16, "short",
           [(VERT, None), (ORANGE, 400), (ROUGE, 800)])
indicateur("CPU de la VM", "Temps processeur de la VM hors inactivité (métriques système collectées par mongod)",
           CPU_VM, 20, "percent", [(VERT, None), (ORANGE, 70), (ROUGE, 90)], decimales=0)

# --- Ligne 2 : débit et efficacité des requêtes ------------------------------------------------------
courbes("Opérations par seconde", "Compteurs opcounters, par type d'opération",
        [(f"rate(mongodb_ss_opcounters{{{OPERATIONS}}}[{INTERVALLE}])", "{{legacy_op_type}}")], 8, 12, 0, 4, "ops")
courbes("Documents examinés et renvoyés par seconde",
        "Un écart important signale des requêtes qui parcourent des collections entières (échelle logarithmique)",
        [(f"sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[{INTERVALLE}]))", "documents examinés"),
         (f'sum(rate(mongodb_ss_metrics_document{{doc_op_type="returned"}}[{INTERVALLE}]))', "documents renvoyés"),
         (f"sum(rate(mongodb_ss_metrics_queryExecutor_scanned[{INTERVALLE}]))", "clés d'index examinées")],
        8, 12, 12, 4, "short", logarithmique=True)

# --- Ligne 3 : latence et concurrence -------------------------------------------------------------------
courbes("Latence moyenne par type d'opération", "opLatencies : durée moyenne des lectures, écritures et commandes",
        [(f'rate(mongodb_ss_opLatencies_latency{{op_type=~"reads|writes|commands"}}[{INTERVALLE}])'
          f' / clamp_min(rate(mongodb_ss_opLatencies_ops{{op_type=~"reads|writes|commands"}}[{INTERVALLE}]), 1) / 1000',
          "{{op_type}}")], 8, 12, 0, 12, "ms")
courbes("Opérations en cours", "Opérations actives et en attente (globalLock), tickets de lecture occupés",
        [("mongodb_ss_globalLock_activeClients_readers", "lectures actives"),
         ("mongodb_ss_globalLock_activeClients_writers", "écritures actives"),
         ('sum(mongodb_ss_globalLock_currentQueue{count_type=~"readers|writers"})', "en attente"),
         ("mongodb_ss_wt_concurrentTransactions_read_normalPriority_out", "tickets de lecture occupés")],
        8, 12, 12, 12, "short")

# --- Ligne 4 : collections, index et processeur ---------------------------------------------------------
courbes("Temps serveur par collection",
        "Commande top : secondes passées par seconde sur chaque collection de bd511 (comme mongotop)",
        [(f'rate(mongodb_top_total_time{{database="bd511"}}[{INTERVALLE}]) / 1e6', "{{collection}}")], 8, 8, 0, 20, "s")
courbes("Utilisation des index de bd511.ventes", "$indexStats : accès par seconde à chaque index",
        [(f'rate(mongodb_indexstats_accesses_ops{{database="bd511", collection="ventes"}}[{INTERVALLE}])', "{{key_name}}")],
        8, 8, 8, 20, "ops")
courbes("Processeur", "Temps processeur de la VM hors inactivité, et part consommée par mongod",
        [(CPU_VM, "VM"),
         (f"100 * sum(rate(mongodb_ss_extra_info_user_time_us[{INTERVALLE}]) + rate(mongodb_ss_extra_info_system_time_us[{INTERVALLE}]))"
          " / 1e6 / max(mongodb_sys_cpu_num_logical_cores)", "mongod")], 8, 8, 16, 20, "percent")

# --- Ligne 5 : mémoire -------------------------------------------------------------------------------------
courbes("Cache WiredTiger", "Données présentes dans le cache, dont modifiées (dirty), et taille maximale du cache",
        [("mongodb_ss_wt_cache_bytes_currently_in_the_cache", "utilisé"),
         ("mongodb_ss_wt_cache_tracked_dirty_bytes_in_the_cache", "modifié (dirty)"),
         ("mongodb_ss_wt_cache_maximum_bytes_configured", "maximum")], 8, 12, 0, 28, "bytes")
courbes("Mémoire", "Mémoire résidente de mongod, mémoire utilisée et mémoire totale de la VM",
        [("mongodb_ss_mem_resident * 1024 * 1024", "mongod (résidente)"),
         ("(mongodb_sys_memory_MemTotal_kb - mongodb_sys_memory_MemAvailable_kb) * 1024", "VM (utilisée)"),
         ("mongodb_sys_memory_MemTotal_kb * 1024", "VM (totale)")], 8, 12, 12, 28, "bytes")

tableau = {
    "uid": "bd511-mongodb", "title": "BD511 – Charge MongoDB", "tags": ["BD511", "MongoDB"],
    "description": "Instance mongod du chapitre 2 : métriques de percona/mongodb_exporter collectées par Prometheus",
    "timezone": "browser", "editable": False, "graphTooltip": 1, "refresh": "10s", "schemaVersion": 42,
    "time": {"from": "now-15m", "to": "now"}, "timepicker": {}, "templating": {"list": []},
    "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
                              "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts",
                              "type": "dashboard"}]},
    "links": [], "panels": panneaux, "version": 1, "fiscalYearStartMonth": 0, "liveNow": False, "weekStart": "",
}
fichier = pathlib.Path(__file__).resolve().parent / "grafana" / "dashboards" / "bd511-mongodb.json"
fichier.write_text(json.dumps(tableau, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"{fichier.relative_to(fichier.parents[2])} : {len(panneaux)} panneaux")
