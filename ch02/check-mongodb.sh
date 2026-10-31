#!/usr/bin/env bash
# check-mongodb.sh - BD511 ch.2 : contrôle de l'installation MongoDB et des réglages de production
# Usage : sudo bash ~/bd511/ch02/check-mongodb.sh
set -u
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

DBPATH=/var/lib/mongodb
URI="mongodb://127.0.0.1:27017/admin?directConnection=true&serverSelectionTimeoutMS=2000"
THP=/sys/kernel/mm/transparent_hugepage
nb_ok=0; nb_ko=0

res() {  # res <code retour du test> <libellé> <valeur constatée>
  local espaces=$(( 47 - ${#2} ))
  (( espaces < 1 )) && espaces=1
  if [[ $1 == 0 ]]; then printf '  \033[32m[OK]\033[0m %s%*s%s\n' "$2" "$espaces" '' "$3"; nb_ok=$((nb_ok + 1))
  else                   printf '  \033[31m[KO]\033[0m %s%*s%s\n' "$2" "$espaces" '' "$3"; nb_ko=$((nb_ko + 1)); fi
}

noyau_compatible() {  # règle de mongod 8.3.x : noyaux 6.19.0 à 7.0.13 refusés
  [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
  local v=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} ))
  (( v < 6019000 || v > 7000013 ))
}

echo "== Noyau et processeur"
val=$(uname -r); noyau_compatible "$val"; res $? "Noyau hors plage 6.19 - 7.0.13" "$val"
if [[ $(uname -m) == x86_64 ]]; then
  grep -qw avx /proc/cpuinfo; rc=$?; res $rc "Jeu d'instructions AVX" "$([[ $rc == 0 ]] && echo présent || echo absent)"
fi

pid=$(systemctl show -p MainPID --value mongod 2>/dev/null)
nofile=64000
[[ ${pid:-0} != 0 && -r /proc/$pid/limits ]] && nofile=$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")

echo "== Mémoire (THP et sysctl)"
val=$(< "$THP/enabled");                    [[ $val == *"[always]"* ]];        res $? "THP enabled = always" "$val"
val=$(< "$THP/defrag");                     [[ $val == *"[defer+madvise]"* ]]; res $? "THP defrag = defer+madvise" "$val"
val=$(< "$THP/khugepaged/max_ptes_none");   [[ $val == 0 ]];                   res $? "THP khugepaged/max_ptes_none = 0" "$val"
val=$(sysctl -n vm.overcommit_memory);      [[ $val == 1 ]];                   res $? "vm.overcommit_memory = 1" "$val"
val=$(sysctl -n vm.swappiness);             (( val <= 1 ));                    res $? "vm.swappiness <= 1" "$val"
val=$(sysctl -n vm.zone_reclaim_mode);      [[ $val == 0 ]];                   res $? "vm.zone_reclaim_mode = 0" "$val"
mini=$(( nofile * 8 / 10 ))
val=$(sysctl -n vm.max_map_count);          (( val >= mini ));                 res $? "vm.max_map_count >= $mini" "$val"
val=$(sysctl -n net.ipv4.tcp_keepalive_time); [[ $val == 120 ]];               res $? "net.ipv4.tcp_keepalive_time = 120" "$val"

echo "== Stockage"
val=$(findmnt -n -o FSTYPE --target "$DBPATH"); [[ $val == xfs ]];            res $? "Système de fichiers de $DBPATH = xfs" "$val"
val=$(findmnt -n -o OPTIONS --target "$DBPATH"); [[ ,$val, == *,noatime,* ]];  res $? "Montage avec noatime" "$(cut -d, -f1-2 <<< "$val")"
dev=$(findmnt -n -o SOURCE --target "$DBPATH")
val=$(blockdev --getra "$dev" 2>/dev/null || echo "?"); [[ $val =~ ^[0-9]+$ ]] && (( val >= 8 && val <= 32 )); res $? "Readahead de $dev entre 8 et 32" "$val"
for q in /sys/block/{sd,vd,xvd,nvme}*/queue/scheduler; do
  [[ -e $q ]] || continue
  d=${q#/sys/block/}; d=${d%%/*}
  val=$(< "$q"); [[ $val == *"[none]"* ]]; res $? "Ordonnanceur d'E/S de $d = none" "$val"
done
val=$(stat -c '%U:%G %a' "$DBPATH"); [[ $val == mongodb:mongodb* ]];          res $? "Propriétaire de $DBPATH" "$val"

echo "== Système"
val=$(lscpu -p=NODE 2>/dev/null | grep -v '^#' | sort -u | wc -l); (( val <= 1 )); res $? "Nœuds NUMA (1 attendu sur une VM)" "$val"
val=$(timedatectl show -p NTPSynchronized --value 2>/dev/null); [[ $val == yes ]]; res $? "Horloge synchronisée (NTP)" "${val:-inconnu}"

echo "== Service mongod"
val=$(systemctl is-enabled mongod 2>/dev/null); [[ $val == enabled ]];         res $? "mongod activé au démarrage" "$val"
val=$(systemctl is-active mongod 2>/dev/null);  [[ $val == active ]];          res $? "mongod en cours d'exécution" "$val"
if [[ ${pid:-0} != 0 && -d /proc/$pid ]]; then
  (( nofile >= 64000 )); res $? "ulimit fichiers ouverts >= 64000" "$nofile"
  val=$(awk '/^Max processes/ {print $3}' "/proc/$pid/limits"); (( val >= 64000 )); res $? "ulimit processus >= 64000" "$val"
  val=$(tr '\0' '\n' < "/proc/$pid/environ" | grep '^GLIBC_TUNABLES=' || true)
  [[ $val == *glibc.pthread.rseq=0* ]]; res $? "glibc rseq désactivé" "${val:-absent}"
  val=$(ss -Hltn 'sport = :27017' | awk '{print $4}' | sort -u | paste -sd ' ')
  [[ $val == "127.0.0.1:27017" ]]; res $? "Écoute réseau limitée à 127.0.0.1" "${val:-aucune}"
fi

echo "== Connexion avec mongosh"
for _ in $(seq 1 30); do
  mongosh --quiet --norc "$URI" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1 && break
  sleep 1
done
json=$(mongosh --quiet --norc "$URI" --eval '
  const s = db.serverStatus();
  const w = db.adminCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg);
  print(JSON.stringify({ version: s.version, perCpu: s.tcmalloc.usingPerCPUCaches, warnings: w }));' 2>/dev/null)
if [[ -n $json ]]; then
  res 0 "Connexion à mongodb://127.0.0.1:27017" "MongoDB $(jq -r .version <<< "$json")"
  val=$(jq -r .perCpu <<< "$json"); [[ $val == true ]]; res $? "Caches TCMalloc par CPU actifs" "$val"
  autres=$(jq -r '.warnings[] | select(startswith("Access control is not enabled") | not)' <<< "$json")
  [[ -z $autres ]]; res $? "Aucun autre avertissement que l'accès libre" "$(jq '.warnings | length' <<< "$json") avertissement(s)"
  [[ -n $autres ]] && printf '         - %s\n' "$autres"
else
  res 1 "Connexion à mongodb://127.0.0.1:27017" "échec"
fi

echo
echo "Bilan : ${nb_ok} OK, ${nb_ko} KO"
exit $(( nb_ko > 0 ))
