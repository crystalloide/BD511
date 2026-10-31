#!/usr/bin/env bash
# charge.sh - BD511 ch.8 : démarre, arrête ou affiche la charge applicative simulée sur bd511.ventes
#   demarrer [N] : lance N clients (3 par défaut) en arrière-plan, compte « charge », journaux dans ~/BD511/ch08/charge
#   etat         : dernière ligne de bilan de chaque client
#   arreter      : arrête tous les clients
# Usage : bash ~/BD511/ch08/charge.sh demarrer|etat|arreter [N]
set -euo pipefail
CH08="$HOME/BD511/ch08"
DOSSIER="$CH08/charge"
mkdir -p "$DOSSIER"

case ${1:-} in
  demarrer)
    if [[ -s $DOSSIER/pids ]]; then echo "Charge déjà démarrée : bash $0 arreter" >&2; exit 1; fi
    for i in $(seq 1 "${2:-3}"); do
      RYTHME=${RYTHME:-10} DUREE=${DUREE:-3600} nohup "$CH08/mongosh-bd511" --compte charge --quiet "$CH08/client-charge.js" \
        > "$DOSSIER/client$i.log" 2>&1 &
      echo $! >> "$DOSSIER/pids"
    done
    sleep 2
    echo "$(wc -l < "$DOSSIER/pids") clients démarrés (journaux : ~/BD511/ch08/charge/client*.log)" ;;
  etat)
    for f in "$DOSSIER"/client*.log; do [[ -e $f ]] && echo "$(basename "$f" .log) : $(tail -n 1 "$f")"; done ;;
  arreter)
    if [[ -s $DOSSIER/pids ]]; then
      xargs kill < "$DOSSIER/pids" 2>/dev/null || true
      rm -f "$DOSSIER/pids"
      echo "Clients arrêtés"
    else echo "Aucun client en cours"; fi ;;
  *) echo "Usage : $0 demarrer|etat|arreter [N]" >&2; exit 1 ;;
esac
