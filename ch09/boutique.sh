#!/usr/bin/env bash
# boutique.sh - BD511 ch.9 : démarre, arrête ou affiche l'application de la boutique (commandes en continu sur RS9)
#   demarrer : lance l'application en arrière-plan, compte appli, journal ~/BD511/ch09/boutique.log
#   etat     : dernière ligne de bilan
#   arreter  : demande l'arrêt propre (fichier boutique.stop) et attend la fin de la transaction en cours
# Usage : bash ~/BD511/ch09/boutique.sh demarrer|etat|arreter
set -euo pipefail
CH09="$HOME/BD511/ch09"
PIDF="$CH09/boutique.pid"

case ${1:-} in
  demarrer)
    if [[ -s $PIDF ]] && kill -0 "$(< "$PIDF")" 2>/dev/null; then echo "Application déjà démarrée" >&2; exit 1; fi
    rm -f "$CH09/boutique.stop"
    RYTHME=${RYTHME:-10} DUREE=${DUREE:-7200} nohup "$CH09/mongosh-rs9" --quiet "$CH09/boutique.js" \
      > "$CH09/boutique.log" 2>&1 &
    echo $! > "$PIDF"
    sleep 2
    echo "Application démarrée (journal : ~/BD511/ch09/boutique.log)" ;;
  etat)
    tail -n 1 "$CH09/boutique.log" ;;
  arreter)
    if [[ -s $PIDF ]] && kill -0 "$(< "$PIDF")" 2>/dev/null; then
      touch "$CH09/boutique.stop"
      for i in $(seq 1 30); do kill -0 "$(< "$PIDF")" 2>/dev/null || break; sleep 0.5; done
      kill "$(< "$PIDF")" 2>/dev/null || true
      rm -f "$PIDF"
      echo "Application arrêtée : $(tail -n 2 "$CH09/boutique.log" | head -n 1)"
    else rm -f "$PIDF"; echo "Application déjà arrêtée"; fi ;;
  *) echo "Usage : $0 demarrer|etat|arreter" >&2; exit 1 ;;
esac
