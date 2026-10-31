#!/usr/bin/env bash
# BD511 – TP chapitre 5 – Étape 0.4 : contrôle et application des réglages système de production
# Cible : Ubuntu 24.04 LTS + MongoDB 8.3 Community installé depuis le dépôt officiel (chapitre 2).
# Idempotent : peut être relancé sans risque.
# Usage : sudo bash ~/tp05-securite/scripts/00_prepa_systeme.sh
set -euo pipefail

if [[ $EUID -ne 0 ]]; then echo "Lancer ce script avec sudo." >&2; exit 1; fi

ERREURS=0
REDEMARRER=0
ok()   { printf '  [OK]    %s\n' "$*"; }
corr() { printf '  [CORR]  %s\n' "$*"; }
info() { printf '  [INFO]  %s\n' "$*"; }
ko()   { printf '  [KO]    %s\n' "$*"; ERREURS=$((ERREURS + 1)); }
version_de() { "$1" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true; }

echo "1. Plate-forme"
# shellcheck source=/dev/null
. /etc/os-release
if [[ ${VERSION_ID:-} == "24.04" ]]; then ok "$PRETTY_NAME"; else info "$PRETTY_NAME (handlab validé sur Ubuntu 24.04)"; fi
if grep -qw avx /proc/cpuinfo; then ok "jeu d'instructions AVX disponible"
else ko "AVX absent : l'activer dans l'hyperviseur (exigé par MongoDB depuis la 5.0)"; fi

echo "2. Binaires MongoDB"
for b in mongod mongosh mongoimport; do
  if command -v "$b" > /dev/null; then ok "$b $(version_de "$b")"
  else ko "$b introuvable : refaire le TP du chapitre 2"; fi
done

echo "3. Noyau Linux et allocateur TCMalloc de MongoDB 8.x (SERVER-121912)"
NOYAU=$(uname -r)
IFS='.-' read -r MAJ MIN PAT _ <<< "$NOYAU"
PAT=${PAT%%[!0-9]*}
VNUM=$(( MAJ * 1000000 + MIN * 1000 + ${PAT:-0} ))
DROPIN=/etc/systemd/system/mongod.service.d/10-noyau-rseq.conf
if (( VNUM >= 6019000 && VNUM <= 7000013 )); then
  info "noyau $NOYAU : MongoDB 8.3 refuse de démarrer avec ses caches TCMalloc par CPU (voir annexe A)"
  if [[ -f $DROPIN ]]; then
    ok "contournement déjà en place : $DROPIN"
  else
    mkdir -p "$(dirname "$DROPIN")"
    cat > "$DROPIN" <<'EOF'
# BD511 – noyau 6.19 à 7.0.13 (dont le noyau HWE 7.0 d'Ubuntu 24.04) : voir annexe A du handlab.
# glibc conserve rseq, TCMalloc passe en caches par thread : mongod peut démarrer.
[Service]
Environment="GLIBC_TUNABLES=glibc.pthread.rseq=1"
EOF
    systemctl daemon-reload
    REDEMARRER=1
    corr "contournement appliqué : $DROPIN"
  fi
else
  ok "noyau $NOYAU compatible avec les caches TCMalloc par CPU"
  if [[ -f $DROPIN ]]; then
    rm -f "$DROPIN"; systemctl daemon-reload; REDEMARRER=1
    corr "contournement retiré (inutile avec ce noyau) : caches par CPU réactivés"
  fi
fi

echo "4. Transparent Huge Pages (recommandation MongoDB 8.x : activées)"
THP=/sys/kernel/mm/transparent_hugepage
UNITE_THP=/etc/systemd/system/enable-transparent-huge-pages.service
etat_thp() { echo "$(cat $THP/enabled)|$(cat $THP/defrag)|$(cat $THP/khugepaged/max_ptes_none)|$(cat /proc/sys/vm/overcommit_memory)"; }
AVANT=$(etat_thp)
cat > "$UNITE_THP" <<'EOF'
[Unit]
Description=Enable Transparent Hugepages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo always | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null && echo defer+madvise | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null && echo 0 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none > /dev/null && echo 1 | tee /proc/sys/vm/overcommit_memory > /dev/null'
RemainAfterExit=true

[Install]
WantedBy=basic.target
EOF
systemctl daemon-reload
systemctl enable --quiet enable-transparent-huge-pages.service
systemctl restart enable-transparent-huge-pages.service
APRES=$(etat_thp)
if [[ $APRES == *"[always]"*"[defer+madvise]"*"|0|1" ]]; then ok "THP enabled=always, defrag=defer+madvise, max_ptes_none=0, overcommit_memory=1"
else ko "valeurs THP inattendues : $APRES"; fi
if [[ $AVANT != "$APRES" ]]; then REDEMARRER=1; corr "réglages THP modifiés (service activé au démarrage)"; fi

echo "5. Paramètres noyau (sysctl)"
SYSCTL=/etc/sysctl.d/90-mongodb.conf
cat > "$SYSCTL" <<'EOF'
# BD511 – paramètres noyau recommandés pour MongoDB (Production Notes)
# Swap uniquement en dernier recours
vm.swappiness = 1
# Au moins 2 x le nombre maximal de connexions entrantes
vm.max_map_count = 1048576
# NUMA : pas de récupération de mémoire par zone
vm.zone_reclaim_mode = 0
# Détection plus rapide des connexions mortes
net.ipv4.tcp_keepalive_time = 120
EOF
sysctl -q -p "$SYSCTL"
ok "swappiness=$(sysctl -n vm.swappiness), max_map_count=$(sysctl -n vm.max_map_count), tcp_keepalive_time=$(sysctl -n net.ipv4.tcp_keepalive_time)"

echo "6. Limites ulimit du service mongod (fixées par l'unité systemd du paquet)"
NOFILE=$(systemctl show mongod -p LimitNOFILE --value)
NPROC=$(systemctl show mongod -p LimitNPROC --value)
if [[ $NOFILE =~ ^[0-9]+$ && $NOFILE -ge 64000 && $NPROC =~ ^[0-9]+$ && $NPROC -ge 64000 ]]; then
  ok "LimitNOFILE=$NOFILE, LimitNPROC=$NPROC"
else ko "LimitNOFILE=$NOFILE, LimitNPROC=$NPROC (64000 minimum attendu)"; fi

echo "7. Synchronisation horaire"
if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == "yes" ]]; then ok "horloge synchronisée (NTP)"
else info "horloge non synchronisée : sans impact pour ce TP, indispensable en production (replica set)"; fi

echo "8. Stockage du dbPath (/var/lib/mongodb)"
FS=$(findmnt -n -o FSTYPE --target /var/lib/mongodb || true)
OPTS=$(findmnt -n -o OPTIONS --target /var/lib/mongodb || true)
if [[ $FS == "xfs" ]]; then ok "système de fichiers XFS"
else info "système de fichiers $FS : MongoDB émettra l'avertissement « XFS strongly recommended » (attendu sur la VM à disque unique)"; fi
if [[ $OPTS == *noatime* ]]; then ok "montage noatime"; else info "montage sans noatime ($OPTS) : en production, monter le volume de données en noatime"; fi

echo "9. Service mongod"
systemctl enable --quiet mongod
if [[ $REDEMARRER -eq 1 ]] || ! systemctl is-active --quiet mongod; then
  if systemctl restart mongod; then corr "mongod (re)démarré"; else ko "échec du démarrage de mongod"; fi
fi
for _ in $(seq 1 60); do
  if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then break; fi
  sleep 1
done
if mongosh --quiet "mongodb://127.0.0.1:27017" --eval 'db.runCommand({ ping: 1 }).ok' > /dev/null 2>&1; then
  ok "mongod $(version_de mongod) répond sur 127.0.0.1:27017"
else
  ko "mongod ne répond pas : voir « sudo journalctl -u mongod -n 30 » et /var/log/mongodb/mongod.log"
fi

echo
if [[ $ERREURS -gt 0 ]]; then echo "BILAN : $ERREURS point(s) bloquant(s) à corriger avant de poursuivre."; exit 1; fi
echo "BILAN : environnement prêt pour le TP."
