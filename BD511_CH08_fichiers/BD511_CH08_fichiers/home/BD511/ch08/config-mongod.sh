#!/usr/bin/env bash
# config-mongod.sh - BD511 ch.8 : réglages de production du chapitre 8 dans /etc/mongod.conf
#   systemLog.logRotate: reopen   -> la rotation du journal est confiée à logrotate (mongod rouvre son fichier)
#   operationProfiling            -> profiler désactivé, seuil des opérations lentes explicite (100 ms)
# Le fichier d'origine est sauvegardé une fois sous /etc/mongod.conf.avant-ch08. Le script peut être relancé.
# Usage : sudo bash ~/BD511/ch08/config-mongod.sh   (puis sudo systemctl restart mongod)
set -euo pipefail
CONF=/etc/mongod.conf
[[ -f $CONF.avant-ch08 ]] || cp -p "$CONF" "$CONF.avant-ch08"
nouveau=$(mktemp)
trap 'rm -f "$nouveau"' EXIT
cp "$CONF" "$nouveau" && chmod 644 "$nouveau"

# 1) logRotate: reopen, ajouté juste après logAppend dans la section systemLog
if ! grep -qE '^\s+logRotate:' "$nouveau"; then
  grep -qE '^\s+logAppend:\s*true' "$nouveau" || { echo "logAppend: true introuvable dans $CONF" >&2; exit 1; }
  sed -i -E 's/^(\s+)logAppend:\s*true.*$/&\n\1# Rotation par logrotate (\/etc\/logrotate.d\/mongod) : mongod rouvre le fichier sur SIGUSR1.\n\1logRotate: reopen/' "$nouveau"
fi

# 2) section operationProfiling, à la place de la ligne réservée par le chapitre 2 (ou en fin de fichier)
if ! grep -qE '^operationProfiling:' "$nouveau"; then
  bloc='operationProfiling:   # chapitre 8 - profiler et requêtes lentes\n  # Profiler désactivé en production : les opérations lentes sont tout de même écrites dans le journal.\n  mode: "off"\n  # Seuil des opérations lentes (journal, et profiler quand on l'"'"'active) : 100 ms, valeur par défaut rendue explicite.\n  slowOpThresholdMs: 100'
  if grep -qE '^#operationProfiling:' "$nouveau"; then
    sed -i -E "s/^#operationProfiling:.*$/$bloc/" "$nouveau"
  else
    printf '\n%b\n' "$bloc" >> "$nouveau"
  fi
fi

# Contrôle : mongod doit lire le nouveau fichier sans erreur
sudo -u mongodb /usr/bin/mongod --config "$nouveau" --outputConfig > /dev/null
if cmp -s "$CONF" "$nouveau"; then echo "$CONF : déjà à jour"; else
  diff -u "$CONF.avant-ch08" "$nouveau" | tail -n +3 || true
  install -m 644 -o root -g root "$nouveau" "$CONF"
  echo "$CONF mis à jour : redémarrez mongod"
fi
