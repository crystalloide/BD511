# `check-mongodb.sh` — explications

**Module BD511 · Chapitre 2 · Contrôle de l'installation MongoDB et des réglages de production**

## En bref

Ce script passe en revue votre installation de MongoDB et tous les réglages système recommandés pour la production. Pour chaque point, il affiche :

- `[OK]` en vert ou `[KO]` en rouge ;
- un libellé décrivant ce qui est contrôlé ;
- la valeur **réellement constatée** sur la machine.

Il se termine par un bilan (`Bilan : N OK, M KO`). Il ne modifie rien, mais il a besoin de `sudo` pour lire certaines informations réservées à `root` : les limites et l'environnement du processus `mongod`, le réglage de lecture anticipée du disque.

```bash
sudo bash ~/bd511/ch02/check-mongodb.sh
```

Il utilise deux outils qui doivent être installés : `mongosh` (le shell MongoDB) et `jq` (un outil en ligne de commande pour lire du JSON).

Le script est organisé en sections : préparation, noyau et processeur, mémoire, stockage, système, service `mongod`, connexion avec `mongosh`, bilan. Un **mémo** en fin de document résume chaque réglage et sa raison d'être.

---

## 1. Préparation

### En-tête et options

```bash
#!/usr/bin/env bash
# check-mongodb.sh - BD511 ch.2 : contrôle de l'installation MongoDB et des réglages de production
# Usage : sudo bash ~/bd511/ch02/check-mongodb.sh
set -u
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
```

- le **shebang** indique un script bash, les lignes `#` sont des commentaires ;
- `set -u` arrête le script si une variable non définie est utilisée. Il n'y a volontairement pas de `set -e` : un contrôle en échec ne doit pas interrompre le script, qui doit afficher **tous** les résultats ;
- la dernière ligne vérifie que le script tourne en `root` (`$EUID` vaut 0), sinon elle affiche un message sur la sortie d'erreur (`>&2`) et s'arrête.

### Variables

```bash
DBPATH=/var/lib/mongodb
URI="mongodb://127.0.0.1:27017/admin?directConnection=true&serverSelectionTimeoutMS=2000"
THP=/sys/kernel/mm/transparent_hugepage
nb_ok=0; nb_ko=0
```

- `DBPATH` : dossier des données MongoDB ;
- `URI` : chaîne de connexion utilisée par `mongosh`, détaillée en section 7 ;
- `THP` : dossier du noyau qui contient les réglages des *Transparent Huge Pages* ;
- `nb_ok`, `nb_ko` : compteurs de résultats. Le `;` permet d'écrire deux commandes sur une même ligne.

### La fonction d'affichage `res`

```bash
res() {  # res <code retour du test> <libellé> <valeur constatée>
  local espaces=$(( 47 - ${#2} ))
  (( espaces < 1 )) && espaces=1
  if [[ $1 == 0 ]]; then printf '  \033[32m[OK]\033[0m %s%*s%s\n' "$2" "$espaces" '' "$3"; nb_ok=$((nb_ok + 1))
  else                   printf '  \033[31m[KO]\033[0m %s%*s%s\n' "$2" "$espaces" '' "$3"; nb_ko=$((nb_ko + 1)); fi
}
```

Cette fonction affiche une ligne de résultat. Elle reçoit trois arguments : `$1` le résultat du test (0 = réussi), `$2` le libellé, `$3` la valeur constatée.

- `${#2}` est la **longueur** du libellé. `espaces` est le nombre d'espaces à ajouter pour que toutes les valeurs commencent à la même colonne ; il vaut au moins 1 ;
- `\033[32m` et `\033[31m` sont des **codes de couleur ANSI** compris par le terminal (vert et rouge) ; `\033[0m` revient à la couleur normale ;
- dans le format de `printf`, `%s` affiche le libellé, puis `%*s` utilise **deux** arguments : une largeur (`$espaces`) et un texte (`''`, vide). Il affiche donc exactement `$espaces` espaces. Le dernier `%s` affiche la valeur ;
- selon le résultat, le compteur `nb_ok` ou `nb_ko` est incrémenté.

### Le schéma de chaque contrôle

Presque toutes les lignes du script suivent le même modèle :

```bash
val=$(commande);   test sur "$val";   res $? "Libellé" "$val"
```

1. `$(commande)` récupère ce qu'affiche la commande et le range dans `val` ;
2. un test vérifie cette valeur : `[[ ... ]]` pour comparer du texte, `(( ... ))` pour comparer des nombres ;
3. `$?` contient le **code retour de la dernière commande exécutée**, ici le test : `0` s'il est vrai, autre chose sinon. Il est transmis à `res` avec le libellé et la valeur.

### La fonction `noyau_compatible`

```bash
noyau_compatible() {  # règle de mongod 8.3.x : noyaux 6.19.0 à 7.0.13 refusés
  [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
  local v=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} ))
  (( v < 6019000 || v > 7000013 ))
}
```

Fonction identique à celle de `00-verif-plateforme.sh` (voir sa fiche pour le détail) :

- l'expression régulière extrait les trois nombres de la version (`6.8.0-87-generic` donne 6, 8 et 0), rangés dans `BASH_REMATCH` ;
- `10#` force la lecture en base 10 ;
- la version devient un entier (6.8.0 donne 6 008 000) ;
- la fonction réussit si la version est antérieure à 6.19.0 ou postérieure à 7.0.13.

---

## 2. Noyau et processeur

```bash
echo "== Noyau et processeur"
val=$(uname -r); noyau_compatible "$val"; res $? "Noyau hors plage 6.19 - 7.0.13" "$val"
```

`uname -r` donne le noyau en cours d'exécution. Après la partie 0.4, il doit s'agir d'un noyau `6.8.0-…`.

```bash
if [[ $(uname -m) == x86_64 ]]; then
  grep -qw avx /proc/cpuinfo; rc=$?; res $rc "Jeu d'instructions AVX" "$([[ $rc == 0 ]] && echo présent || echo absent)"
fi
```

Uniquement sur processeur Intel/AMD (`x86_64`) :

- `grep -qw avx /proc/cpuinfo` cherche le mot exact `avx` dans les capacités du processeur ;
- `rc=$?` **sauvegarde** le code retour tout de suite, car `$?` est écrasé par chaque nouvelle commande, et on en a besoin deux fois ;
- `cond && echo présent || echo absent` affiche « présent » si la condition est vraie, « absent » sinon.

### Lecture des limites du processus `mongod`

```bash
pid=$(systemctl show -p MainPID --value mongod 2>/dev/null)
nofile=64000
[[ ${pid:-0} != 0 && -r /proc/$pid/limits ]] && nofile=$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits")
```

Ces lignes préparent des valeurs utilisées plus loin :

- `systemctl show -p MainPID --value mongod` donne le **PID** (numéro de processus) de `mongod`, ou `0` s'il ne tourne pas ;
- `nofile` reçoit une valeur par défaut de 64 000 ;
- si `mongod` tourne (`${pid:-0} != 0`) et que son fichier de limites est lisible (`-r`), on y lit la vraie valeur. Le fichier `/proc/<PID>/limits` montre les limites **réellement appliquées** au processus, et non celles qu'on croit avoir configurées. Sa ligne `Max open files   64000   64000   files` se découpe en champs : `Max`(1) `open`(2) `files`(3) puis la limite souple (4). `awk` affiche ce 4ᵉ champ.

---

## 3. Mémoire (THP et sysctl)

```bash
echo "== Mémoire (THP et sysctl)"
```

### Transparent Huge Pages (THP)

La mémoire est découpée en **pages**, de 4 Kio par défaut. Avec les *Transparent Huge Pages*, le noyau peut utiliser automatiquement des pages de 2 Mio, ce qui accélère les accès mémoire des programmes qui en manipulent beaucoup. Avant MongoDB 8.0, on recommandait de désactiver THP. **Depuis la version 8.0**, MongoDB utilise une nouvelle version de son allocateur mémoire TCMalloc, qui en tire parti : on recommande désormais de **l'activer**, avec des réglages précis.

```bash
val=$(< "$THP/enabled");                    [[ $val == *"[always]"* ]];        res $? "THP enabled = always" "$val"
```

- `$(< fichier)` lit le contenu d'un fichier (plus rapide que `cat`) ;
- le fichier contient par exemple `[always] madvise never` : la valeur **entre crochets** est la valeur active ;
- `[[ $val == *"[always]"* ]]` teste si le texte contient `[always]` ; `*` remplace n'importe quelle suite de caractères. Les guillemets autour de `[always]` sont indispensables : sans eux, bash interpréterait les crochets comme un motif (« un caractère parmi a, l, w, y, s »).

```bash
val=$(< "$THP/defrag");                     [[ $val == *"[defer+madvise]"* ]]; res $? "THP defrag = defer+madvise" "$val"
```

`defrag` règle ce que fait le noyau quand il manque de grandes pages libres. Avec `defer+madvise`, il ne bloque pas le programme pour réorganiser (« compacter ») la mémoire, sauf pour les zones qui l'ont explicitement demandé ; le reste est confié à un processus d'arrière-plan. On évite ainsi des pics de latence.

```bash
val=$(< "$THP/khugepaged/max_ptes_none");   [[ $val == 0 ]];                   res $? "THP khugepaged/max_ptes_none = 0" "$val"
```

`khugepaged` est le processus du noyau qui regroupe en arrière-plan des petites pages en une grande page. `max_ptes_none = 0` lui interdit de créer une grande page si certaines des petites pages concernées ne sont pas réellement utilisées, ce qui évite de gonfler la consommation mémoire.

### Paramètres noyau (sysctl)

`sysctl -n <paramètre>` lit la valeur d'un paramètre du noyau ; `-n` n'affiche que la valeur.

```bash
val=$(sysctl -n vm.overcommit_memory);      [[ $val == 1 ]];                   res $? "vm.overcommit_memory = 1" "$val"
```

`vm.overcommit_memory = 1` : le noyau accepte toujours les demandes d'allocation mémoire sans les estimer au préalable. C'est la valeur recommandée par MongoDB avec la configuration THP ci-dessus.

```bash
val=$(sysctl -n vm.swappiness);             (( val <= 1 ));                    res $? "vm.swappiness <= 1" "$val"
```

`vm.swappiness` règle la tendance du noyau à envoyer de la mémoire sur le disque (*swap*). À 0 ou 1, il ne le fait qu'en dernier recours. Une base de données dont la mémoire part en swap devient extrêmement lente.

```bash
val=$(sysctl -n vm.zone_reclaim_mode);      [[ $val == 0 ]];                   res $? "vm.zone_reclaim_mode = 0" "$val"
```

Sur une machine **NUMA** (plusieurs processeurs ayant chacun leur propre mémoire), `zone_reclaim_mode` pousse le noyau à libérer de la mémoire locale plutôt qu'à utiliser celle d'un autre processeur. Pour MongoDB, ce comportement dégrade les performances : on le désactive (0).

```bash
mini=$(( nofile * 8 / 10 ))
val=$(sysctl -n vm.max_map_count);          (( val >= mini ));                 res $? "vm.max_map_count >= $mini" "$val"
```

`vm.max_map_count` est le nombre maximal de zones mémoire qu'un processus peut réserver. `mongod` en consomme notamment pour chaque thread de connexion. Le seuil exigé par le script vaut 80 % de la limite de fichiers ouverts (51 200 pour 64 000), ce qui correspond au nombre maximal de connexions accepté par défaut par `mongod`.

```bash
val=$(sysctl -n net.ipv4.tcp_keepalive_time); [[ $val == 120 ]];               res $? "net.ipv4.tcp_keepalive_time = 120" "$val"
```

Délai, en secondes, avant que le système vérifie qu'une connexion TCP inactive est toujours vivante. La valeur par défaut est de 7 200 s (2 h) ; MongoDB recommande 120 s pour détecter et libérer plus vite les connexions mortes.

---

## 4. Stockage

```bash
echo "== Stockage"
val=$(findmnt -n -o FSTYPE --target "$DBPATH"); [[ $val == xfs ]];            res $? "Système de fichiers de $DBPATH = xfs" "$val"
```

- `findmnt --target <chemin>` trouve le système de fichiers qui **contient** ce chemin, même si le chemin n'est pas lui-même un point de montage (si le volume XFS n'est pas monté, on obtient le système de fichiers de `/`, en général `ext4`) ;
- `-o FSTYPE` n'affiche que le type, `-n` supprime l'en-tête.

XFS est le système de fichiers recommandé pour WiredTiger.

```bash
val=$(findmnt -n -o OPTIONS --target "$DBPATH"); [[ ,$val, == *,noatime,* ]];  res $? "Montage avec noatime" "$(cut -d, -f1-2 <<< "$val")"
```

- `-o OPTIONS` donne les options de montage, séparées par des virgules : `rw,noatime,attr2,…` ;
- l'astuce `,$val,` ajoute une virgule au début et à la fin, puis on cherche `,noatime,`. Cela trouve l'option où qu'elle soit (même en première ou dernière position) et seulement si c'est **exactement** cette option, pas un mot qui la contiendrait ;
- `cut -d, -f1-2` n'affiche que les deux premières options (`-d,` : séparateur virgule, `-f1-2` : champs 1 à 2) ; `<<<` envoie la chaîne en entrée de la commande.

```bash
dev=$(findmnt -n -o SOURCE --target "$DBPATH")
val=$(blockdev --getra "$dev" 2>/dev/null || echo "?"); [[ $val =~ ^[0-9]+$ ]] && (( val >= 8 && val <= 32 )); res $? "Readahead de $dev entre 8 et 32" "$val"
```

- `-o SOURCE` donne le périphérique qui porte les données (dans ce TP, le périphérique loop créé par `02-volume-xfs.sh`, par exemple `/dev/loop0`) ;
- `blockdev --getra` lit la **lecture anticipée** (*readahead*) : quand on lit un bloc, le système lit aussi par avance les blocs suivants. La valeur est en secteurs de 512 octets ; `|| echo "?"` affiche `?` si la commande échoue ;
- `[[ $val =~ ^[0-9]+$ ]]` vérifie que la valeur est bien un nombre avant de faire un calcul dessus ;
- MongoDB recommande entre 8 et 32 secteurs (4 à 16 Kio) : WiredTiger lit des petits blocs à des endroits variés, et une lecture anticipée plus grande chargerait surtout des données inutiles.

```bash
for q in /sys/block/{sd,vd,xvd,nvme}*/queue/scheduler; do
  [[ -e $q ]] || continue
  d=${q#/sys/block/}; d=${d%%/*}
  val=$(< "$q"); [[ $val == *"[none]"* ]]; res $? "Ordonnanceur d'E/S de $d = none" "$val"
done
```

Contrôle l'**ordonnanceur d'entrées/sorties** de chaque disque, c'est-à-dire l'algorithme qui choisit l'ordre des lectures et écritures envoyées au disque.

- `{sd,vd,xvd,nvme}` est un **développement d'accolades** : bash produit quatre motifs, `/sys/block/sd*/…`, `/sys/block/vd*/…`, `/sys/block/xvd*/…` et `/sys/block/nvme*/…`, couvrant les disques SATA/SCSI, virtio, Xen et NVMe ;
- `[[ -e $q ]] || continue` ignore les motifs qui ne correspondent à aucun disque ;
- `${q#/sys/block/}` retire le début du chemin, puis `${d%%/*}` retire tout ce qui suit le premier `/` : `/sys/block/vda/queue/scheduler` donne `vda` ;
- le fichier contient par exemple `[none] mq-deadline` ; la valeur entre crochets est la valeur active.

Dans une VM, l'hyperviseur et le disque physique ordonnent déjà les opérations : un ordonnancement supplémentaire dans la VM n'apporte rien. La valeur recommandée est `none`.

```bash
val=$(stat -c '%U:%G %a' "$DBPATH"); [[ $val == mongodb:mongodb* ]];          res $? "Propriétaire de $DBPATH" "$val"
```

`stat -c` affiche des informations formatées sur un fichier : `%U` le propriétaire, `%G` le groupe, `%a` les droits en octal. Résultat attendu : `mongodb:mongodb 750`. Le `*` final du test accepte n'importe quels droits, du moment que le propriétaire est correct.

---

## 5. Système

```bash
echo "== Système"
val=$(lscpu -p=NODE 2>/dev/null | grep -v '^#' | sort -u | wc -l); (( val <= 1 )); res $? "Nœuds NUMA (1 attendu sur une VM)" "$val"
```

Compte les nœuds NUMA :

- `lscpu -p=NODE` affiche, pour chaque cœur, le numéro du nœud NUMA auquel il appartient ;
- `grep -v '^#'` retire les lignes de commentaire ;
- `sort -u` trie et supprime les doublons ;
- `wc -l` compte les lignes restantes, donc le nombre de nœuds différents.

Une VM n'a normalement qu'un nœud. Sur un serveur à plusieurs nœuds, il faudrait lancer `mongod` avec `numactl --interleave=all`.

```bash
val=$(timedatectl show -p NTPSynchronized --value 2>/dev/null); [[ $val == yes ]]; res $? "Horloge synchronisée (NTP)" "${val:-inconnu}"
```

`timedatectl` indique si l'horloge est synchronisée sur un serveur de temps (NTP). Une horloge juste est indispensable pour des journaux cohérents et, plus tard, pour la réplication entre plusieurs serveurs.

---

## 6. Service `mongod`

```bash
echo "== Service mongod"
val=$(systemctl is-enabled mongod 2>/dev/null); [[ $val == enabled ]];         res $? "mongod activé au démarrage" "$val"
val=$(systemctl is-active mongod 2>/dev/null);  [[ $val == active ]];          res $? "mongod en cours d'exécution" "$val"
```

- `is-enabled` : le service démarre-t-il automatiquement avec la machine ? (attendu : `enabled`) ;
- `is-active` : le service tourne-t-il en ce moment ? (attendu : `active`).

```bash
if [[ ${pid:-0} != 0 && -d /proc/$pid ]]; then
```

Les contrôles suivants n'ont de sens que si `mongod` tourne : on vérifie que son PID est connu et que son dossier `/proc/<PID>` existe.

```bash
  (( nofile >= 64000 )); res $? "ulimit fichiers ouverts >= 64000" "$nofile"
  val=$(awk '/^Max processes/ {print $3}' "/proc/$pid/limits"); (( val >= 64000 )); res $? "ulimit processus >= 64000" "$val"
```

Limites du processus, lues dans `/proc/<PID>/limits` :

- **fichiers ouverts** (`nofile`, lu en section 2) : chaque connexion cliente et chaque fichier de données occupe un descripteur de fichier ;
- **processus** : sous Linux, cette limite compte aussi les **threads**, et `mongod` en utilise beaucoup. La ligne `Max processes  64000 …` n'a que deux mots avant la valeur : on lit donc le 3ᵉ champ.

MongoDB recommande au moins 64 000 pour ces deux limites ; le service installé par les paquets MongoDB les fixe à cette valeur.

```bash
  val=$(tr '\0' '\n' < "/proc/$pid/environ" | grep '^GLIBC_TUNABLES=' || true)
  [[ $val == *glibc.pthread.rseq=0* ]]; res $? "glibc rseq désactivé" "${val:-absent}"
```

- `/proc/<PID>/environ` contient les variables d'environnement du processus, séparées par des caractères nuls (`\0`). `tr '\0' '\n'` les remplace par des retours à la ligne pour pouvoir les lire ligne par ligne ;
- `grep '^GLIBC_TUNABLES='` garde la variable qui nous intéresse ; `|| true` évite une erreur si elle est absente ;
- on vérifie qu'elle contient `glibc.pthread.rseq=0`.

**Pourquoi ?** Depuis MongoDB 8.0, TCMalloc garde un cache mémoire **par processeur**, ce qui repose sur un mécanisme du noyau appelé *rseq* (*restartable sequences*). Or la bibliothèque C du système (glibc) réserve elle-même rseq pour chaque thread, ce qui empêche TCMalloc de l'utiliser. Ce réglage demande à glibc de ne pas le faire, afin de laisser rseq à TCMalloc. Il est défini dans la configuration du service `mongod`.

```bash
  val=$(ss -Hltn 'sport = :27017' | awk '{print $4}' | sort -u | paste -sd ' ')
  [[ $val == "127.0.0.1:27017" ]]; res $? "Écoute réseau limitée à 127.0.0.1" "${val:-aucune}"
fi
```

Vérifie sur quelles adresses `mongod` attend des connexions :

- `ss` liste les connexions réseau : `-H` sans en-tête, `-l` uniquement les ports en écoute, `-t` TCP, `-n` adresses en chiffres (sans résolution de noms) ;
- `'sport = :27017'` est un filtre : port local 27017 ;
- `awk '{print $4}'` garde la 4ᵉ colonne, l'adresse locale (`127.0.0.1:27017`) ;
- `sort -u` supprime les doublons et `paste -sd ' '` regroupe toutes les lignes en une seule, séparées par des espaces.

Résultat attendu : **uniquement** `127.0.0.1:27017`. Tant que l'authentification n'est pas activée, le serveur ne doit être joignable que depuis la machine elle-même (paramètre `net.bindIp` de `/etc/mongod.conf`).

---

## 7. Connexion avec `mongosh`

```bash
echo "== Connexion avec mongosh"
for _ in $(seq 1 30); do
  mongosh --quiet --norc "$URI" --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1 && break
  sleep 1
done
```

Attend que le serveur réponde, pendant 30 secondes au plus (utile si `mongod` vient d'être redémarré) :

- `seq 1 30` produit les nombres 1 à 30 : la boucle tourne 30 fois au maximum. La variable `_` n'est pas utilisée, son nom indique simplement qu'elle ne sert à rien ;
- `mongosh --quiet` supprime le message d'accueil, `--norc` ignore le fichier de personnalisation `~/.mongoshrc.js`, `--eval` exécute le code JavaScript donné ;
- la commande `ping` vérifie que le serveur répond ;
- `>/dev/null 2>&1` masque à la fois la sortie normale et la sortie d'erreur ;
- `&& break` sort de la boucle dès que la connexion réussit ; sinon, `sleep 1` attend une seconde avant de réessayer.

La chaîne de connexion `URI` se décompose ainsi :

| Partie | Signification |
|---|---|
| `mongodb://` | protocole MongoDB |
| `127.0.0.1:27017` | adresse et port du serveur |
| `/admin` | base utilisée pour la connexion |
| `directConnection=true` | se connecter directement à ce serveur, sans chercher d'autres membres d'un *replica set* |
| `serverSelectionTimeoutMS=2000` | abandonner après 2 secondes au lieu de 30 par défaut |

```bash
json=$(mongosh --quiet --norc "$URI" --eval '
  const s = db.serverStatus();
  const w = db.adminCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg);
  print(JSON.stringify({ version: s.version, perCpu: s.tcmalloc.usingPerCPUCaches, warnings: w }));' 2>/dev/null)
```

Un seul appel à `mongosh` récupère toutes les informations, au format JSON, dans la variable `json` :

- `db.serverStatus()` renvoie l'état du serveur (version, mémoire, connexions…) ;
- `getLog: "startupWarnings"` renvoie les **avertissements affichés au démarrage** de `mongod`. Depuis MongoDB 4.4, les journaux sont écrits en JSON : chaque entrée est une chaîne JSON, que `JSON.parse(l)` transforme en objet pour en extraire le message (`.msg`) ;
- `s.tcmalloc.usingPerCPUCaches` indique si les caches TCMalloc par processeur sont actifs ;
- `print(JSON.stringify({...}))` affiche le tout sous forme de texte JSON, par exemple `{"version":"8.3.x","perCpu":true,"warnings":["Access control is not enabled…"]}`.

```bash
if [[ -n $json ]]; then
  res 0 "Connexion à mongodb://127.0.0.1:27017" "MongoDB $(jq -r .version <<< "$json")"
```

Si `json` n'est pas vide (`-n`), la connexion a réussi : on appelle directement `res 0`. `jq -r .version` extrait le champ `version` du JSON ; `-r` l'affiche sans guillemets.

```bash
  val=$(jq -r .perCpu <<< "$json"); [[ $val == true ]]; res $? "Caches TCMalloc par CPU actifs" "$val"
```

`true` attendu. C'est la **preuve** que le réglage `GLIBC_TUNABLES` vérifié plus haut fonctionne : TCMalloc a bien pu utiliser rseq.

```bash
  autres=$(jq -r '.warnings[] | select(startswith("Access control is not enabled") | not)' <<< "$json")
  [[ -z $autres ]]; res $? "Aucun autre avertissement que l'accès libre" "$(jq '.warnings | length' <<< "$json") avertissement(s)"
  [[ -n $autres ]] && printf '         - %s\n' "$autres"
```

- le filtre `jq` parcourt les avertissements (`.warnings[]`) et ne garde que ceux qui **ne commencent pas** par « Access control is not enabled » (`select(... | not)`) ;
- cet avertissement-là est normal à ce stade : l'authentification n'est pas encore activée. **Tout autre avertissement** signale un réglage oublié ;
- `-z` teste si la chaîne est vide : c'est le résultat attendu ;
- `jq '.warnings | length'` compte le nombre total d'avertissements, affiché comme valeur ;
- s'il reste d'autres avertissements, ils sont affichés sous la ligne pour vous aider à corriger.

```bash
else
  res 1 "Connexion à mongodb://127.0.0.1:27017" "échec"
fi
```

Si `json` est vide, la connexion a échoué : on appelle `res 1`.

---

## 8. Bilan

```bash
echo
echo "Bilan : ${nb_ok} OK, ${nb_ko} KO"
exit $(( nb_ko > 0 ))
```

Affiche le décompte, puis termine avec le code retour `1` s'il y a au moins un KO, `0` sinon (vous pouvez l'afficher avec `echo $?` juste après).

---

## Mémo : les réglages contrôlés et leur raison d'être

| Contrôle | Valeur attendue | Pourquoi |
|---|---|---|
| Noyau | hors 6.19.0 – 7.0.13 | `mongod` 8.3.x refuse de démarrer sur ces noyaux (incompatibilité rseq / TCMalloc) |
| AVX (x86_64) | présent | exigé par les binaires MongoDB depuis la version 5.0 |
| THP `enabled` | `always` | TCMalloc (MongoDB 8.0+) tire parti des pages de 2 Mio |
| THP `defrag` | `defer+madvise` | pas de compaction mémoire bloquante pour `mongod` |
| `khugepaged/max_ptes_none` | `0` | pas de surconsommation mémoire lors des regroupements de pages |
| `vm.overcommit_memory` | `1` | valeur recommandée avec la configuration THP |
| `vm.swappiness` | `0` ou `1` | éviter que la mémoire de la base parte en swap |
| `vm.zone_reclaim_mode` | `0` | éviter des libérations de mémoire coûteuses (NUMA) |
| `vm.max_map_count` | ≥ 80 % de la limite de fichiers | assez de zones mémoire pour toutes les connexions |
| `tcp_keepalive_time` | `120` | détecter plus vite les connexions mortes |
| Système de fichiers | `xfs` | recommandé pour WiredTiger |
| Option de montage | `noatime` | pas d'écriture à chaque lecture |
| Readahead | 8 à 32 secteurs | WiredTiger lit de petits blocs dispersés |
| Ordonnanceur d'E/S | `none` | dans une VM, l'hyperviseur ordonne déjà les E/S |
| Propriétaire du dbPath | `mongodb:mongodb` | `mongod` tourne sous l'utilisateur `mongodb` |
| Nœuds NUMA | 1 | sinon, lancer `mongod` avec `numactl --interleave=all` |
| NTP | `yes` | horodatage fiable (journaux, réplication) |
| Fichiers ouverts / processus | ≥ 64 000 | une connexion = un descripteur de fichier ; nombreux threads |
| `GLIBC_TUNABLES` | `glibc.pthread.rseq=0` | laisser rseq à TCMalloc |
| Écoute réseau | `127.0.0.1:27017` | pas d'accès réseau tant que l'authentification est désactivée |
| Caches TCMalloc par CPU | `true` | preuve que le réglage rseq est effectif |
| Avertissements de démarrage | seulement « Access control… » | tout autre avertissement signale un réglage manquant |
