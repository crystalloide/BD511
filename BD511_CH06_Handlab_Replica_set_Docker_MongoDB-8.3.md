# BD511 – Chapitre 6 – Handlab : replica set sous Docker, keyFile, élection et write concern

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 6 – Réplication |
| **Durée indicative** | 3 h 20 |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop des chapitres précédents (2 vCPU, 4 Go de RAM) avec les réglages système du chapitre 2, mongosh et les Database Tools ; 7 Go libres sur le disque ; accès Internet |
| **Versions vérifiées le 23/10/2026** | MongoDB Community Server **8.3.13** (image Docker officielle `mongo:8.3.13`) · Docker Engine **29.9.2** · Docker Compose **5.6.1** · mongosh **2.13.0** · Database Tools **100.19.1** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. installer Docker Engine depuis le dépôt officiel et le régler pour un usage de production ;
2. traduire l'architecture du cluster du cours en un fichier Docker Compose, et démarrer le replica set **RS1** (un primaire, un secondaire, un arbitre) ;
3. sécuriser le replica set : authentification interne des membres par **keyFile**, comptes administrateur et applicatif, contrôle d'accès ;
4. simuler la **panne du primaire**, observer l'**élection**, le retour de l'ancien primaire et une bascule planifiée ;
5. tester les **write concerns**, mesurer leur comportement quand un membre manque, et provoquer un **rollback** pour comprendre ce qu'un accusé de réception garantit vraiment.

## L'architecture du cours

Le cluster des chapitres 6 et 7 est décrit par le tableau suivant (fichier `Architecture_RS_SHARD_docker-compose.md` fourni avec le cours). Chaque ligne devient un conteneur Docker, avec son adresse IP fixe sur un réseau privé de la VM.

| host | port d'écoute | fonction | groupe | service | paramètre | répertoire |
| --- | --- | --- | --- | --- | --- | --- |
| 192.168.100.111 | 27011 | primary | RS1 | mongod | `--shardsvr` | rs11 |
| 192.168.100.112 | 27012 | secondary | RS1 | mongod | `--shardsvr` | rs12 |
| 192.168.100.113 | 27013 | arbitre | RS1 | mongod | `--shardsvr` | rs1arb |
| 192.168.100.121 | 27021 | primary | RS2 | mongod | `--shardsvr` | rs21 |
| 192.168.100.122 | 27022 | secondary | RS2 | mongod | `--shardsvr` | rs22 |
| 192.168.100.123 | 27023 | arbitre | RS2 | mongod | `--shardsvr` | rs2arb |
| 192.168.100.131 | 27031 | primary | RS3 | mongod | `--shardsvr` | rs31 |
| 192.168.100.132 | 27032 | secondary | RS3 | mongod | `--shardsvr` | rs32 |
| 192.168.100.133 | 27033 | arbitre | RS3 | mongod | `--shardsvr` | rs3arb |
| 192.168.100.101 | 27041 | serveur config | RSCFG | mongod | `--configsvr` | config1 |
| 192.168.100.102 | 27042 | serveur config | RSCFG | mongod | `--configsvr` | config2 |
| 192.168.100.103 | 27043 | serveur config | RSCFG | mongod | `--configsvr` | config3 |
| 192.168.100.141 | 27017 | routeur requête | | mongos | | mongos1 |
| 192.168.100.142 | 27018 | optionnel | | mongos | | mongos2 |

Le fichier Docker Compose de ce TP décrit **toute** l'architecture, mais ce chapitre ne démarre que le replica set **RS1** ; les autres services portent le profil Compose `sharding` et serviront au chapitre 7.

```text
              VM Ubuntu (hôte Docker) - réseau « BD511 » 192.168.100.0/24, passerelle 192.168.100.1
   ┌──────────────────────────┐    ┌──────────────────────────┐    ┌──────────────────────────┐
   │ rs11      .111 : 27011   │    │ rs12      .112 : 27012   │    │ rs1arb    .113 : 27013   │
   │ PRIMARY   (priorité 2)   │───►│ SECONDARY (priorité 1)   │    │ ARBITER   (priorité 0)   │
   │ données : /srv/BD511/rs11│    │ données : /srv/BD511/rs12│    │ vote, aucune donnée      │
   └──────────────────────────┘    └──────────────────────────┘    └──────────────────────────┘
        réplication de l'oplog : rs11 ─► rs12          battements de cœur toutes les 2 s entre les 3 membres
```

> **Un arbitre, et non trois copies des données.** RS1 suit le modèle **PSA** (*Primary-Secondary-Arbiter*) : l'arbitre vote aux élections mais ne stocke rien. Il permet de garder un nombre impair de votants à moindre coût, mais MongoDB le déconseille en production : quand un seul des deux membres porteurs de données est disponible, les écritures `w: "majority"` ne peuvent plus être confirmées. La partie 5 mesure ces conséquences ; en production, on lui préfère un troisième membre porteur de données (modèle PSS).

> **Une seule VM.** Les trois membres tournent ici sur la même machine : la haute disponibilité est simulée. En production, chaque membre est sur un serveur distinct, idéalement dans des salles ou des zones différentes.

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Vérification de la VM | 10 min |
| 1 | Installation et réglage de Docker Engine | 20 min |
| 2 | Volume de données, fichier de clé, configuration et fichier Docker Compose ; démarrage des conteneurs RS1 | 35 min |
| 3 | Initialisation du replica set, comptes, connexion depuis la VM et import de données | 30 min |
| 4 | Panne du primaire, élection, retour de l'ancien primaire, bascule planifiée | 40 min |
| 5 | Write concerns : défauts, membre indisponible, rollback | 50 min |
| 6 | Bilan | 15 min |

## Conventions

- Le TP utilise **trois terminaux** (`Ctrl` + `Alt` + `T`, puis `Ctrl` + `Maj` + `T` pour chaque onglet) :
  - **terminal 1** : les commandes d'administration (bash) ;
  - **terminal 2** : la surveillance du replica set (partie 4 et suivantes) ;
  - **terminal 3** : une application qui écrit en continu (partie 4).
- Les commandes Docker s'exécutent avec `sudo` depuis le répertoire du projet `~/BD511/cluster` : le groupe `docker` donne l'équivalent des droits `root`, on n'y ajoute donc pas le compte de travail.
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Les heures, durées, identifiants (`ObjectId`, conteneurs, ports clients) et numéros de terme d'élection varient d'une VM à l'autre ; tout le reste est identique.
- Les fichiers du TP sont générés dans `~/BD511/ch06` (scripts) et `~/BD511/cluster` (projet Docker Compose, réutilisé au chapitre 7) ; l'annexe B en donne la liste.

> **Note formateur.** L'annexe C remet RS1 à zéro en une commande (suppression des conteneurs et des données) pour repartir de la partie 3.

---

## Partie 0 – Vérification de la VM

### 0.1 Créer l'espace de travail

Dans le terminal 1 :

```bash
mkdir -p ~/BD511/ch06/donnees ~/BD511/cluster/conf
cd ~/BD511/ch06
```

### 0.2 Contrôler les réglages du chapitre 2

Les conteneurs partagent le **noyau de la VM** : les réglages système de production appliqués au chapitre 2 (Transparent Huge Pages, `swappiness`, `max_map_count`…) valent aussi pour les `mongod` lancés sous Docker. Relancez leur contrôle :

```bash
sudo bash ~/BD511/ch02/check-mongodb.sh | tail -n 1
```

Résultat attendu :

```text
Bilan : 26 OK, 0 KO
```

### 0.3 Contrôler les prérequis du chapitre

```bash
cat > ~/BD511/ch06/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.6 : vérifie la VM avant de déployer le replica set sous Docker
# Usage : bash ~/BD511/ch06/00-prerequis.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Système (partagé par l'hôte et tous les conteneurs)"
. /etc/os-release
if [[ $VERSION_ID == 24.04 ]]; then ok "$PRETTY_NAME"; else nok "Ubuntu 24.04 attendu (trouvé : $PRETTY_NAME)"; fi
if grep -qw avx /proc/cpuinfo; then ok "Processeur avec AVX (exigé par MongoDB 5.0 et plus)"; else nok "AVX absent : activez-le dans l'hyperviseur"; fi
thp=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled)
defrag=$(sed -n 's/.*\[\(.*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/defrag)
if [[ $thp == always && $defrag == defer+madvise ]]; then ok "THP : enabled=$thp, defrag=$defrag (chapitre 2)"
else nok "THP : enabled=$thp, defrag=$defrag ; refaites la partie 2.2 du chapitre 2"; fi
ntp=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
if [[ $ntp == yes ]]; then ok "Horloge synchronisée (NTP)"; else nok "Horloge non synchronisée : sudo timedatectl set-ntp true"; fi
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"; else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; fermez des applications"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 7 )); then ok "Espace libre sur / : ${libre} Go (7 Go requis)"; else nok "Espace libre sur / : ${libre} Go (7 Go requis) ; agrandissez le disque (annexe A)"; fi
route=$(ip -4 route show 192.168.100.0/24)
if [[ -z $route || $route == *"dev BD511 "* ]]; then ok "Plage réseau 192.168.100.0/24 libre pour Docker"
else nok "Plage 192.168.100.0/24 déjà utilisée : $route"; fi

echo "== Outils clients installés au chapitre 2"
v=$(mongosh --version 2>/dev/null)
if [[ -n $v ]]; then ok "mongosh $v"; else nok "mongosh absent (chapitre 2, partie 1)"; fi
v=$(mongoimport --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ -n $v ]]; then ok "Database Tools $v"; else nok "mongoimport absent (chapitre 2, partie 1)"; fi
for outil in openssl jq curl; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent : sudo apt-get install -y $outil"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch06/00-prerequis.sh
```

Résultat attendu (mémoire et espace disque variables) :

```text
== Système (partagé par l'hôte et tous les conteneurs)
  [OK] Ubuntu 24.04.3 LTS
  [OK] Processeur avec AVX (exigé par MongoDB 5.0 et plus)
  [OK] THP : enabled=always, defrag=defer+madvise (chapitre 2)
  [OK] Horloge synchronisée (NTP)
  [OK] Mémoire disponible : 2410 Mo (1 536 Mo requis)
  [OK] Espace libre sur / : 9 Go (7 Go requis)
  [OK] Plage réseau 192.168.100.0/24 libre pour Docker
== Outils clients installés au chapitre 2
  [OK] mongosh 2.13.0
  [OK] Database Tools 100.19.1
  [OK] openssl présent
  [OK] jq présent
  [OK] curl présent

Résultat : VM prête pour le TP.
```

Les 7 Go se répartissent ainsi : environ 2 Go pour Docker et l'image MongoDB, 4 Go pour le volume de données du cluster (partie 2.2), le reste en marge. Une horloge synchronisée est indispensable dans un replica set : les journaux, les délais d'élection et la mesure du retard de réplication en dépendent.

---

## Partie 1 – Installer Docker Engine

### 1.1 Installer Docker depuis le dépôt officiel

Ubuntu fournit un paquet `docker.io`, mais il suit le rythme des versions d'Ubuntu. On installe la dernière version de **Docker Engine** et du plugin **Docker Compose** depuis le dépôt officiel de Docker, en retirant d'abord les paquets concurrents éventuels :

```bash
sudo apt-get remove -y $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc 2>/dev/null | cut -f1)
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources > /dev/null <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Le dépôt est déclaré au format **deb822** (`docker.sources`), le format recommandé par Docker et par Ubuntu 24.04.

### 1.2 Régler le démon Docker pour la production

Deux réglages du démon comptent pour des bases de données :

- **rotation des journaux** des conteneurs : sans elle, la sortie de `mongod` (journal JSON) remplirait le disque. Chaque conteneur garde ici au plus 5 fichiers de 50 Mo ;
- **`live-restore`** : les conteneurs continuent de tourner pendant un redémarrage ou une mise à jour du démon Docker.

```bash
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "50m", "max-file": "5" },
  "live-restore": true
}
EOF
dockerd --validate --config-file /etc/docker/daemon.json
sudo systemctl restart docker
sudo systemctl is-enabled docker
```

Résultat attendu :

```text
configuration OK
enabled
```

### 1.3 Vérifier l'installation

```bash
docker version --format 'Docker Engine {{.Server.Version}}'
docker compose version
docker info --format 'journaux={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}} cgroup=v{{.CgroupVersion}}'
docker run --rm hello-world | grep 'Hello from Docker'
```

Résultat attendu (versions du 23/10/2026, ou plus récentes) :

```text
Docker Engine 29.9.2
Docker Compose version v5.6.1
journaux=json-file live-restore=true cgroup=v2
Hello from Docker!
```

### 1.4 Télécharger l'image MongoDB officielle

L'image officielle `mongo` est construite par Docker à partir des paquets `mongodb-org` du dépôt MongoDB, sur une base Ubuntu 24.04 (*noble*). On la désigne par sa **version exacte** : le tag `latest` changerait de version majeure sans prévenir (il pointe aujourd'hui sur la 9.0).

```bash
docker pull -q mongo:8.3.13
docker run --rm mongo:8.3.13 mongod --version | head -n 1
docker run --rm mongo:8.3.13 id mongodb
docker image inspect mongo:8.3.13 --format '{{range .Config.Env}}{{println .}}{{end}}' | grep GLIBC
```

Résultat attendu :

```text
docker.io/library/mongo:8.3.13
db version v8.3.13
uid=999(mongodb) gid=999(mongodb) groups=999(mongodb)
GLIBC_TUNABLES=glibc.pthread.rseq=0
```

Deux informations serviront plus loin :

- dans l'image, `mongod` tourne sous le compte **`mongodb`, uid 999** : les répertoires de données et le fichier de clé devront appartenir à cet uid ;
- l'image désactive déjà `rseq` dans la glibc (`GLIBC_TUNABLES`), le réglage que le chapitre 2 a appliqué au service `mongod` de la VM pour l'allocateur TCMalloc.

---

## Partie 2 – Préparer et démarrer les conteneurs

### 2.1 Décrire l'architecture

Le tableau de l'architecture est enregistré dans le projet sous forme de fichier texte à colonnes séparées par des tabulations : les scripts suivants s'en servent pour créer les répertoires de données et les noms d'hôtes.

```bash
cat > ~/BD511/cluster/architecture.tsv <<'EOF'
host	port d'écoute	fonction	groupe	service	paramètre	répertoire
192.168.100.111	27011	primary	RS1	mongod	--shardsvr	rs11
192.168.100.112	27012	secondary	RS1	mongod	--shardsvr	rs12
192.168.100.113	27013	arbitre	RS1	mongod	--shardsvr	rs1arb
192.168.100.121	27021	primary	RS2	mongod	--shardsvr	rs21
192.168.100.122	27022	secondary	RS2	mongod	--shardsvr	rs22
192.168.100.123	27023	arbitre	RS2	mongod	--shardsvr	rs2arb
192.168.100.131	27031	primary	RS3	mongod	--shardsvr	rs31
192.168.100.132	27032	secondary	RS3	mongod	--shardsvr	rs32
192.168.100.133	27033	arbitre	RS3	mongod	--shardsvr	rs3arb
192.168.100.101	27041	serveur config	RSCFG	mongod	--configsvr	config1
192.168.100.102	27042	serveur config	RSCFG	mongod	--configsvr	config2
192.168.100.103	27043	serveur config	RSCFG	mongod	--configsvr	config3
192.168.100.141	27017	routeur requête		mongos		mongos1
192.168.100.142	27018	optionnel		mongos		mongos2
EOF
column -t -s $'\t' ~/BD511/cluster/architecture.tsv | head -n 4
```

Résultat attendu :

```text
host             port d'écoute  fonction         groupe  service  paramètre    répertoire
192.168.100.111  27011          primary          RS1     mongod   --shardsvr   rs11
192.168.100.112  27012          secondary        RS1     mongod   --shardsvr   rs12
192.168.100.113  27013          arbitre          RS1     mongod   --shardsvr   rs1arb
```

### 2.2 Créer un volume XFS pour les données du cluster

Comme au chapitre 2, les données vont sur un volume **XFS** monté en **`noatime`**, simulé par un fichier image. Il est monté sur `/srv/BD511`, avec un sous-répertoire par `mongod` de l'architecture (colonne « répertoire ») : `/srv/BD511/rs11` deviendra le `/data/db` du conteneur `rs11`. Le script ajoute une dépendance au démon Docker : s'il démarre avant que le volume soit monté, il attend, au lieu de lancer des `mongod` sur des répertoires vides du disque système.

```bash
cat > ~/BD511/ch06/02-volume-cluster.sh <<'EOF'
#!/usr/bin/env bash
# 02-volume-cluster.sh - BD511 ch.6 : volume XFS dédié (noatime) aux données du cluster Docker
# Simule un disque dédié par un fichier image monté en boucle sur /srv/BD511, puis crée un
# répertoire de données par mongod de l'architecture (colonne « répertoire »).
# Usage : sudo bash ~/BD511/ch06/02-volume-cluster.sh ~/BD511/cluster/architecture.tsv [taille_en_Go]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

ARCHI=${1:?"chemin de architecture.tsv attendu"}
TAILLE_GO=${2:-4}
IMAGE=/var/lib/BD511-cluster-xfs.img
POINT=/srv/BD511
UID_MONGODB=999      # utilisateur mongodb de l'image officielle mongo (uid et gid 999)

[[ -r $ARCHI ]] || { echo "Fichier introuvable : $ARCHI" >&2; exit 1; }
command -v mkfs.xfs >/dev/null || apt-get install -y xfsprogs

if ! findmnt -n -t xfs "$POINT" >/dev/null; then
  mkdir -p "$POINT"
  [[ -z $(ls -A "$POINT") ]] || { echo "$POINT n'est pas vide : abandon." >&2; exit 1; }
  if [[ ! -f $IMAGE ]]; then
    libre=$(df --output=avail -BG "$(dirname "$IMAGE")" | tail -n 1 | tr -dc '0-9')
    (( libre - 2 >= TAILLE_GO )) || { echo "Espace disque insuffisant : ${libre} Go libres, $((TAILLE_GO + 2)) Go requis." >&2; exit 1; }
    echo "Création de $IMAGE (${TAILLE_GO} Go)..."
    fallocate -l "${TAILLE_GO}G" "$IMAGE"
    chmod 600 "$IMAGE"
  fi
  if [[ $(blkid -p -s TYPE -o value "$IMAGE" 2>/dev/null || true) != xfs ]]; then
    echo "Formatage XFS..."
    mkfs.xfs -q -f -L BD511cluster "$IMAGE"
  fi
  if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
    printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$POINT"
fi
chmod 0755 "$POINT"

# Un répertoire par mongod (les mongos n'ont pas de données), propriété de l'uid 999, accès restreint.
awk -F'\t' 'NR > 1 && $5 == "mongod" { print $7 }' "$ARCHI" | while read -r rep; do
  install -d -m 0750 -o "$UID_MONGODB" -g "$UID_MONGODB" "$POINT/$rep"
done

# Docker ne doit pas démarrer les conteneurs si le volume n'est pas monté :
# sinon mongod initialiserait des répertoires vides sur le disque système.
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/BD511-volume.conf <<CONF
# BD511 : les conteneurs MongoDB ont besoin du volume de données $POINT
[Unit]
RequiresMountsFor=$POINT
CONF
systemctl daemon-reload

findmnt "$POINT"
ls -ln "$POINT"
EOF
sudo bash ~/BD511/ch06/02-volume-cluster.sh ~/BD511/cluster/architecture.tsv
```

Résultat attendu (le numéro du périphérique `loop` varie ; selon la version du noyau, l'option `attr2` peut ne pas figurer dans la liste) :

```text
Création de /var/lib/BD511-cluster-xfs.img (4 Go)...
Formatage XFS...
TARGET     SOURCE     FSTYPE OPTIONS
/srv/BD511 /dev/loop9 xfs    rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
total 0
drwxr-x--- 2 999 999 6 Oct 23 14:10 config1
drwxr-x--- 2 999 999 6 Oct 23 14:10 config2
drwxr-x--- 2 999 999 6 Oct 23 14:10 config3
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs11
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs12
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs1arb
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs21
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs22
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs2arb
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs31
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs32
drwxr-x--- 2 999 999 6 Oct 23 14:10 rs3arb
```

### 2.3 Déclarer les noms des membres

Les membres d'un replica set se désignent de préférence par des **noms d'hôtes** plutôt que par des adresses IP : une adresse peut changer, le nom reste. Dans le réseau Docker, chaque conteneur est joignable par son nom (`rs11`, `rs12`…) grâce au DNS intégré de Docker. La VM, elle, doit connaître ces noms pour que mongosh et les applications suivent les membres du replica set : le script suivant les ajoute à `/etc/hosts`.

```bash
cat > ~/BD511/ch06/03-hosts.sh <<'EOF'
#!/usr/bin/env bash
# 03-hosts.sh - BD511 ch.6 : déclare les noms des membres du cluster dans /etc/hosts de la VM
# (les conteneurs se résolvent entre eux par le DNS de Docker ; la VM, elle, passe par /etc/hosts).
# Le bloc est délimité par deux marqueurs : le script peut être relancé sans créer de doublons.
# Usage : sudo bash ~/BD511/ch06/03-hosts.sh ~/BD511/cluster/architecture.tsv
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
ARCHI=${1:?"chemin de architecture.tsv attendu"}
DEBUT="# >>> BD511 cluster Docker (généré par 03-hosts.sh)"
FIN="# <<< BD511 cluster Docker"

cp /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d%H%M%S)"
sed -i "/^${DEBUT}\$/,/^${FIN}\$/d" /etc/hosts
{
  echo "$DEBUT"
  awk -F'\t' 'NR > 1 { printf "%s\t%s\n", $1, $7 }' "$ARCHI"
  echo "$FIN"
} >> /etc/hosts
sed -n "/^${DEBUT}\$/,/^${FIN}\$/p" /etc/hosts
EOF
sudo bash ~/BD511/ch06/03-hosts.sh ~/BD511/cluster/architecture.tsv
getent hosts rs11 rs12 rs1arb
```

Résultat attendu :

```text
# >>> BD511 cluster Docker (généré par 03-hosts.sh)
192.168.100.111	rs11
192.168.100.112	rs12
192.168.100.113	rs1arb
192.168.100.121	rs21
192.168.100.122	rs22
192.168.100.123	rs2arb
192.168.100.131	rs31
192.168.100.132	rs32
192.168.100.133	rs3arb
192.168.100.101	config1
192.168.100.102	config2
192.168.100.103	config3
192.168.100.141	mongos1
192.168.100.142	mongos2
# <<< BD511 cluster Docker
192.168.100.111 rs11
192.168.100.112 rs12
192.168.100.113 rs1arb
```

En production, ces noms sont déclarés dans le DNS de l'entreprise, et chaque membre a son propre nom de domaine complet.

### 2.4 Générer le fichier de clé et les mots de passe

Les membres d'un replica set s'authentifient entre eux. La méthode la plus simple est le **fichier de clé** (*keyFile*) : un secret partagé, identique sur tous les membres, de 6 à 1 024 caractères base64. Activer `keyFile` active aussi le **contrôle d'accès** des clients : sans compte, plus rien n'est permis, sauf, depuis l'interface locale du serveur et tant qu'aucun utilisateur n'existe, l'initialisation du replica set et la création du premier utilisateur (exception localhost).

```bash
cd ~/BD511/cluster
install -d -m 700 secrets
openssl rand -base64 756 > secrets/keyfile
chmod 400 secrets/keyfile
sudo chown 999:999 secrets/keyfile
for compte in admin appli; do
  ( umask 077; openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 > "secrets/$compte.pwd" )
done
ls -ln secrets
wc -c secrets/keyfile
```

Résultat attendu (uid de votre compte et dates variables) :

```text
total 12
-rw------- 1 1000 1000   24 Oct 23 14:12 admin.pwd
-rw------- 1 1000 1000   24 Oct 23 14:12 appli.pwd
-r-------- 1  999  999 1024 Oct 23 14:12 keyfile
wc: secrets/keyfile: Permission denied
```

Le refus de lecture est voulu : le fichier de clé appartient désormais à l'uid 999 (le compte `mongodb` des conteneurs), en lecture seule pour lui seul. `mongod` refuse de démarrer si le fichier est lisible par le groupe ou par les autres. Les deux mots de passe (24 caractères alphanumériques) serviront aux comptes `admin` et `appli` de la partie 3 ; ils ne sont lisibles que par vous.

> **En production**, MongoDB réserve le fichier de clé aux environnements de test et de développement et recommande les **certificats x.509** pour l'authentification interne : chaque membre y est identifié individuellement, et les échanges sont chiffrés en TLS. Le fichier de clé reste la méthode la plus simple pour apprendre ; il se distribue alors par un outil de gestion de secrets et se renouvelle régulièrement.

### 2.5 Écrire la configuration commune des `mongod`

Tous les `mongod` du cluster partagent un même fichier de configuration, monté en lecture seule dans chaque conteneur. Les réglages propres à chaque membre (port, adresse d'écoute, replica set, rôle dans le cluster) sont passés en ligne de commande par le fichier Docker Compose.

```bash
cat > ~/BD511/cluster/conf/mongod.conf <<'EOF'
# mongod.conf - BD511 : configuration commune à tous les mongod du cluster Docker (chapitres 6 et 7)
# Montée en lecture seule dans chaque conteneur : /etc/mongo/mongod.conf
# Les réglages propres à chaque membre (port, adresse d'écoute, replica set, rôle dans le cluster)
# sont passés en ligne de commande dans docker-compose.yml.

storage:
  dbPath: /data/db                 # volume XFS de l'hôte (/srv/BD511/<membre>) monté sur /data/db
  wiredTiger:
    engineConfig:
      # Plusieurs mongod partagent la même machine : le cache de chacun est borné explicitement
      # (par défaut, chaque mongod prendrait 50 % de (RAM - 1 Go)). 0,25 Go est le minimum autorisé.
      cacheSizeGB: 0.25

# Pas de section systemLog : le journal part sur la sortie standard, collectée par Docker
# (docker compose logs), avec la rotation définie dans /etc/docker/daemon.json.

security:
  # Authentification interne des membres par fichier de clé partagé.
  # keyFile active aussi le contrôle d'accès des clients (security.authorization).
  keyFile: /etc/mongo/keyfile
  authorization: enabled

replication:
  # Taille de l'oplog fixée explicitement (par défaut : 5 % de l'espace libre, 990 Mo au minimum).
  oplogSizeMB: 1024
EOF
```

Les choix de production de ce fichier :

| Réglage | Valeur | Pourquoi |
| --- | --- | --- |
| `cacheSizeGB` | 0.25 | plusieurs `mongod` partagent la VM : sans borne, chacun prendrait 50 % de (RAM − 1 Go) |
| `security.keyFile` | `/etc/mongo/keyfile` | authentification interne des membres et contrôle d'accès des clients |
| `oplogSizeMB` | 1024 | taille de l'oplog choisie, plutôt que 5 % de l'espace libre du volume |
| pas de `systemLog` | sortie standard | Docker collecte et fait tourner les journaux (partie 1.2) |

### 2.6 Écrire le fichier Docker Compose

Le fichier décrit les 14 services de l'architecture. Une **ancre YAML** (`x-mongodb`) regroupe les réglages communs : version exacte de l'image, redémarrage automatique, délai d'arrêt propre, plafond mémoire et limites de ressources recommandées par MongoDB. Chaque service ajoute son adresse IP fixe, sa ligne de commande et ses volumes. Les services des chapitres suivants portent le profil `sharding` : `docker compose up` ne les démarre pas sans `--profile sharding`.

```bash
cat > ~/BD511/cluster/docker-compose.yml <<'EOF'
# docker-compose.yml - BD511 : cluster MongoDB 8.3 décrit dans architecture.tsv (chapitres 6 et 7)
#   - services sans profil        : replica set RS1 (rs11, rs12, rs1arb)                 -> chapitre 6
#   - profil « sharding »         : RS2, RS3, serveurs de configuration RSCFG, mongos    -> chapitre 7
# Usage : cd ~/BD511/cluster && docker compose up -d --wait
name: BD511

# Réglages communs à tous les processus MongoDB (ancre YAML reprise par chaque service)
x-mongodb: &mongodb
  image: mongo:8.3.13              # version figée : jamais « latest » en production
  restart: unless-stopped          # redémarrage automatique (après un plantage, au démarrage de la VM)
  stop_grace_period: 1m            # temps laissé à mongod pour s'arrêter proprement (10 s par défaut)
  mem_limit: 1g                    # plafond mémoire du conteneur
  ulimits:                         # limites recommandées par les notes de production MongoDB
    nofile: { soft: 64000, hard: 64000 }
    nproc: { soft: 64000, hard: 64000 }

services:
  # ---------- Replica set RS1 (futur shard 1) - chapitre 6 ----------
  rs11:
    <<: *mongodb
    container_name: rs11
    hostname: rs11
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27011", "--bind_ip", "localhost,192.168.100.111",
              "--replSet", "RS1", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.111 }
    volumes:
      - /srv/BD511/rs11:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27011", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs12:
    <<: *mongodb
    container_name: rs12
    hostname: rs12
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27012", "--bind_ip", "localhost,192.168.100.112",
              "--replSet", "RS1", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.112 }
    volumes:
      - /srv/BD511/rs12:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27012", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs1arb:
    <<: *mongodb
    container_name: rs1arb
    hostname: rs1arb
    mem_limit: 512m                # un arbitre ne stocke pas de données
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27013", "--bind_ip", "localhost,192.168.100.113",
              "--replSet", "RS1", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.113 }
    volumes:
      - /srv/BD511/rs1arb:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27013", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  # ---------- Replica set RS2 (shard 2) - chapitre 7 ----------
  rs21:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs21
    hostname: rs21
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27021", "--bind_ip", "localhost,192.168.100.121",
              "--replSet", "RS2", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.121 }
    volumes:
      - /srv/BD511/rs21:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27021", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs22:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs22
    hostname: rs22
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27022", "--bind_ip", "localhost,192.168.100.122",
              "--replSet", "RS2", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.122 }
    volumes:
      - /srv/BD511/rs22:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27022", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs2arb:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs2arb
    hostname: rs2arb
    mem_limit: 512m                # un arbitre ne stocke pas de données
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27023", "--bind_ip", "localhost,192.168.100.123",
              "--replSet", "RS2", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.123 }
    volumes:
      - /srv/BD511/rs2arb:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27023", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  # ---------- Replica set RS3 (shard 3) - chapitre 7 ----------
  rs31:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs31
    hostname: rs31
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27031", "--bind_ip", "localhost,192.168.100.131",
              "--replSet", "RS3", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.131 }
    volumes:
      - /srv/BD511/rs31:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27031", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs32:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs32
    hostname: rs32
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27032", "--bind_ip", "localhost,192.168.100.132",
              "--replSet", "RS3", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.132 }
    volumes:
      - /srv/BD511/rs32:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27032", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs3arb:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: rs3arb
    hostname: rs3arb
    mem_limit: 512m                # un arbitre ne stocke pas de données
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27033", "--bind_ip", "localhost,192.168.100.133",
              "--replSet", "RS3", "--shardsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.133 }
    volumes:
      - /srv/BD511/rs3arb:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27033", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  # ---------- Serveurs de configuration, replica set RSCFG - chapitre 7 ----------
  config1:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: config1
    hostname: config1
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27041", "--bind_ip", "localhost,192.168.100.101",
              "--replSet", "RSCFG", "--configsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.101 }
    volumes:
      - /srv/BD511/config1:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27041", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  config2:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: config2
    hostname: config2
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27042", "--bind_ip", "localhost,192.168.100.102",
              "--replSet", "RSCFG", "--configsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.102 }
    volumes:
      - /srv/BD511/config2:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27042", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  config3:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: config3
    hostname: config3
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27043", "--bind_ip", "localhost,192.168.100.103",
              "--replSet", "RSCFG", "--configsvr"]
    networks:
      BD511: { ipv4_address: 192.168.100.103 }
    volumes:
      - /srv/BD511/config3:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27043", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  # ---------- Routeurs de requêtes mongos - chapitre 7 ----------
  mongos1:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: mongos1
    hostname: mongos1
    command: ["mongos", "--keyFile", "/etc/mongo/keyfile", "--port", "27017", "--bind_ip", "localhost,192.168.100.141",
              "--configdb", "RSCFG/config1:27041,config2:27042,config3:27043"]
    networks:
      BD511: { ipv4_address: 192.168.100.141 }
    volumes:
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27017", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  mongos2:
    <<: *mongodb
    profiles: ["sharding"]
    container_name: mongos2
    hostname: mongos2
    command: ["mongos", "--keyFile", "/etc/mongo/keyfile", "--port", "27018", "--bind_ip", "localhost,192.168.100.142",
              "--configdb", "RSCFG/config1:27041,config2:27042,config3:27043"]
    networks:
      BD511: { ipv4_address: 192.168.100.142 }
    volumes:
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27018", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

networks:
  BD511:
    name: BD511
    driver_opts:
      com.docker.network.bridge.name: BD511   # nom de l'interface réseau sur la VM (ip addr show BD511)
    ipam:
      config:
        - subnet: 192.168.100.0/24
          gateway: 192.168.100.1         # adresse de la VM sur ce réseau
EOF
cd ~/BD511/cluster
docker compose config --quiet && echo "docker-compose.yml valide"
docker compose config --services
docker compose --profile sharding config --services | wc -l
```

Résultat attendu :

```text
docker-compose.yml valide
rs11
rs12
rs1arb
14
```

Points à remarquer dans le service `rs11` :

- `command` ne commence pas par `mongod` : le script d'entrée de l'image l'ajoute, prépare les droits de `/data/db`, puis lance `mongod` sous le compte `mongodb` ;
- `--bind_ip localhost,192.168.100.111` : `mongod` n'écoute que sur l'interface locale du conteneur (pour l'exception localhost) et sur son adresse du réseau `BD511` ;
- `--shardsvr` : le paramètre de l'architecture. RS1 deviendra un shard au chapitre 7 ; d'ici là, il fonctionne comme un replica set ordinaire ;
- `healthcheck` : Docker vérifie toutes les 30 s (toutes les 2 s pendant la première minute) que `mongod` répond à un `ping`, ce qui permet à `docker compose up --wait` d'attendre que les membres soient prêts ;
- `/etc/localtime` : les conteneurs écrivent leurs journaux à l'heure de la VM ;
- aucun port n'est publié sur la VM (`ports:`) : on joint chaque conteneur directement par son adresse sur le réseau `BD511`.

### 2.7 Démarrer les conteneurs de RS1

```bash
cd ~/BD511/cluster
docker compose up -d --wait
docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
ip -4 -br addr show BD511
```

Résultat attendu (l'affichage de `docker compose` se met à jour en direct ; ordre des lignes et durées variables) :

```text
[+] up 4/4
 ✔ Network BD511    Created                                                    0.1s
 ✔ Container rs12   Healthy                                                    6.2s
 ✔ Container rs1arb Healthy                                                    6.2s
 ✔ Container rs11   Healthy                                                    6.7s
NAME      IMAGE          STATUS
rs11      mongo:8.3.13   Up 7 seconds (healthy)
rs12      mongo:8.3.13   Up 7 seconds (healthy)
rs1arb    mongo:8.3.13   Up 7 seconds (healthy)
BD511            UP             192.168.100.1/24
```

Vérifiez dans le journal de `rs11` les options réellement appliquées (fichier commun et ligne de commande fusionnés), puis l'absence d'avertissement de démarrage :

```bash
cd ~/BD511/cluster
docker compose logs --no-log-prefix rs11 | jq -c 'select(.msg == "Options set by command line") | .attr.options'
docker compose logs --no-log-prefix rs11 | jq -r 'select(.tags != null) | .msg'
docker compose logs --no-log-prefix rs11 | jq -r 'select(.id == 22074) | .msg'
```

Résultat attendu :

```text
{"config":"/etc/mongo/mongod.conf","net":{"bindIp":"localhost,192.168.100.111","port":27011},"replication":{"oplogSizeMB":1024,"replSet":"RS1"},"security":{"authorization":"enabled","keyFile":"/etc/mongo/keyfile"},"sharding":{"clusterRole":"shardsvr"},"storage":{"dbPath":"/data/db","wiredTiger":{"engineConfig":{"cacheSizeGB":0.25}}}}
Started with ShardServer role, but no shardIdentity document was found on disk. This most likely means this server has not yet been added to a sharded cluster.
```

La deuxième commande n'affiche rien : aucun avertissement de démarrage (*startupWarnings*), les réglages du chapitre 2 (THP, limites de ressources…) conviennent aussi aux conteneurs. Le seul message attendu, affiché par la troisième commande, rappelle que RS1 n'a pas encore été ajouté à un cluster : ce sera fait au chapitre 7.

---

## Partie 3 – Initialiser et sécuriser le replica set RS1

### 3.1 Constater le contrôle d'accès

Les trois `mongod` tournent, mais ne forment pas encore un replica set, et le contrôle d'accès est déjà actif. Depuis la VM (terminal 1) :

```bash
mongosh --quiet "mongodb://rs11:27011/?directConnection=true" --eval 'db.adminCommand({ ping: 1 }).ok'
mongosh --quiet "mongodb://rs11:27011/?directConnection=true" --eval 'db.adminCommand({ listDatabases: 1 })'
```

Résultat attendu :

```text
1
MongoServerError: Command listDatabases requires authentication
```

Seules quelques commandes de diagnostic, comme `ping`, restent permises sans compte. Pour initialiser le replica set et créer le premier utilisateur, on passe donc par l'**exception localhost** : tant qu'aucun utilisateur n'existe, une session ouverte sur l'interface locale du serveur peut initialiser le replica set (`rs.initiate()`), consulter son état (`rs.status()`) et créer le **premier** utilisateur ou rôle. Ici, l'interface locale est celle du conteneur : on y lance mongosh avec `docker compose exec`.

### 3.2 Initialiser le replica set

Le script suivant décrit les trois membres, puis attend l'élection du primaire. Les membres sont désignés par leur nom d'hôte ; `rs11` reçoit la priorité la plus haute, conformément à l'architecture, et `rs1arb` est déclaré arbitre (`arbiterOnly`).

```bash
cat > ~/BD511/ch06/init-rs1.js <<'EOF'
// init-rs1.js - BD511 ch.6 : initialise le replica set RS1
// Exécuté dans le conteneur rs11, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/BD511/cluster && docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin < ~/BD511/ch06/init-rs1.js
const config = {
  _id: "RS1",
  members: [
    { _id: 0, host: "rs11:27011", priority: 2 },        // primaire de l'architecture : priorité la plus haute
    { _id: 1, host: "rs12:27012", priority: 1 },        // secondaire
    { _id: 2, host: "rs1arb:27013", arbiterOnly: true }, // arbitre : vote, ne stocke pas de données (priorité 0)
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection de rs11 comme primaire (60 s au plus)
for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
for (const m of rs.status().members) print(`${m.name.padEnd(13)} ${m.stateStr}`);
EOF
cd ~/BD511/cluster
docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin < ~/BD511/ch06/init-rs1.js
```

Résultat attendu (après une dizaine de secondes) :

```text
{
  ok: 1
}
rs11:27011    PRIMARY
rs12:27012    SECONDARY
rs1arb:27013  ARBITER
```

L'option `-T` de `docker compose exec` transmet l'entrée standard (le script) à mongosh, qui le lit avec `--file /dev/stdin`. Pendant ces quelques secondes, `rs12` a copié toutes les données de `rs11` (synchronisation initiale), puis les trois membres se sont reconnus grâce au fichier de clé.

### 3.3 Créer les comptes

Deux comptes sont créés dans la base `admin`, toujours par l'exception localhost :

- `admin`, avec le rôle `root`, pour l'administration ;
- `appli`, avec le seul rôle `readWrite` sur la base `BD511`, pour l'application (principe du moindre privilège, chapitre 5).

Les mots de passe sont lus dans les fichiers de la partie 2.4 et transmis par l'entrée standard : ils n'apparaissent jamais dans la ligne de commande, donc ni dans la liste des processus ni dans l'historique du shell. Le compte `appli` est créé après une authentification en `admin`, car l'exception localhost disparaît dès que le premier utilisateur existe. Le write concern `majority` garantit que les comptes sont répliqués sur `rs12` avant la suite.

```bash
cd ~/BD511/cluster
docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin <<EOF
const admin = db.getSiblingDB("admin");
const wc = { w: "majority", wtimeout: 10000 };
admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: [ "root" ] }, wc);
admin.auth("admin", "$(cat secrets/admin.pwd)");
admin.createUser({ user: "appli", pwd: "$(cat secrets/appli.pwd)", roles: [ { role: "readWrite", db: "BD511" } ] }, wc);
for (const u of admin.getUsers().users) print(u.user.padEnd(6), EJSON.stringify(u.roles));
EOF
docker compose exec -T rs11 mongosh --port 27011 --quiet --eval 'db.adminCommand({ listDatabases: 1 })'
```

Résultat attendu :

```text
admin  [{"role":"root","db":"admin"}]
appli  [{"role":"readWrite","db":"BD511"}]
MongoServerError: Command listDatabases requires authentication
```

La dernière commande le confirme : l'exception localhost est refermée, même depuis l'intérieur du conteneur.

> L'arbitre ne stocke aucune donnée, donc aucun utilisateur : on ne peut l'interroger que par l'exception localhost, qui y reste ouverte pour les commandes d'état du replica set. C'est sans risque tant que son interface locale n'est accessible qu'aux administrateurs de la machine (ici, par `docker compose exec`).

### 3.4 Se connecter au replica set depuis la VM

Une application se connecte au **replica set**, pas à un serveur : son URI liste quelques membres (la *seed list*) et le nom du replica set. Le driver découvre alors tous les membres, repère le primaire et le suit quand il change. Le script suivant ouvre mongosh de cette façon, avec l'un des deux comptes :

```bash
cat > ~/BD511/ch06/mongosh-rs1 <<'EOF'
#!/usr/bin/env bash
# mongosh-rs1 - BD511 ch.6 : ouvre mongosh sur le replica set RS1, base BD511
# Le mot de passe est lu dans ~/BD511/cluster/secrets/<compte>.pwd ; mongosh le masque ensuite
# dans la liste des processus (« mongodb://<credentials>@... »). Compte par défaut : admin.
# Usage : ~/BD511/ch06/mongosh-rs1 [--compte appli] [options et scripts mongosh...]
set -euo pipefail
compte=admin
if [[ ${1:-} == --compte ]]; then compte=$2; shift 2; fi
mdp=$(< "$HOME/BD511/cluster/secrets/$compte.pwd")
exec mongosh "mongodb://$compte:$mdp@rs11:27011,rs12:27012/BD511?replicaSet=RS1&authSource=admin&appName=BD511-tp6-$compte" "$@"
EOF
chmod +x ~/BD511/ch06/mongosh-rs1
~/BD511/ch06/mongosh-rs1
```

Le mot de passe figure dans l'URI passée à mongosh, mais mongosh le masque aussitôt dans la liste des processus. Vérifiez-le depuis un autre terminal avec `ps -ef | grep [m]ongosh` : la commande apparaît sous la forme `mongosh mongodb://<credentials>@rs11:27011,rs12:27012/BD511?...`.

L'invite indique le replica set et le rôle du membre courant : `RS1 [primary] BD511>`. Explorez le replica set :

```javascript
db.hello().hosts
db.hello().arbiters
db.hello().primary
rs.conf().members.map(m => ({ membre: m.host, arbitre: m.arbiterOnly, priorite: m.priority, votes: m.votes }))
rs.conf().settings.heartbeatIntervalMillis
rs.conf().settings.electionTimeoutMillis
```

Résultat attendu :

```text
[ 'rs11:27011', 'rs12:27012' ]
[ 'rs1arb:27013' ]
rs11:27011
[
  { membre: 'rs11:27011', arbitre: false, priorite: 2, votes: 1 },
  { membre: 'rs12:27012', arbitre: false, priorite: 1, votes: 1 },
  { membre: 'rs1arb:27013', arbitre: true, priorite: 0, votes: 1 }
]
2000
10000
```

Chaque membre envoie un **battement de cœur** (*heartbeat*) aux autres toutes les 2 secondes ; si aucun primaire n'a donné signe de vie pendant 10 secondes (`electionTimeoutMillis`), un secondaire éligible déclenche une **élection**. Les trois membres votent (1 voix chacun) : il faut **2 voix sur 3** pour être élu primaire.

Quittez mongosh avec `exit`.

### 3.5 Importer un jeu de données

On importe dans RS1 le jeu de données du chapitre 3 (formations, inscriptions, stagiaires), avec le compte `appli`. Copiez d'abord les fichiers du chapitre 3 et vérifiez leur intégrité :

```bash
cp ~/BD511/ch03/donnees/{formations.json,inscriptions.json,stagiaires.csv,stagiaires.fields,SHA256SUMS} ~/BD511/ch06/donnees/
cd ~/BD511/ch06/donnees && sha256sum -c SHA256SUMS
```

Résultat attendu :

```text
formations.json: OK
inscriptions.json: OK
stagiaires.csv: OK
stagiaires.fields: OK
```

> Si le chapitre 3 n'a pas été réalisé sur cette VM, ces cinq fichiers se trouvent dans l'archive `BD511_CH06_fichiers.zip` qui accompagne ce handlab (répertoire `home/BD511/ch06/donnees`).

Le script d'import transmet le mot de passe à `mongoimport` par un fichier de configuration temporaire, lisible par vous seul et supprimé à la fin (option `--config`), et non par la ligne de commande :

```bash
cat > ~/BD511/ch06/importer-rs1.sh <<'EOF'
#!/usr/bin/env bash
# importer-rs1.sh - BD511 ch.6 : importe le jeu de données du chapitre 3 dans le replica set RS1
# Compte applicatif « appli » ; le mot de passe passe par un fichier de configuration temporaire
# (mode 600, supprimé à la fin), jamais par la ligne de commande.
# Usage : bash ~/BD511/ch06/importer-rs1.sh
set -euo pipefail
DONNEES="$HOME/BD511/ch06/donnees"
URI="mongodb://appli@rs11:27011,rs12:27012/?replicaSet=RS1&authSource=admin&appName=BD511-import"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers de données différents de la référence (partie 3.5)." >&2; exit 1; }

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
printf 'password: "%s"\n' "$(< "$HOME/BD511/cluster/secrets/appli.pwd")" > "$conf"

# Écriture confirmée par la majorité des membres porteurs de données, arrêt à la première erreur.
commun=(--config "$conf" --uri "$URI" --db BD511 --drop --writeConcern '{w: "majority"}' --stopOnError --quiet)
mongoimport "${commun[@]}" --collection formations --jsonArray --file formations.json
mongoimport "${commun[@]}" --collection inscriptions --file inscriptions.json
tail -n +2 stagiaires.csv | mongoimport "${commun[@]}" --collection stagiaires --type csv \
  --columnsHaveTypes --fieldFile stagiaires.fields --ignoreBlanks --parseGrace stop

"$HOME/BD511/ch06/mongosh-rs1" --compte appli --quiet --eval '
  for (const nom of ["formations", "inscriptions", "stagiaires"]) {
    print(nom.padEnd(13) + ": " + db.getCollection(nom).countDocuments() + " documents");
  }'
EOF
bash ~/BD511/ch06/importer-rs1.sh
```

Résultat attendu :

```text
formations   : 24 documents
inscriptions : 1202 documents
stagiaires   : 300 documents
```

### 3.6 Vérifier la réplication

Reconnectez-vous avec le compte `admin` et observez l'oplog et la réplication :

```bash
~/BD511/ch06/mongosh-rs1
```

```javascript
rs.printReplicationInfo()
rs.printSecondaryReplicationInfo()
db.inscriptions.find().readPref("secondary").explain().serverInfo.host
db.getMongo().setReadPref("secondary")
db.inscriptions.countDocuments()
db.getMongo().setReadPref("primary")
```

Résultat attendu (dates et durées variables) :

```text
actual oplog size
'1024 MB'
---
configured oplog size
'1024 MB'
---
log length start to end
'95 secs (0.03 hrs)'
---
oplog first event time
'Fri Oct 23 2026 14:15:02 GMT+0200 (Central European Summer Time)'
---
oplog last event time
'Fri Oct 23 2026 14:16:37 GMT+0200 (Central European Summer Time)'
---
now
'Fri Oct 23 2026 14:16:41 GMT+0200 (Central European Summer Time)'
source: rs12:27012
{
  syncedTo: 'Fri Oct 23 2026 14:16:37 GMT+0200 (Central European Summer Time)',
  replLag: '0 secs (0 hrs) behind the primary '
}
rs12
1202
```

- La **fenêtre de l'oplog** (*log length start to end*) est la durée d'activité que l'oplog peut contenir : un secondaire arrêté plus longtemps que cette fenêtre ne pourra plus rattraper son retard et devra refaire une synchronisation initiale complète. En production, on la dimensionne pour couvrir largement la plus longue maintenance prévisible (plusieurs jours), et on la surveille.
- `replLag` mesure le **retard de réplication** du secondaire.
- La lecture avec la préférence `secondary` a bien été servie par `rs12`, qui a les 1 202 inscriptions.

Quittez mongosh (`exit`).

---

## Partie 4 – Panne du primaire et élection

### 4.1 Mettre en place l'observation

Dans le **terminal 2**, lancez la surveillance du replica set : chaque seconde, le script demande l'état des membres, de préférence à un secondaire pour continuer à répondre pendant la panne du primaire, et affiche une ligne à chaque changement.

```bash
cat > ~/BD511/ch06/surveiller-rs.js <<'EOF'
// surveiller-rs.js - BD511 ch.6 : affiche l'état des membres du replica set à chaque changement
// Usage : ~/BD511/ch06/mongosh-rs1 --quiet ~/BD511/ch06/surveiller-rs.js   (15 min par défaut, DUREE=<s> pour changer ; Ctrl+C pour arrêter)
// Chaque seconde, l'état est demandé de préférence à un secondaire (readPreference secondaryPreferred) :
// la surveillance continue pendant la panne du primaire, vue par les autres membres.
const admin = db.getSiblingDB("admin");
const duree = Number(process.env.DUREE || 900);
let precedent = "";
print(`Surveillance de ${db.hello().setName} pendant ${duree} s (une ligne à chaque changement)`);
for (let i = 0; i < duree; i++) {
  let ligne, source = "";
  try {
    const s = admin.runCommand({ replSetGetStatus: 1 }, { readPreference: "secondaryPreferred" });
    source = `   (vu par ${s.members.find(m => m.self).name.split(":")[0]})`;
    const etats = s.members.map(m => `${m.name.split(":")[0]}:${m.health === 1 ? m.stateStr : "injoignable"}`);
    ligne = `terme ${s.term}  ${etats.join("  ")}`;
  } catch (e) {
    ligne = `aucun membre ne répond (${e.codeName || e.name})`;
  }
  if (ligne !== precedent) print(`${new Date().toTimeString().slice(0, 8)}  ${ligne}${source}`);
  precedent = ligne;
  sleep(1000);
}
EOF
~/BD511/ch06/mongosh-rs1 --quiet ~/BD511/ch06/surveiller-rs.js
```

Résultat attendu (heure variable) :

```text
Surveillance de RS1 pendant 900 s (une ligne à chaque changement)
14:20:05  terme 1  rs11:PRIMARY  rs12:SECONDARY  rs1arb:ARBITER   (vu par rs12)
```

Le **terme** (*term*) est le numéro de l'élection en cours : il augmente de 1 à chaque élection. Laissez tourner ce terminal pendant toute la partie 4 (la surveillance s'arrête seule après 15 minutes ; `Ctrl` + `C` l'arrête plus tôt).

Dans le **terminal 3**, créez le script qui simule l'application : il insère un document toutes les 100 ms avec le compte `appli`, et signale toute écriture en erreur ou plus lente qu'une seconde.

```bash
cat > ~/BD511/ch06/ecrivain.js <<'EOF'
// ecrivain.js - BD511 ch.6 : simule une application qui écrit en continu (10 insertions par seconde)
// Usage : DUREE=120 ~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/ecrivain.js
// Affiche les incidents (erreur ou écriture de plus d'une seconde), un point d'étape toutes les 10 s,
// puis la plus longue interruption : l'écart maximal entre deux écritures confirmées.
const duree = Number(process.env.DUREE || 120);
const coll = db.getSiblingDB("BD511").ecritures;
const heure = () => new Date().toTimeString().slice(0, 8);
let ok = 0, erreurs = 0, n = 0, dernierOk = Date.now(), interruption = 0;
const fin = Date.now() + duree * 1000;
let prochainPoint = Date.now() + 10000;
print(`${heure()}  début : une insertion toutes les 100 ms pendant ${duree} s`);
while (Date.now() < fin) {
  const debut = Date.now();
  try {
    coll.insertOne({ n: ++n, t: new Date() });
    ok++;
    interruption = Math.max(interruption, Date.now() - dernierOk);
    dernierOk = Date.now();
    if (Date.now() - debut >= 1000) print(`${heure()}  écriture n°${n} confirmée après ${Date.now() - debut} ms`);
  } catch (e) {
    erreurs++;
    print(`${heure()}  écriture n°${n} en erreur après ${Date.now() - debut} ms : ${e.codeName || e.name}`);
  }
  if (Date.now() >= prochainPoint) {
    print(`${heure()}  ${ok} écritures confirmées, ${erreurs} en erreur`);
    prochainPoint = Date.now() + 10000;
  }
  sleep(Math.max(0, 100 - (Date.now() - debut)));
}
print(`${heure()}  fin : ${ok} écritures confirmées, ${erreurs} en erreur, plus longue interruption ${(interruption / 1000).toFixed(1)} s`);
EOF
```

### 4.2 Provoquer la panne franche du primaire

Lancez l'application dans le terminal 3 :

```bash
DUREE=90 ~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/ecrivain.js
```

Une dizaine de secondes plus tard, dans le **terminal 1**, « débranchez » le primaire : `docker compose kill` envoie le signal `SIGKILL`, qui tue `mongod` instantanément, comme une coupure de courant ou un plantage de la machine.

```bash
cd ~/BD511/cluster
docker compose kill rs11
```

Résultat attendu dans le terminal 1 :

```text
[+] kill 1/1
 ✔ Container rs11 Killed                                                      0.1s
```

Observez le terminal 2 (heures variables) :

```text
14:21:12  terme 1  rs11:injoignable  rs12:SECONDARY  rs1arb:ARBITER   (vu par rs12)
14:21:23  terme 2  rs11:injoignable  rs12:PRIMARY  rs1arb:ARBITER   (vu par rs12)
```

Puis le terminal 3, à la fin des 90 secondes (heures et numéros variables) :

```text
14:21:02  début : une insertion toutes les 100 ms pendant 90 s
14:21:12  101 écritures confirmées, 0 en erreur
14:21:23  écriture n°103 confirmée après 10981 ms
14:21:23  103 écritures confirmées, 0 en erreur
14:21:32  194 écritures confirmées, 0 en erreur
14:21:42  294 écritures confirmées, 0 en erreur
14:21:52  393 écritures confirmées, 0 en erreur
14:22:02  493 écritures confirmées, 0 en erreur
14:22:12  593 écritures confirmées, 0 en erreur
14:22:22  693 écritures confirmées, 0 en erreur
14:22:32  fin : 789 écritures confirmées, 0 en erreur, plus longue interruption 11.0 s
```

Ce qui s'est passé :

1. `rs12` et l'arbitre constatent immédiatement que `rs11` ne répond plus (`injoignable`) ;
2. pendant **10 secondes** (`electionTimeoutMillis`), ils attendent un éventuel retour du primaire ;
3. `rs12` se présente à l'élection, obtient sa propre voix et celle de l'arbitre (2 sur 3) et devient **primaire** au terme 2 ;
4. côté application, l'écriture en cours a attendu environ **11 secondes**, puis a **réussi** : le driver a automatiquement rejoué l'écriture sur le nouveau primaire (*retryable writes*, actif par défaut). Aucune erreur n'est remontée à l'application, seulement un ralentissement.

### 4.3 Lire l'élection dans les journaux et les métriques

Le journal du nouveau primaire raconte l'élection (terminal 1) :

```bash
cd ~/BD511/cluster
docker compose logs --no-log-prefix rs12 | jq -c 'select(.id == 21216 or .c == "ELECTION" or .id == 21358 or .id == 21331)
  | {heure: .t["$date"][11:23], msg, membre: .attr.hostAndPort, de: .attr.from, vote: .attr.vote, terme: (.attr.term // .attr.newTerm), etat: .attr.newState}
  | with_entries(select(.value != null))'
```

Résultat attendu (heures variables) :

```text
{"heure":"14:19:56.861","msg":"Replica set state transition","etat":"STARTUP2"}
{"heure":"14:19:57.978","msg":"Replica set state transition","etat":"RECOVERING"}
{"heure":"14:19:57.979","msg":"Replica set state transition","etat":"SECONDARY"}
{"heure":"14:20:07.150","msg":"Responding to vote request"}
{"heure":"14:20:07.153","msg":"Responding to vote request"}
{"heure":"14:21:12.381","msg":"Member is now in state DOWN","membre":"rs11:27011"}
{"heure":"14:21:23.236","msg":"Starting an election, since we've seen no PRIMARY in election timeout period"}
{"heure":"14:21:23.236","msg":"Conducting a dry run election to see if we could be elected"}
{"heure":"14:21:23.237","msg":"VoteRequester processResponse","de":"rs1arb:27013","vote":"yes","terme":1}
{"heure":"14:21:23.237","msg":"Dry election run succeeded, running for election","terme":2}
{"heure":"14:21:23.238","msg":"Storing last vote document in local storage for my election"}
{"heure":"14:21:23.241","msg":"VoteRequester processResponse","de":"rs11:27011","terme":2}
{"heure":"14:21:23.242","msg":"VoteRequester processResponse","de":"rs1arb:27013","vote":"yes","terme":2}
{"heure":"14:21:23.242","msg":"Election succeeded, assuming primary role","terme":2}
{"heure":"14:21:23.242","msg":"Replica set state transition","etat":"PRIMARY"}
{"heure":"14:21:23.258","msg":"Transition to primary complete; database writes are now permitted","terme":2}
```

Le journal retrace toute la vie de `rs12` :

- à l'initialisation (partie 3.2), il est passé par la synchronisation initiale (`STARTUP2`, `RECOVERING`) avant de devenir `SECONDARY`, puis il a voté pour `rs11` lors de la toute première élection (*Responding to vote request*) ;
- à la panne, il constate la disparition de `rs11` (*state DOWN*) et attend 10 secondes ;
- l'élection se déroule en deux tours : un **tour d'essai** (*dry run*), qui vérifie que le candidat peut gagner sans incrémenter le terme, puis l'élection réelle au terme 2. La demande de vote adressée à `rs11` reste sans réponse ; le vote de l'arbitre suffit.

Les métriques de l'élection sont aussi conservées par les membres. Côté candidat, avec le compte `admin` :

```bash
~/BD511/ch06/mongosh-rs1 --quiet --eval '
  const m = rs.status().electionCandidateMetrics;
  printjson({ raison: m.lastElectionReason, terme: m.electionTerm, votesNecessaires: m.numVotesNeeded,
              priorite: m.priorityAtElection, delaiElection: m.electionTimeoutMillis,
              majoriteEcritureDisponible: m.wMajorityWriteAvailabilityDate ?? "non" })'
```

Résultat attendu :

```text
{
  raison: 'electionTimeout',
  terme: Long('2'),
  votesNecessaires: 2,
  priorite: 1,
  delaiElection: Long('10000'),
  majoriteEcritureDisponible: 'non'
}
```

`majoriteEcritureDisponible: 'non'` : le nouveau primaire est élu, mais il est le **seul** membre porteur de données disponible. Les écritures `w: "majority"` ne peuvent pas être confirmées tant que `rs11` est absent : c'est la faiblesse du modèle PSA, étudiée en partie 5.

Côté votant, sur l'arbitre (par l'exception localhost, la seule façon de s'y connecter) :

```bash
cd ~/BD511/cluster
docker compose exec -T rs1arb mongosh --port 27013 --quiet --eval '
  const m = rs.status().electionParticipantMetrics;
  printjson({ aVote: m.votedForCandidate, terme: m.electionTerm, candidat: m.electionCandidateMemberId })'
```

Résultat attendu :

```text
{
  aVote: true,
  terme: Long('2'),
  candidat: 1
}
```

L'arbitre a voté pour le membre d'identifiant 1, `rs12`.

### 4.4 Remettre l'ancien primaire en service

Redémarrez `rs11` (terminal 1) :

```bash
cd ~/BD511/cluster
docker compose start rs11
```

Résultat attendu :

```text
[+] start 1/1
 ✔ Container rs11 Started                                                     0.2s
```

Observez le terminal 2 (heures variables) :

```text
14:23:40  terme 2  rs11:SECONDARY  rs12:PRIMARY  rs1arb:ARBITER   (vu par rs12)
14:23:51  terme 3  rs11:PRIMARY  rs12:SECONDARY  rs1arb:ARBITER   (vu par rs12)
```

`rs11` revient d'abord comme **secondaire** : il rattrape les écritures faites pendant son absence en lisant l'oplog de `rs12`. Une fois à jour, comme sa priorité (2) dépasse celle du primaire (1), il provoque une nouvelle élection et reprend le rôle de primaire au terme 3, une dizaine de secondes après son redémarrage.

Pour ne pas enchaîner trop tôt, créez un petit script qui interroge le replica set toutes les 2 secondes jusqu'à ce qu'un primaire soit élu (ou, si on le précise, jusqu'à ce qu'un membre donné soit primaire) ; il resservira en partie 5. Attendez avec lui le retour de `rs11` comme primaire, puis consultez les métriques de cette nouvelle élection :

```bash
cat > ~/BD511/ch06/attendre-primaire.sh <<'EOF'
#!/usr/bin/env bash
# attendre-primaire.sh - BD511 ch.6 : attend qu'un primaire soit élu dans RS1 (90 s au plus) et l'affiche
# Usage : bash ~/BD511/ch06/attendre-primaire.sh [membre]   ex. : attendre-primaire.sh rs11:27011
# Avec un membre en argument, attend que ce membre précis soit le primaire.
cible=${1:-}
for i in $(seq 1 45); do
  p=$("$HOME/BD511/ch06/mongosh-rs1" --quiet --eval 'print(db.hello().primary || "")' 2>/dev/null)
  if [[ -n $p && ( -z $cible || $p == "$cible" ) ]]; then echo "$(date +%T)  primaire : $p"; exit 0; fi
  sleep 2
done
echo "$(date +%T)  pas de primaire${cible:+ $cible} après 90 s" >&2
exit 1
EOF
bash ~/BD511/ch06/attendre-primaire.sh rs11:27011
~/BD511/ch06/mongosh-rs1 --quiet --eval 'const m = rs.status().electionCandidateMetrics; print(db.hello().primary, m.lastElectionReason, m.electionTerm)'
```

Résultat attendu (heure variable) :

```text
14:23:51  primaire : rs11:27011
rs11:27011 priorityTakeover Long('3')
```

`priorityTakeover` : l'élection a été déclenchée par `rs11` parce qu'il est prioritaire, et non par une panne.

> **En production**, cette reprise automatique par priorité est à double tranchant : elle provoque une seconde bascule, donc une seconde courte interruption des écritures. On réserve les priorités différentes aux cas où un membre doit être préféré (meilleur matériel, centre de données principal).

### 4.5 Faire une bascule planifiée

Pour une maintenance (mise à jour, redémarrage de la machine), on ne coupe pas le primaire : on lui demande de **céder sa place** avec `rs.stepDown()`. Relancez l'application dans le terminal 3 :

```bash
DUREE=90 ~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/ecrivain.js
```

Puis, dans le terminal 1 :

```bash
~/BD511/ch06/mongosh-rs1 --quiet --eval 'printjson(rs.stepDown(60))'
sleep 3
~/BD511/ch06/mongosh-rs1 --quiet --eval 'print(db.hello().primary, rs.status().electionCandidateMetrics.lastElectionReason)'
```

Résultat attendu :

```text
{
  ok: 1
}
rs12:27012 stepUpRequestSkipDryRun
```

`rs.stepDown(60)` interdit à `rs11` de redevenir primaire pendant 60 secondes. Avant de céder, `rs11` attend qu'un secondaire soit à jour, puis lui demande de se présenter immédiatement (`stepUpRequestSkipDryRun`) : il n'y a pas de délai de détection de 10 secondes. Terminal 2 :

```text
14:25:10  terme 4  rs11:SECONDARY  rs12:PRIMARY  rs1arb:ARBITER   (vu par rs11)
14:26:21  terme 5  rs11:PRIMARY  rs12:SECONDARY  rs1arb:ARBITER   (vu par rs12)
```

Passé le délai de 60 secondes, `rs11` reprend la main par priorité. Terminal 3, à la fin (heure et valeurs variables) :

```text
14:26:31  fin : 897 écritures confirmées, 0 en erreur, plus longue interruption 0.2 s
```

Comparez les deux bascules :

| | Panne franche (`kill`) | Bascule planifiée (`rs.stepDown()`) |
| --- | --- | --- |
| Détection | 10 s sans primaire (`electionTimeoutMillis`) | aucune : le primaire passe la main |
| Interruption des écritures | ≈ 11 s | < 1 s |
| Erreurs côté application | aucune (écriture rejouée par le driver) | aucune |
| Raison de l'élection | `electionTimeout` | `stepUpRequestSkipDryRun` |

> `docker compose stop` (arrêt propre par `SIGTERM`) se comporte comme une bascule planifiée : `mongod` cède son rôle de primaire avant de s'arrêter, d'où le délai d'arrêt de 1 minute prévu dans le fichier Compose.

Arrêtez la surveillance du terminal 2 si elle tourne encore (`Ctrl` + `C`).

---

## Partie 5 – Write concern

Le **write concern** est le niveau d'accusé de réception qu'un client demande pour une écriture :

| Write concern | L'écriture est confirmée quand… |
| --- | --- |
| `{ w: 0 }` | jamais : le client n'attend aucune réponse |
| `{ w: 1 }` | le primaire l'a appliquée en mémoire |
| `{ w: 1, j: true }` | le primaire l'a aussi écrite dans son journal sur disque |
| `{ w: "majority" }` | une **majorité de membres porteurs de données votants** l'a appliquée (et journalisée) |
| `{ w: <n> }` | `n` membres porteurs de données l'ont appliquée |
| `wtimeout: <ms>` | délai maximal d'attente de cet accusé de réception |

### 5.1 Le write concern par défaut de RS1

Depuis MongoDB 5.0, le write concern par défaut est `{ w: "majority" }`, **sauf** dans un replica set avec arbitre où les membres porteurs de données ne sont pas plus nombreux que la majorité des votants. La règle (*implicit default write concern*) :

```text
si (nombre d'arbitres > 0) ET (membres non arbitres <= majorité des votants)
    write concern par défaut = { w: 1 }
sinon
    write concern par défaut = { w: "majority" }
```

Pour RS1 : 3 votants, majorité = 2 ; 2 membres non arbitres ≤ 2 → le défaut est **`{ w: 1 }`**. Vérifiez les compteurs du replica set (terminal 1) :

```bash
~/BD511/ch06/mongosh-rs1 --quiet --eval '
  const s = rs.status();
  printjson({ votants: s.votingMembersCount, majoriteDesVotes: s.majorityVoteCount,
              votantsPorteursDeDonnees: s.writableVotingMembersCount, majoriteEcriture: s.writeMajorityCount })
  db.adminCommand({ getDefaultRWConcern: 1 })'
```

Résultat attendu :

```text
{
  votants: 3,
  majoriteDesVotes: 2,
  votantsPorteursDeDonnees: 2,
  majoriteEcriture: 2
}
MongoServerError: 'getDefaultRWConcern' is not supported on shard nodes.
```

`writeMajorityCount: 2` : une écriture `majority` doit être confirmée par **les deux** membres porteurs de données. Il n'y a aucune marge.

La commande `getDefaultRWConcern` est refusée : RS1 est démarré avec `--shardsvr`, et le write concern par défaut d'un cluster shardé se règle sur les routeurs `mongos` (chapitre 7 ; l'ajout d'un shard avec arbitre l'exigera même). D'ici là, RS1 applique le défaut implicite `{ w: 1 }` : la partie 5.3 le montre. Bonne pratique dans tous les cas : l'application **demande explicitement** le write concern dont elle a besoin, par exemple `w=majority` dans son URI de connexion.

### 5.2 Tester les write concerns, tous les membres disponibles

Le script suivant fait une insertion par write concern, mesure sa durée, puis vérifie si le document est présent sur le primaire :

```bash
cat > ~/BD511/ch06/tester-wc.js <<'EOF'
// tester-wc.js - BD511 ch.6 : une insertion par write concern, avec sa durée et son résultat
// Usage : ~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/tester-wc.js
// wtimeout borne l'attente à 3 s ; on vérifie ensuite si le document a bien été écrit sur le primaire.
const coll = db.getSiblingDB("BD511").tests_wc;
const essais = [
  { w: 0 },
  { w: 1 },
  { w: 1, j: true },
  { w: "majority", wtimeout: 3000 },
  { w: 2, wtimeout: 3000 },
  { w: 3, wtimeout: 3000 },
];
print(`Primaire : ${db.hello().primary}`);
print("writeConcern".padEnd(36) + "durée".padStart(8) + "  résultat".padEnd(40) + "écrit sur le primaire ?");
for (const wc of essais) {
  const id = new ObjectId();
  const debut = Date.now();
  let resultat;
  try {
    const r = coll.insertOne({ _id: id, wc, t: new Date() }, { writeConcern: wc });
    resultat = r.acknowledged ? "acquittée" : "non acquittée (w: 0)";
  } catch (e) {
    resultat = `erreur ${e.codeName || e.code}`;
  }
  const duree = `${Date.now() - debut} ms`;
  sleep(200);   // laisse aboutir l'écriture w: 0, qui n'attend aucune réponse
  const present = coll.findOne({ _id: id }) ? "oui" : "non";
  print(EJSON.stringify(wc).padEnd(36) + duree.padStart(8) + `  ${resultat}`.padEnd(40) + present);
}
EOF
~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/tester-wc.js
```

Résultat attendu (durées variables, de l'ordre de quelques millisecondes) :

```text
Primaire : rs11:27011
writeConcern                           durée  résultat                              écrit sur le primaire ?
{"w":0}                                 3 ms  non acquittée (w: 0)                  oui
{"w":1}                                 4 ms  acquittée                             oui
{"w":1,"j":true}                        3 ms  acquittée                             oui
{"w":"majority","wtimeout":3000}        4 ms  acquittée                             oui
{"w":2,"wtimeout":3000}                 3 ms  acquittée                             oui
{"w":3,"wtimeout":3000}                 2 ms  erreur UnsatisfiableWriteConcern      oui
```

- `w: 0` : le client ne sait rien du sort de son écriture (elle a abouti ici, mais une erreur serait passée inaperçue) ;
- `w: "majority"` et `w: 2` sont équivalents dans RS1, et rapides quand le secondaire suit ;
- `w: 3` est **impossible** : l'arbitre ne compte pas, il n'y a que 2 membres porteurs de données. Le serveur répond aussitôt par une erreur… mais l'écriture a **quand même été faite** sur le primaire. Une erreur de write concern ne dit pas que l'écriture a échoué, seulement que **l'accusé de réception demandé** n'a pas pu être donné.

### 5.3 Tester les write concerns avec le secondaire arrêté

Arrêtez proprement le secondaire `rs12` (environ 15 secondes : `mongod` attend la fin des opérations en cours) :

```bash
cd ~/BD511/cluster
docker compose stop rs12
~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/tester-wc.js
```

Résultat attendu (durées variables) :

```text
[+] stop 1/1
 ✔ Container rs12 Stopped                                                    15.4s
Primaire : rs11:27011
writeConcern                           durée  résultat                              écrit sur le primaire ?
{"w":0}                                 7 ms  non acquittée (w: 0)                  oui
{"w":1}                                 6 ms  acquittée                             oui
{"w":1,"j":true}                        3 ms  acquittée                             oui
{"w":"majority","wtimeout":3000}     3011 ms  erreur WriteConcernTimeout            oui
{"w":2,"wtimeout":3000}              3010 ms  erreur WriteConcernTimeout            oui
{"w":3,"wtimeout":3000}                 1 ms  erreur UnsatisfiableWriteConcern      oui
```

`rs11` reste primaire : avec l'arbitre, il dispose de 2 voix sur 3. Mais il est le seul membre porteur de données :

- les écritures `w: 1` (le défaut implicite de RS1) continuent sans le moindre signal d'alerte ;
- les écritures `w: "majority"` attendent un secondaire qui ne viendra pas : sans `wtimeout`, elles **bloqueraient indéfiniment** ; avec `wtimeout`, elles échouent au bout de 3 secondes, **alors que le document est écrit** sur le primaire. L'application doit traiter ce cas comme « résultat incertain » (relecture, écriture idempotente).

Le **point de validation majoritaire** (*majority commit point*) ne progresse plus : comparez la dernière écriture appliquée et la dernière écriture majoritaire.

```bash
~/BD511/ch06/mongosh-rs1 --quiet --eval '
  const o = rs.status().optimes;
  printjson({ derniereEcritureAppliquee: o.lastAppliedWallTime, derniereEcritureMajoritaire: o.lastCommittedWallTime })'
```

Résultat attendu (dates variables ; la seconde est figée à l'arrêt de `rs12`) :

```text
{
  derniereEcritureAppliquee: ISODate('2026-10-23T12:28:42.311Z'),
  derniereEcritureMajoritaire: ISODate('2026-10-23T12:28:19.874Z')
}
```

Tant que ce point est figé, chaque `mongod` doit conserver en cache l'historique des modifications non majoritaires : dans un replica set PSA, l'absence prolongée d'un membre porteur de données finit par saturer le cache de WiredTiger. La procédure documentée consiste alors à retirer temporairement le vote du membre absent (`rs.reconfig()` avec `votes: 0` et `priority: 0`), puis à le lui rendre avec `rs.reconfigForPSASet()` une fois le membre rétabli et à jour.

### 5.4 Ce que `w: 1` ne garantit pas : le rollback

`rs12` est toujours arrêté. Une application enregistre cinq commandes avec `w: 1` ; le primaire les confirme toutes.

```bash
~/BD511/ch06/mongosh-rs1 --compte appli --quiet --eval '
  for (let i = 1; i <= 5; i++) {
    const r = db.commandes.insertOne({ _id: "A" + i, montant: 100 * i, ecrite_sur: db.hello().me }, { writeConcern: { w: 1 } });
    print(r.insertedId, "confirmée :", r.acknowledged);
  }'
```

Résultat attendu :

```text
A1 confirmée : true
A2 confirmée : true
A3 confirmée : true
A4 confirmée : true
A5 confirmée : true
```

Le primaire tombe en panne avant d'avoir pu répliquer ces écritures, puis `rs12` redémarre. Avec l'arbitre, il forme une majorité de votants et se fait élire, **sans** ces cinq commandes :

```bash
cd ~/BD511/cluster
docker compose kill rs11
docker compose start rs12
bash ~/BD511/ch06/attendre-primaire.sh
```

Résultat attendu (heure variable, environ 15 secondes plus tard) :

```text
[+] kill 1/1
 ✔ Container rs11 Killed                                                      0.1s
[+] start 1/1
 ✔ Container rs12 Started                                                     0.2s
14:30:27  primaire : rs12:27012
```

L'activité reprend sur le nouveau primaire : trois nouvelles commandes, puis la liste des commandes connues.

```bash
~/BD511/ch06/mongosh-rs1 --compte appli --quiet --eval '
  for (let i = 1; i <= 3; i++) db.commandes.insertOne({ _id: "B" + i, montant: 10 * i, ecrite_sur: db.hello().me });
  print(db.commandes.find().sort({ _id: 1 }).toArray().map(c => c._id).join(" "))'
```

Résultat attendu :

```text
B1 B2 B3
```

Remettez `rs11` en service, attendez qu'il ait repris le rôle de primaire, puis relisez les commandes :

```bash
cd ~/BD511/cluster
docker compose start rs11
bash ~/BD511/ch06/attendre-primaire.sh rs11:27011
~/BD511/ch06/mongosh-rs1 --compte appli --quiet --eval 'print(db.commandes.find().sort({ _id: 1 }).toArray().map(c => c._id).join(" "))'
```

Résultat attendu (heure variable, 15 à 30 secondes plus tard) :

```text
[+] start 1/1
 ✔ Container rs11 Started                                                     0.2s
14:31:05  primaire : rs11:27011
B1 B2 B3
```

Les commandes A1 à A5, **confirmées** à l'application, ont disparu. À son retour, `rs11` a constaté que son historique divergeait de celui du primaire `rs12` : il a annulé ses écritures non répliquées (**rollback**) avant de se resynchroniser, puis de reprendre le rôle de primaire. Le journal de `rs11` le détaille :

```bash
cd ~/BD511/cluster
docker compose logs --no-log-prefix rs11 | jq -c 'select(.c == "ROLLBACK" and (.id == 21593 or .id == 6984700 or .id == 21609 or .id == 21592))
  | {msg, collection: .attr.namespace, fichier: .attr.file, annulees: .attr.insert}
  | with_entries(select(.value != null))'
```

Résultat attendu (horodatages des fichiers et identifiants variables ; l'ordre des deux lignes *Preparing to write…* peut être inversé) :

```text
{"msg":"Transition to ROLLBACK"}
{"msg":"Preparing to write deleted documents to a rollback file","collection":"BD511.tests_wc","fichier":"/data/db/rollback/10c4ce6d-1b4b-48c2-b5af-f22102860509/removed.2026-10-23T14-30-41.1.bson"}
{"msg":"Preparing to write deleted documents to a rollback file","collection":"BD511.commandes","fichier":"/data/db/rollback/05db54d2-73f4-4119-a206-1d32354702d8/removed.2026-10-23T14-30-41.2.bson"}
{"msg":"Operations reverted by rollback","annulees":11}
{"msg":"Rollback complete"}
```

Onze insertions ont été annulées : les cinq commandes A1 à A5, mais aussi les six documents écrits par `tester-wc.js` pendant l'absence de `rs12` (partie 5.3), y compris ceux des écritures `w: "majority"` signalées en échec… qui avaient bel et bien été appliquées sur `rs11`.

Les documents annulés ne sont pas perdus pour tout le monde : `mongod` les a enregistrés dans des fichiers BSON, un par collection, sous `/data/db/rollback/`. Lisez celui de la collection `commandes` avec `bsondump` :

```bash
cd ~/BD511/cluster
f=$(docker compose logs --no-log-prefix rs11 | jq -r 'select(.id == 21609 and .attr.namespace == "BD511.commandes") | .attr.file' | tail -n 1)
docker compose exec -T rs11 bsondump --quiet "$f" | sort
```

Résultat attendu :

```text
{"_id":"A1","montant":{"$numberInt":"100"},"ecrite_sur":"rs11:27011"}
{"_id":"A2","montant":{"$numberInt":"200"},"ecrite_sur":"rs11:27011"}
{"_id":"A3","montant":{"$numberInt":"300"},"ecrite_sur":"rs11:27011"}
{"_id":"A4","montant":{"$numberInt":"400"},"ecrite_sur":"rs11:27011"}
{"_id":"A5","montant":{"$numberInt":"500"},"ecrite_sur":"rs11:27011"}
```

MongoDB ne les réintègre jamais automatiquement : c'est à l'équipe applicative d'examiner ces fichiers et de décider quoi rejouer (par exemple avec `mongorestore`), car les données ont pu évoluer entre-temps sur le nouveau primaire.

**La leçon :** une écriture n'est durable dans un replica set que si elle est confirmée par une **majorité** des membres porteurs de données. Avec `w: "majority"`, les commandes A1 à A5 n'auraient pas été confirmées (délai dépassé) : l'application aurait su que leur sort était incertain, au lieu de croire à tort qu'elles étaient enregistrées. Une écriture confirmée en `w: "majority"` est déjà inscrite dans le journal d'une majorité de membres : le futur primaire, élu par une majorité, la possède forcément, et elle ne peut pas être annulée par un rollback (avec le réglage par défaut `writeConcernMajorityJournalDefault: true`).

### 5.5 Vérifier le retour à la normale

```bash
~/BD511/ch06/mongosh-rs1 --quiet --eval 'rs.status().members.forEach(m => print(m.name.padEnd(13), m.stateStr))'
~/BD511/ch06/mongosh-rs1 --compte appli --quiet ~/BD511/ch06/tester-wc.js | grep '"majority"'
```

Résultat attendu :

```text
rs11:27011    PRIMARY
rs12:27012    SECONDARY
rs1arb:27013  ARBITER
{"w":"majority","wtimeout":3000}        4 ms  acquittée                             oui
```

Les deux membres porteurs de données sont de nouveau disponibles : les écritures `majority` sont confirmées en quelques millisecondes.

---

## Partie 6 – Bilan

### 6.1 Contrôle final

```bash
cat > ~/BD511/ch06/verifier-ch06.sh <<'EOF'
#!/usr/bin/env bash
# verifier-ch06.sh - BD511 ch.6 : contrôle final du replica set RS1 déployé sous Docker
# Usage : bash ~/BD511/ch06/verifier-ch06.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
cd "$HOME/BD511/cluster"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Docker et système"
etats=$(docker compose ps --format '{{.Name}}:{{.Health}}' | sort | tr '\n' ' ')
[[ $etats == "rs11:healthy rs12:healthy rs1arb:healthy " ]]; res $? "Conteneurs RS1 en bonne santé : $etats"
[[ $(docker info --format '{{.LiveRestoreEnabled}}') == true ]]; res $? "Démon Docker : live-restore actif"
[[ $(docker inspect rs11 --format '{{.HostConfig.LogConfig.Config}}') == *"max-size:50m"* ]]; res $? "Rotation des journaux Docker (max-size 50m)"
findmnt -n -t xfs -O noatime /srv/BD511 >/dev/null; res $? "Données sur volume XFS monté en noatime : /srv/BD511"
[[ $(stat -c '%a %u' secrets/keyfile) == "400 999" ]]; res $? "Fichier de clé : mode 400, propriétaire uid 999"

echo "== Replica set RS1"
etat=$("$HOME/BD511/ch06/mongosh-rs1" --quiet --eval '
  const s = rs.status(), c = rs.conf();
  print(s.members.map(m => `${m.name}=${m.stateStr}/${c.members.find(x => x.host === m.name).priority}`).join(" "))' 2>/dev/null)
[[ $etat == "rs11:27011=PRIMARY/2 rs12:27012=SECONDARY/1 rs1arb:27013=ARBITER/0" ]]; res $? "Membres et priorités : $etat"
mongosh --quiet "mongodb://rs11:27011/?directConnection=true&appName=BD511-verif" --eval 'db.adminCommand({ listDatabases: 1 })' 2>&1 | grep -q "requires authentication"
res $? "Accès anonyme refusé (contrôle d'accès actif)"
comptes=$("$HOME/BD511/ch06/mongosh-rs1" --quiet --eval 'print(db.getSiblingDB("admin").getUsers().users.map(u => u.user + ":" + u.roles.map(r => r.role + "@" + r.db).join(",")).sort().join(" "))' 2>/dev/null)
[[ $comptes == "admin:root@admin appli:readWrite@BD511" ]]; res $? "Comptes : $comptes"
n=$("$HOME/BD511/ch06/mongosh-rs1" --compte appli --quiet --eval '
  db.getMongo().setReadPref("secondary");
  print(["formations", "inscriptions", "stagiaires"].map(c => db.getCollection(c).countDocuments()).join("/"))' 2>/dev/null)
[[ $n == "24/1202/300" ]]; res $? "Données répliquées, lues sur le secondaire : $n"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch06/verifier-ch06.sh
```

Résultat attendu :

```text
== Docker et système
  [OK] Conteneurs RS1 en bonne santé : rs11:healthy rs12:healthy rs1arb:healthy 
  [OK] Démon Docker : live-restore actif
  [OK] Rotation des journaux Docker (max-size 50m)
  [OK] Données sur volume XFS monté en noatime : /srv/BD511
  [OK] Fichier de clé : mode 400, propriétaire uid 999
== Replica set RS1
  [OK] Membres et priorités : rs11:27011=PRIMARY/2 rs12:27012=SECONDARY/1 rs1arb:27013=ARBITER/0
  [OK] Accès anonyme refusé (contrôle d'accès actif)
  [OK] Comptes : admin:root@admin appli:readWrite@BD511
  [OK] Données répliquées, lues sur le secondaire : 24/1202/300

Bilan : 9 OK, 0 KO
```

Le replica set RS1 reste en place pour le chapitre 7, qui le transformera en shard. Les conteneurs redémarrent seuls avec la VM (`restart: unless-stopped`) ; pour les arrêter ou les relancer, voir l'annexe C.

### 6.2 Ce qu'il faut retenir

- **Un replica set** est un groupe de `mongod` qui détiennent les mêmes données : un **primaire** reçoit les écritures et les inscrit dans son **oplog**, que les **secondaires** rejouent. Un **arbitre** vote sans stocker de données.
- **Les applications se connectent au replica set** (URI avec `replicaSet=` et plusieurs membres) : le driver suit le primaire, rejoue une écriture interrompue par une bascule (*retryable writes*) et peut lire sur les secondaires (*read preference*).
- **Une élection** exige la majorité des votants (2 sur 3 ici) : un nombre impair de votants, répartis sur des machines indépendantes, est indispensable. Panne franche : ≈ 10 à 12 s sans primaire ; bascule planifiée (`rs.stepDown()`) : moins d'une seconde.
- **Le fichier de clé** authentifie les membres entre eux et active le contrôle d'accès ; le premier compte se crée par l'exception localhost, qui se referme aussitôt. En production, MongoDB recommande les certificats x.509.
- **Le write concern** fixe ce qu'un accusé de réception garantit. Une erreur de write concern ne veut pas dire que l'écriture n'a pas eu lieu. Seul `w: "majority"` protège contre le **rollback** ; il faut l'accompagner d'un `wtimeout`.
- **PSA est fragile** : défaut implicite `w: 1`, écritures majoritaires impossibles dès qu'un membre porteur de données manque, point de validation majoritaire figé. En production, préférez trois membres porteurs de données (PSS).

### 6.3 Récapitulatif des bonnes pratiques de production appliquées

| Domaine | Réglage ou pratique | Partie |
| --- | --- | --- |
| Système | réglages du chapitre 2 (THP, `swappiness`…) valables pour tous les conteneurs : ils partagent le noyau | 0.2 |
| Horloge | synchronisation NTP vérifiée | 0.3 |
| Docker | dépôt officiel, rotation des journaux, `live-restore`, démarrage conditionné au montage du volume | 1, 2.2 |
| Image | image officielle à la version exacte (`mongo:8.3.13`), jamais `latest` | 1.4, 2.6 |
| Stockage | volume XFS dédié monté en `noatime`, un répertoire par membre, propriétaire uid 999, droits 750 | 2.2 |
| Nommage | membres désignés par des noms d'hôtes, pas par des adresses IP | 2.3, 3.2 |
| Sécurité | fichier de clé (mode 400, uid 999), contrôle d'accès, comptes `root` et applicatif distincts, mots de passe jamais en ligne de commande | 2.4, 3.3, 3.5 |
| Ressources | cache WiredTiger borné, plafond mémoire par conteneur, limites `nofile` et `nproc` à 64 000 | 2.5, 2.6 |
| Réseau | écoute sur l'interface locale et l'adresse du réseau privé uniquement, aucun port publié | 2.6 |
| Disponibilité | redémarrage automatique, arrêt propre (délai de 1 min), vérification de santé | 2.6 |
| Réplication | oplog dimensionné et surveillé (fenêtre), retard de réplication suivi | 2.5, 3.6 |
| Exploitation | maintenance par `rs.stepDown()` plutôt que par arrêt brutal | 4.5 |
| Écritures | write concern explicite côté application, `w: "majority"` avec `wtimeout`, écritures rejouables | 5 |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `00-prerequis.sh` : espace disque insuffisant | disque de la VM trop petit | agrandissez le disque virtuel dans l'hyperviseur, puis la partition et le système de fichiers (`sudo growpart /dev/sda 2 && sudo resize2fs /dev/sda2`, selon votre partitionnement) |
| `00-prerequis.sh` : plage 192.168.100.0/24 déjà utilisée | un réseau de la VM (ou de l'hyperviseur) utilise déjà cette plage | changez le réseau de la VM, ou adaptez la plage dans `architecture.tsv`, `docker-compose.yml` et `/etc/hosts` |
| `docker compose up` : `Pool overlaps with other one on this address space` | idem | idem |
| Un conteneur redémarre en boucle ; journal : `permissions on /etc/mongo/keyfile are too open` | fichier de clé lisible par le groupe ou les autres | `chmod 400 secrets/keyfile && sudo chown 999:999 secrets/keyfile`, puis `docker compose up -d` |
| Journal : `Unable to acquire security key[s]` ou `Error reading file /etc/mongo/keyfile` | fichier de clé absent ou illisible par l'uid 999 | refaites la partie 2.4 |
| Journal : `Unable to create/open the lock file` ou `Permission denied` sur `/data/db` | répertoire de données qui n'appartient pas à l'uid 999 | `sudo chown -R 999:999 /srv/BD511/<membre>` |
| Les conteneurs ne démarrent pas après un redémarrage de la VM | volume `/srv/BD511` non monté (le démon Docker attend le montage) | `sudo mount /srv/BD511 && sudo systemctl start docker` ; vérifiez la ligne de `/etc/fstab` |
| mongosh : `getaddrinfo ENOTFOUND rs11` | noms des membres absents de `/etc/hosts` | relancez `03-hosts.sh` (partie 2.3) |
| mongosh : `MongoServerSelectionError` | aucun membre joignable ou aucun primaire | `docker compose ps`, puis `bash ~/BD511/ch06/attendre-primaire.sh` |
| `init-rs1.js` : `already initialized` | replica set déjà initialisé | rien à faire ; vérifiez avec `rs.status()` |
| Création des comptes : `command createUser requires authentication` | un utilisateur existe déjà : l'exception localhost est refermée | connectez-vous avec le compte `admin` (`mongosh-rs1`) |
| `MongoServerError: Authentication failed` | mot de passe ou base d'authentification incorrects | les comptes sont dans la base `admin` (`authSource=admin`) ; comparez avec `secrets/*.pwd` |
| `tester-wc.js` : `w: "majority"` bloqué sans fin | `wtimeout` absent et secondaire indisponible | toujours associer `wtimeout` à `w: "majority"` |
| Pas de ligne `ROLLBACK` dans le journal de `rs11` (5.4) | `rs11` redémarré avant que `rs12` soit élu, ou écritures A1 à A5 faites avec `rs12` en service | reprenez la partie 5.3, puis 5.4 dans l'ordre |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `~/BD511/ch06/00-prerequis.sh` | Contrôle de la VM | 0.3 |
| `/etc/docker/daemon.json` | Réglages du démon Docker (journaux, `live-restore`) | 1.2 |
| `/etc/apt/sources.list.d/docker.sources`, `/etc/apt/keyrings/docker.asc` | Dépôt officiel de Docker | 1.1 |
| `~/BD511/cluster/architecture.tsv` | Architecture du cluster (14 processus) | 2.1 |
| `~/BD511/ch06/02-volume-cluster.sh` | Volume XFS `/srv/BD511` et répertoires de données | 2.2 |
| `/var/lib/BD511-cluster-xfs.img`, ligne de `/etc/fstab` | Image du volume XFS et son montage | 2.2 |
| `/etc/systemd/system/docker.service.d/BD511-volume.conf` | Démarrage de Docker conditionné au montage du volume | 2.2 |
| `~/BD511/ch06/03-hosts.sh`, bloc de `/etc/hosts` | Noms des membres pour la VM | 2.3 |
| `~/BD511/cluster/secrets/keyfile` | Fichier de clé du cluster (mode 400, uid 999) | 2.4 |
| `~/BD511/cluster/secrets/admin.pwd`, `appli.pwd` | Mots de passe des comptes (mode 600) | 2.4 |
| `~/BD511/cluster/conf/mongod.conf` | Configuration commune des `mongod` | 2.5 |
| `~/BD511/cluster/docker-compose.yml` | Description des 14 services (RS1 sans profil, le reste en profil `sharding`) | 2.6 |
| `/srv/BD511/<membre>` | Données de chaque `mongod` | 2.7 |
| `~/BD511/ch06/init-rs1.js` | Initialisation du replica set RS1 | 3.2 |
| `~/BD511/ch06/mongosh-rs1` | Connexion au replica set avec le compte `admin` ou `appli` | 3.4 |
| `~/BD511/ch06/donnees/` | Jeu de données du chapitre 3 et `SHA256SUMS` | 3.5 |
| `~/BD511/ch06/importer-rs1.sh` | Import dans RS1 avec le compte `appli` | 3.5 |
| `~/BD511/ch06/surveiller-rs.js` | Surveillance de l'état des membres | 4.1 |
| `~/BD511/ch06/ecrivain.js` | Application qui écrit en continu | 4.1 |
| `~/BD511/ch06/attendre-primaire.sh` | Attente de l'élection d'un primaire (quelconque ou désigné) | 4.4 |
| `~/BD511/ch06/tester-wc.js` | Test des write concerns | 5.2 |
| `~/BD511/ch06/verifier-ch06.sh` | Contrôle final | 6.1 |

## Annexe C – Exploiter le cluster Docker

Toutes ces commandes s'exécutent dans `~/BD511/cluster`.

| Action | Commande |
| --- | --- |
| État des conteneurs | `docker compose ps` |
| Journal d'un membre (JSON) | `docker compose logs --no-log-prefix rs11 \| jq -c '{t: .t["$date"], msg}'` |
| Arrêter RS1 proprement | `docker compose stop` |
| Redémarrer RS1 | `docker compose start` |
| Supprimer les conteneurs (les données restent dans `/srv/BD511`) | `docker compose down` |
| Recréer les conteneurs après une modification du fichier Compose | `docker compose up -d --wait` |

**Remettre RS1 à zéro** (conteneurs et données supprimés, fichiers et comptes de la partie 2 conservés), puis reprendre à la partie 3.2 :

```bash
cd ~/BD511/cluster
docker compose down
sudo find /srv/BD511/rs11 /srv/BD511/rs12 /srv/BD511/rs1arb -mindepth 1 -delete
docker compose up -d --wait
```

## Annexe D – Références

- Docker : [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Docker Engine release notes](https://docs.docker.com/engine/release-notes/), [Compose file reference](https://docs.docker.com/reference/compose-file/), [Live restore](https://docs.docker.com/engine/daemon/live-restore/), [JSON File logging driver](https://docs.docker.com/engine/logging/drivers/json-file/)
- Image : [mongo (Docker Official Image)](https://hub.docker.com/_/mongo), [docker-library/mongo](https://github.com/docker-library/mongo)
- Réplication : [Replication](https://www.mongodb.com/docs/manual/replication/), [Replica Set Elections](https://www.mongodb.com/docs/manual/core/replica-set-elections/), [Replica Set Arbiter](https://www.mongodb.com/docs/manual/core/replica-set-arbiter/), [Rollbacks During Replica Set Failover](https://www.mongodb.com/docs/manual/core/replica-set-rollbacks/), [Replica Set Oplog](https://www.mongodb.com/docs/manual/core/replica-set-oplog/)
- Sécurité : [Deploy Self-Managed Replica Set With Keyfile Authentication](https://www.mongodb.com/docs/manual/tutorial/deploy-replica-set-with-keyfile-access-control/), [Localhost Exception](https://www.mongodb.com/docs/manual/core/localhost-exception/)
- Écritures : [Write Concern](https://www.mongodb.com/docs/manual/reference/write-concern/), [Retryable Writes](https://www.mongodb.com/docs/manual/core/retryable-writes/), [Mitigate Performance Issues with PSA Replica Set](https://www.mongodb.com/docs/manual/tutorial/mitigate-psa-performance-issues/)
- Production : [Production Notes for Self-Managed Deployments](https://www.mongodb.com/docs/manual/administration/production-notes/)
