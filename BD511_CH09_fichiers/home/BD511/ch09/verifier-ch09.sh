#!/usr/bin/env bash
# verifier-ch09.sh - BD511 ch.9 : contrôle final du replica set RS9, des sauvegardes et de la restauration
# Usage : bash ~/BD511/ch09/verifier-ch09.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
CH09="$HOME/BD511/ch09"
MONGOSH="$CH09/mongosh-rs9"
SAUV="$HOME/BD511/sauvegardes"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Replica set RS9"
opts=$(findmnt -n -o FSTYPE,OPTIONS /srv/bd511-rs9 2>/dev/null)
[[ $opts == xfs*noatime* ]]; res $? "Données sur un volume XFS monté en noatime : /srv/bd511-rs9"
etats=$("$MONGOSH" --compte admin --quiet --eval '
  print(rs.status().members.map(m => m.name.split(":")[0] + ":" + m.stateStr).join(" "))' 2>/dev/null)
[[ $etats == "rs91:PRIMARY rs92:SECONDARY rs93:SECONDARY" ]]; res $? "Membres : $etats"
reglages=$("$MONGOSH" --compte admin --quiet --eval '
  const p = db.adminCommand({ getCmdLineOpts: 1 }).parsed;
  print(p.replication.oplogSizeMB, p.storage.oplogMinRetentionHours, p.storage.wiredTiger.engineConfig.cacheSizeGB,
        p.security.authorization, Boolean(p.security.keyFile))' 2>/dev/null)
[[ $reglages == "1024 24 0.25 enabled true" ]]; res $? "Réglages (oplog en Mo, rétention en h, cache en Go, contrôle d'accès, keyFile) : $reglages"
# chaque compte se connecte avec son mot de passe et affiche ses propres rôles
comptes=$(for c in admin appli restauration sauvegarde; do
  "$MONGOSH" --compte "$c" --quiet --eval '
    const a = db.runCommand({ connectionStatus: 1 }).authInfo;
    print(a.authenticatedUsers[0].user + ":" + a.authenticatedUserRoles.map(r => r.role).sort().join("+"))' 2>/dev/null
done | paste -sd ' ')
[[ $comptes == "admin:root appli:readWrite restauration:rejeuOplog+restore sauvegarde:backup" ]]; res $? "Comptes : $comptes"

echo "== Sauvegardes"
complete=$(ls -d "$SAUV"/complete-* 2>/dev/null | tail -n 1)
oplog=$(ls -d "$SAUV"/oplog-* 2>/dev/null | tail -n 1)
[[ $(stat -c %a "$SAUV" 2>/dev/null) == 700 ]]; res $? "Répertoire des sauvegardes réservé à son propriétaire (mode 700)"
[[ -n $complete && -s $complete/oplog.bson ]] && (cd "$complete" && sha256sum --quiet -c SHA256SUMS) >/dev/null 2>&1
res $? "Sauvegarde complète intègre, avec son oplog : $(basename "${complete:-aucune}")"
[[ -n $oplog && -s $oplog/local/oplog.rs.bson ]] && (cd "$oplog" && sha256sum --quiet -c SHA256SUMS) >/dev/null 2>&1
res $? "Sauvegarde de l'oplog intègre : $(basename "${oplog:-aucune}")"

echo "== Données restaurées et application"
for cible in rs91 rs92 rs93; do
  r=$("$MONGOSH" --cible "$cible" --quiet "$CH09/coherence.js" 2>/dev/null | grep -o 'COHÉRENT$\|INCOHÉRENT.*')
  [[ $r == COHÉRENT ]]; res $? "bd511 sur $cible : ${r:-injoignable}"
done
etat=$(tail -n 1 "$CH09/boutique.log" 2>/dev/null)
[[ -s $CH09/boutique.pid ]] && kill -0 "$(< "$CH09/boutique.pid")" 2>/dev/null && [[ $etat == *"erreurs 0" ]]
res $? "Application en service : ${etat:-arrêtée}"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
