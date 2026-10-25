#!/usr/bin/env bash
# sauvegarder-oplog.sh - BD511 ch.9 : sauvegarde incrémentale de l'oplog du replica set RS9
# Copie toutes les entrées de l'oplog postérieures à la fin d'une sauvegarde complète (mongodump --oplog) :
# avec elles, on peut restaurer la base à n'importe quel instant postérieur à cette sauvegarde (--oplogLimit).
# Vérifie d'abord que l'oplog contient encore la fin de la sauvegarde complète (sinon, il manquerait des
# opérations), puis écrit dans ~/BD511/sauvegardes/oplog-<date> : l'oplog, sauvegarde.json et SHA256SUMS.
# Usage : bash ~/BD511/ch09/sauvegarder-oplog.sh ~/BD511/sauvegardes/complete-AAAAMMJJ-HHMMSS
set -euo pipefail
COMPLETE=${1:?"Usage : $0 <répertoire d'une sauvegarde complète>"}
COMPLETE=${COMPLETE%/}
URI="mongodb://sauvegarde@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&readPreference=secondary&appName=bd511-ch09-sauvegarde"
depuis=$(jq -c '.finOplog' "$COMPLETE/sauvegarde.json")       # {"$timestamp":{"t":...,"i":...}}

# 1) L'oplog couvre-t-il encore la fin de la sauvegarde complète ?
"$HOME/BD511/ch09/mongosh-rs9" --compte sauvegarde --quiet --eval "
  const depuis = EJSON.parse('$depuis');
  const premiere = db.getSiblingDB('local').oplog.rs.find({}, { ts: 1 }).sort({ \$natural: 1 }).limit(1).next().ts;
  if (premiere.greaterThan(depuis)) { print('Oplog tronqué : il ne contient plus la fin de la sauvegarde complète.'); quit(1); }
  print('Oplog disponible depuis le ' + new Date(premiere.t * 1000).toLocaleString('fr-FR') +
        ' : il couvre la fin de la sauvegarde complète (' + new Date(depuis.t * 1000).toLocaleString('fr-FR') + ')')"

# 2) Copie des entrées postérieures, depuis un secondaire, avec le compte sauvegarde
OPLOG="$HOME/BD511/sauvegardes/oplog-$(date +%Y%m%d-%H%M%S)"
( umask 077
  mongodump --uri "$URI" --config "$HOME/BD511/rs9/secrets/sauvegarde.yaml" --db local --collection oplog.rs \
    --query "{\"ts\": {\"\$gt\": $depuis}}" --out "$OPLOG" --quiet
  bsondump --quiet "$OPLOG/local/oplog.rs.bson" | jq -s -c --arg complete "$(basename "$COMPLETE")" \
    '{sauvegarde: "oplog", depuis: $complete, entrees: length, debutOplog: .[0].ts, finOplog: .[-1].ts}' \
    > "$OPLOG/sauvegarde.json"
  cd "$OPLOG" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
jq -r '"\(.entrees) entrées, du \(.debutOplog["$timestamp"].t | strflocaltime("%d/%m/%Y %H:%M:%S")) au \(.finOplog["$timestamp"].t | strflocaltime("%d/%m/%Y %H:%M:%S"))"' \
  "$OPLOG/sauvegarde.json" | sed "s|^|$(basename "$OPLOG") : |"
