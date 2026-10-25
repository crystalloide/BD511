# BD511 – Chapitre 7 – Handlab : cluster shardé sous Docker, balancer et méthodes de sharding

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 7 – Sharding |
| **Durée indicative** | 3 h |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop du chapitre 6 (2 vCPU), avec le replica set RS1 en service sous Docker ; **6 Go de RAM** (partie 0.1) ; 2 Go libres sur le volume `/srv/bd511` |
| **Versions vérifiées le 25/10/2026** | MongoDB Community Server **8.3.13** (image Docker officielle `mongo:8.3.13`) · Docker Engine **29.9.2** · Docker Compose **5.6.1** · mongosh **2.13.0** · Database Tools **100.19.1** · Python **3.12** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. déployer un **cluster shardé minimal** : serveurs de configuration en replica set (**RSCFG**), deux shards déployés en replica sets (**RS1**, repris du chapitre 6, et **RS2**), routeur **`mongos`** ;
2. sécuriser ce cluster : fichier de clé commun, comptes du cluster créés par le routeur, comptes locaux des shards, write concern par défaut du cluster ;
3. **sharder une collection** existante, observer la **répartition** des données et le travail du **balancer** (migrations, chunks, documents orphelins) ;
4. comparer **plusieurs méthodes de sharding** (clé à intervalles, clé à intervalles croissante, clé hachée, zones) sur trois critères : répartition des données, répartition des nouvelles écritures, routage des requêtes.

## L'architecture du chapitre

Ce TP démarre les services du profil `sharding` du fichier Docker Compose écrit au chapitre 6, sauf le troisième shard et le second routeur. Le fichier `docker-compose.yml` n'est pas modifié.

| Groupe | Conteneurs (adresse : port) | Rôle | Au début du TP |
| --- | --- | --- | --- |
| RSCFG | `config1` (.101 : 27041), `config2` (.102 : 27042), `config3` (.103 : 27043) | serveurs de configuration (métadonnées du cluster) | à créer |
| RS1 | `rs11` (.111 : 27011), `rs12` (.112 : 27012), `rs1arb` (.113 : 27013) | shard 1 | en service (chapitre 6), avec la base `bd511` |
| RS2 | `rs21` (.121 : 27021), `rs22` (.122 : 27022), `rs2arb` (.123 : 27023) | shard 2 | à créer |
| – | `mongos1` (.141 : 27017) | routeur | à créer |
| RS3, – | `rs31`, `rs32`, `rs3arb`, `mongos2` | troisième shard, second routeur | non utilisés |

```text
                      Applications, mongosh, mongoimport (sur la VM)
                                       │  mongodb://…@mongos1:27017
                         ┌─────────────▼─────────────┐
                         │ mongos1      .141 : 27017 │  routeur : ne stocke rien, envoie chaque
                         │ table de routage en cache │  requête au(x) shard(s) concerné(s)
                         └──┬────────────┬────────┬──┘
            ┌───────────────┘            │        └──────────────────┐
┌───────────▼───────────┐   ┌────────────▼──────────┐   ┌────────────▼──────────┐
│ RSCFG  (métadonnées)  │   │ shard RS1             │   │ shard RS2             │
│ config1  .101 : 27041 │   │ rs11    .111 : 27011  │   │ rs21    .121 : 27021  │
│ config2  .102 : 27042 │   │ rs12    .112 : 27012  │   │ rs22    .122 : 27022  │
│ config3  .103 : 27043 │   │ rs1arb  .113 : 27013  │   │ rs2arb  .123 : 27023  │
│ balancer (primaire)   │   │ données du chapitre 6 │   │                       │
└───────────────────────┘   └───────────────────────┘   └───────────────────────┘
          réseau Docker « bd511 » 192.168.100.0/24 ; fichier de clé commun à tous les processus
```

> **Pourquoi 6 Go de RAM.** Le cluster compte 10 processus MongoDB. Une fois les données chargées, ils occupent environ 2,3 Go : près de 400 Mo pour chacun des quatre membres porteurs de données des shards (cache WiredTiger de 256 Mo compris), environ 150 Mo par serveur de configuration ou arbitre, 60 Mo pour le routeur. Avec l'environnement de bureau d'Ubuntu, 4 Go ne suffisent plus. C'est aussi pourquoi RS3 et `mongos2` restent éteints.

> **Un cluster de démonstration.** En production, chaque membre tourne sur son propre serveur, les shards suivent le modèle PSS (trois membres porteurs de données, sans arbitre) et l'on déploie au moins deux routeurs, souvent un par serveur d'application.

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Mémoire de la VM et contrôle des prérequis | 15 min |
| 1 | Déploiement du cluster : serveurs de configuration, shard RS2, routeur, comptes, ajout des shards | 45 min |
| 2 | Sharding de la collection `ventes` : clé, répartition, balancer, routage | 50 min |
| 3 | Comparaison des méthodes de sharding : intervalles croissants, hachage, zones | 55 min |
| 4 | Arrêt et redémarrage du cluster, bilan | 15 min |

## Conventions

- Toutes les commandes s'exécutent dans un terminal (`Ctrl` + `Alt` + `T`). Les sessions mongosh interactives se quittent avec `exit`.
- Les commandes Docker s'exécutent avec `sudo` depuis le répertoire du projet `~/bd511/cluster`, comme au chapitre 6.
- Les services du cluster sont toujours **nommés** dans les commandes `docker compose` qui démarrent des conteneurs : `--profile sharding` démarrerait aussi RS3 et `mongos2`.
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Les heures, durées, tailles mémoire et identifiants (`ObjectId`, `UUID`, horodatages) varient d'une VM à l'autre. Le jeu de données est généré de façon déterministe : les nombres de documents sont identiques, sauf mention contraire.
- Les fichiers du TP sont générés dans `~/bd511/ch07` ; l'annexe B en donne la liste.

---

## Partie 0 – Préparer la VM

### 0.1 Passer la VM à 6 Go de RAM

Si votre VM dispose déjà d'au moins 6 Go de RAM, passez à la partie 0.2.

Arrêtez proprement le replica set RS1, puis la VM :

```bash
cd ~/bd511/cluster
sudo docker compose stop
sudo poweroff
```

Dans l'hyperviseur, VM arrêtée, portez la mémoire vive à **6144 Mo** (VirtualBox : *Configuration › Système › Carte mère › Mémoire vive* ; VMware : *Edit virtual machine settings › Memory*). Redémarrez la VM, ouvrez un terminal et relancez RS1 :

```bash
cd ~/bd511/cluster
sudo docker compose up -d --wait
bash ~/bd511/ch06/attendre-primaire.sh rs11:27011
free -m | head -n 2
```

Résultat attendu (valeurs variables ; la colonne `total` doit dépasser 5 800 Mo) :

```text
[+] up 3/3
 ✔ Container rs12   Healthy                                                    6.1s
 ✔ Container rs1arb Healthy                                                    6.1s
 ✔ Container rs11   Healthy                                                    6.6s
14:02:31  primaire : rs11:27011
               total        used        free      shared  buff/cache   available
Mem:            5923        2016        3093          41        1081        3907
```

Comme au chapitre 6, `docker compose stop` laisse les conteneurs arrêtés au redémarrage de la VM (`restart: unless-stopped`) : c'est `docker compose up -d` qui les relance. Le script `attendre-primaire.sh` du chapitre 6 attend ensuite que `rs11`, prioritaire, ait repris le rôle de primaire.

### 0.2 Créer l'espace de travail et contrôler les prérequis

Le script suivant vérifie la mémoire disponible, la place libre sur le volume de données, les outils, et l'état du cluster laissé par le chapitre 6 :

```bash
mkdir -p ~/bd511/ch07/donnees
cat > ~/bd511/ch07/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.7 : vérifie que la VM et le replica set RS1 du chapitre 6 sont prêts pour le sharding
# Usage : bash ~/bd511/ch07/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }
CLUSTER="$HOME/bd511/cluster"

echo "== Système"
total=$(awk '/^MemTotal/ {print int($2 / 1024)}' /proc/meminfo)
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 2560 )); then ok "Mémoire disponible : ${dispo} Mo sur ${total} Mo (2 560 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo sur ${total} Mo (2 560 Mo requis) ; passez la VM à 6 Go de RAM (partie 0.1)"; fi
if mountpoint -q /srv/bd511; then
  libre=$(df -BM --output=avail /srv/bd511 | tail -n 1 | tr -dc '0-9')
  if (( libre >= 2048 )); then ok "Volume /srv/bd511 monté : ${libre} Mo libres (2 048 Mo requis)"
  else nok "Volume /srv/bd511 : ${libre} Mo libres (2 048 Mo requis)"; fi
else nok "Volume /srv/bd511 non monté (chapitre 6, partie 2.2) : sudo mount /srv/bd511"; fi
for outil in mongosh mongoimport python3 jq; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done

echo "== Cluster Docker du chapitre 6"
if sudo docker info >/dev/null 2>&1; then ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}') actif"; else nok "Docker inactif : sudo systemctl start docker"; fi
manquants=""
for f in docker-compose.yml conf/mongod.conf secrets/keyfile secrets/admin.pwd secrets/appli.pwd; do
  sudo test -s "$CLUSTER/$f" || manquants+=" $f"
done
if [[ -z $manquants ]]; then ok "Fichiers du cluster présents dans ~/bd511/cluster"; else nok "Fichiers absents de ~/bd511/cluster :$manquants"; fi
noms=$(getent hosts config1 rs21 mongos1 | wc -l)
if (( noms == 3 )); then ok "Noms des membres déclarés dans /etc/hosts"; else nok "Noms absents de /etc/hosts : relancez 03-hosts.sh (chapitre 6, partie 2.3)"; fi
etat=$("$HOME/bd511/ch06/mongosh-rs1" --quiet --eval 'print(rs.status().members.map(m => m.stateStr).sort().join(" "))' 2>/dev/null)
if [[ $etat == "ARBITER PRIMARY SECONDARY" ]]; then ok "Replica set RS1 : un primaire, un secondaire, un arbitre"
else nok "Replica set RS1 indisponible ou dégradé (${etat:-aucune réponse}) : cd ~/bd511/cluster && sudo docker compose up -d --wait"; fi
if [[ -n $(sudo docker ps -aq --filter name='^(config[123]|rs2[12]|rs2arb|mongos1)$') ]]; then
  nok "Des conteneurs du chapitre 7 existent déjà : voir l'annexe C pour repartir de zéro"
else ok "Aucun conteneur du chapitre 7 créé"; fi

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/bd511/ch07/00-prerequis.sh
```

Résultat attendu (mémoire et espace libre variables) :

```text
== Système
  [OK] Mémoire disponible : 3907 Mo sur 5923 Mo (2 560 Mo requis)
  [OK] Volume /srv/bd511 monté : 3314 Mo libres (2 048 Mo requis)
  [OK] mongosh présent
  [OK] mongoimport présent
  [OK] python3 présent
  [OK] jq présent
== Cluster Docker du chapitre 6
  [OK] Docker Engine 29.9.2 actif
  [OK] Fichiers du cluster présents dans ~/bd511/cluster
  [OK] Noms des membres déclarés dans /etc/hosts
  [OK] Replica set RS1 : un primaire, un secondaire, un arbitre
  [OK] Aucun conteneur du chapitre 7 créé

Résultat : VM prête pour le TP.
```

Corrigez chaque ligne `[KO]` avant de continuer (annexe A).

---

## Partie 1 – Déployer le cluster shardé minimal

### 1.1 Les trois composants d'un cluster shardé

| Composant | Rôle | Dans ce TP |
| --- | --- | --- |
| **Shard** | stocke une partie des données de chaque collection shardée, et la totalité des collections non shardées des bases dont il est le *shard primaire* ; c'est un replica set dont les membres sont lancés avec `--shardsvr` | RS1, RS2 |
| **Serveurs de configuration** | stockent les **métadonnées** du cluster (base `config`) : liste des shards, bases et collections shardées, **chunks** (plages de valeurs de la clé de sharding, chacune attribuée à un shard), zones, réglages du balancer ; ils conservent aussi les **comptes du cluster**. C'est un replica set lancé avec `--configsvr`, sans arbitre. Son primaire exécute le **balancer** | RSCFG |
| **Routeur `mongos`** | point d'entrée unique des applications : il reçoit chaque requête, l'envoie au(x) seul(s) shard(s) concerné(s) d'après sa table de routage (copie en cache des métadonnées) et fusionne les résultats. Il ne stocke rien | `mongos1` |

L'ordre de déploiement en découle : les serveurs de configuration d'abord, puis les shards, enfin le routeur, qui a besoin de RSCFG pour démarrer. Tous les processus partagent le **fichier de clé** du chapitre 6 : c'est lui qui authentifie les membres entre eux, quel que soit leur rôle.

### 1.2 Démarrer et initialiser les serveurs de configuration

Démarrez les trois conteneurs de RSCFG :

```bash
cd ~/bd511/cluster
sudo docker compose up -d --wait config1 config2 config3
```

Résultat attendu :

```text
[+] up 3/3
 ✔ Container config1 Healthy                                                   5.6s
 ✔ Container config2 Healthy                                                   5.6s
 ✔ Container config3 Healthy                                                   5.6s
```

Comme pour RS1, on initialise le replica set par l'**exception localhost**, depuis l'intérieur du conteneur `config1`. La configuration porte l'option `configsvr: true`, obligatoire pour un replica set de serveurs de configuration, et trois membres porteurs de données, sans arbitre ni priorité particulière :

```bash
cat > ~/bd511/ch07/init-rscfg.js <<'EOF'
// init-rscfg.js - BD511 ch.7 : initialise le replica set RSCFG des serveurs de configuration
// Exécuté dans le conteneur config1, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/bd511/cluster && sudo docker compose exec -T config1 mongosh --port 27041 --quiet --file /dev/stdin < ~/bd511/ch07/init-rscfg.js
const config = {
  _id: "RSCFG",
  configsvr: true,                 // replica set de serveurs de configuration (lancés avec --configsvr)
  members: [                       // trois membres porteurs de données, sans arbitre (interdit pour RSCFG)
    { _id: 0, host: "config1:27041" },
    { _id: 1, host: "config2:27042" },
    { _id: 2, host: "config3:27043" },
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection d'un primaire et de la synchronisation des secondaires (60 s au plus)
for (let i = 0; i < 60; i++) {
  const etats = rs.status().members.map(m => m.stateStr);
  if (etats.filter(e => e === "PRIMARY").length === 1 && etats.filter(e => e === "SECONDARY").length === 2) break;
  sleep(1000);
}
for (const m of rs.status().members) print(`${m.name.padEnd(14)} ${m.stateStr}`);
EOF
cd ~/bd511/cluster
sudo docker compose exec -T config1 mongosh --port 27041 --quiet --file /dev/stdin < ~/bd511/ch07/init-rscfg.js
```

Résultat attendu (après une dizaine de secondes ; le primaire est en général `config1`) :

```text
{
  ok: 1
}
config1:27041  PRIMARY
config2:27042  SECONDARY
config3:27043  SECONDARY
```

Le replica set RSCFG accueillera la base `config` (métadonnées) et, dans sa base `admin`, les comptes du cluster. MongoDB y écrit toujours avec le write concern `majority` : ces métadonnées ne doivent jamais être perdues par un rollback.

### 1.3 Démarrer et initialiser le shard RS2

RS2 reproduit RS1 : `rs21` (priorité 2), `rs22` (priorité 1) et l'arbitre `rs2arb`, tous lancés avec `--shardsvr` par le fichier Compose.

```bash
cd ~/bd511/cluster
sudo docker compose up -d --wait rs21 rs22 rs2arb
cat > ~/bd511/ch07/init-rs2.js <<'EOF'
// init-rs2.js - BD511 ch.7 : initialise le replica set RS2 (futur shard 2), sur le modèle de RS1
// Exécuté dans le conteneur rs21, par l'interface locale (exception localhost : aucun utilisateur n'existe encore).
// Usage : cd ~/bd511/cluster && sudo docker compose exec -T rs21 mongosh --port 27021 --quiet --file /dev/stdin < ~/bd511/ch07/init-rs2.js
const config = {
  _id: "RS2",
  members: [
    { _id: 0, host: "rs21:27021", priority: 2 },        // primaire de l'architecture : priorité la plus haute
    { _id: 1, host: "rs22:27022", priority: 1 },        // secondaire
    { _id: 2, host: "rs2arb:27023", arbiterOnly: true }, // arbitre : vote, ne stocke pas de données
  ],
};
printjson(rs.initiate(config));

// Attente de l'élection de rs21 comme primaire et de la synchronisation de rs22 (60 s au plus)
for (let i = 0; i < 60; i++) {
  const etats = rs.status().members.map(m => m.stateStr);
  if (db.hello().isWritablePrimary && etats.includes("SECONDARY")) break;
  sleep(1000);
}
for (const m of rs.status().members) print(`${m.name.padEnd(13)} ${m.stateStr}`);
EOF
sudo docker compose exec -T rs21 mongosh --port 27021 --quiet --file /dev/stdin < ~/bd511/ch07/init-rs2.js
```

Résultat attendu :

```text
[+] up 3/3
 ✔ Container rs22   Healthy                                                    5.6s
 ✔ Container rs2arb Healthy                                                    5.6s
 ✔ Container rs21   Healthy                                                    5.6s
{
  ok: 1
}
rs21:27021    PRIMARY
rs22:27022    SECONDARY
rs2arb:27023  ARBITER
```

Créez ensuite l'**administrateur local** du shard, toujours par l'exception localhost, avec le mot de passe du compte `admin` du chapitre 6 :

```bash
cd ~/bd511/cluster
sudo docker compose exec -T rs21 mongosh --port 27021 --quiet --file /dev/stdin <<EOF
const admin = db.getSiblingDB("admin");
admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: [ "root" ] }, { w: "majority", wtimeout: 10000 });
admin.auth("admin", "$(cat secrets/admin.pwd)");
for (const u of admin.getUsers().users) print(u.user, EJSON.stringify(u.roles));
EOF
```

Résultat attendu :

```text
admin [{"role":"root","db":"admin"}]
```

Un cluster shardé a **deux niveaux de comptes** :

- les **comptes du cluster**, créés par le routeur et stockés sur RSCFG : ce sont ceux des applications et des administrateurs (partie 1.4) ;
- les **comptes locaux de chaque shard**, stockés sur le shard lui-même : ils ne servent qu'aux connexions directes au shard, pour la maintenance. Tant qu'un shard n'en a aucun, son exception localhost reste ouverte ; on en crée donc au moins un, comme ici. RS1 possède déjà les siens (`admin` et `appli`, chapitre 6).

### 1.4 Démarrer le routeur et créer les comptes du cluster

Le fichier Compose lance `mongos1` avec le fichier de clé et l'adresse des serveurs de configuration (`--configdb RSCFG/config1:27041,config2:27042,config3:27043`). Démarrez-le :

```bash
cd ~/bd511/cluster
sudo docker compose up -d --wait mongos1
```

Résultat attendu :

```text
[+] up 1/1
 ✔ Container mongos1 Healthy                                                   2.6s
```

Aucun compte n'existe encore sur RSCFG : l'exception localhost s'applique au routeur. Créez par son intermédiaire les deux comptes du cluster, avec les mêmes noms, rôles et mots de passe qu'au chapitre 6 (fichiers `secrets/*.pwd`) :

```bash
cd ~/bd511/cluster
sudo docker compose exec -T mongos1 mongosh --port 27017 --quiet --file /dev/stdin <<EOF
const admin = db.getSiblingDB("admin");
const wc = { w: "majority", wtimeout: 10000 };
admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: [ "root" ] }, wc);
admin.auth("admin", "$(cat secrets/admin.pwd)");
admin.createUser({ user: "appli", pwd: "$(cat secrets/appli.pwd)", roles: [ { role: "readWrite", db: "bd511" } ] }, wc);
for (const u of admin.getUsers().users) print(u.user.padEnd(6), EJSON.stringify(u.roles));
EOF
sudo docker compose exec -T mongos1 mongosh --port 27017 --quiet --eval 'db.adminCommand({ listDatabases: 1 })'
```

Résultat attendu :

```text
admin  [{"role":"root","db":"admin"}]
appli  [{"role":"readWrite","db":"bd511"}]
MongoServerError: Command listDatabases requires authentication
```

Les comptes sont enregistrés sur RSCFG : l'exception localhost est désormais refermée sur le routeur comme sur les serveurs de configuration.

### 1.5 Se connecter au cluster

Les applications se connectent au **routeur**, jamais directement aux shards. Le script suivant ouvre mongosh sur `mongos1` avec le compte `admin` (par défaut) ou `appli`. Pour l'observation, l'option `--cible` permet aussi de se connecter directement à un replica set du cluster : RSCFG avec les comptes du cluster, RS1 ou RS2 avec leurs comptes locaux.

```bash
cat > ~/bd511/ch07/mongosh-cluster <<'EOF'
#!/usr/bin/env bash
# mongosh-cluster - BD511 ch.7 : ouvre mongosh sur le cluster shardé, base bd511
#   - par défaut, par le routeur mongos1 : c'est l'accès normal des applications ;
#   - avec --cible RSCFG, RS1 ou RS2 : directement sur ce replica set, pour l'administration et l'observation.
# Le mot de passe est lu dans ~/bd511/cluster/secrets/<compte>.pwd ; mongosh le masque ensuite
# dans la liste des processus (« mongodb://<credentials>@... »). Compte par défaut : admin.
# Usage : ~/bd511/ch07/mongosh-cluster [--compte appli] [--cible RSCFG|RS1|RS2] [options et scripts mongosh...]
set -euo pipefail
compte=admin; cible=mongos
while [[ ${1:-} == --compte || ${1:-} == --cible ]]; do
  if [[ $1 == --compte ]]; then compte=$2; else cible=$2; fi
  shift 2
done
case $cible in
  mongos) hotes="mongos1:27017"; rs="" ;;
  RSCFG)  hotes="config1:27041,config2:27042,config3:27043"; rs="replicaSet=RSCFG&" ;;
  RS1)    hotes="rs11:27011,rs12:27012"; rs="replicaSet=RS1&" ;;
  RS2)    hotes="rs21:27021,rs22:27022"; rs="replicaSet=RS2&" ;;
  *) echo "Cible inconnue : $cible (RSCFG, RS1 ou RS2)" >&2; exit 1 ;;
esac
mdp=$(< "$HOME/bd511/cluster/secrets/$compte.pwd")
exec mongosh "mongodb://$compte:$mdp@$hotes/bd511?${rs}authSource=admin&appName=bd511-tp7-$compte" "$@"
EOF
chmod +x ~/bd511/ch07/mongosh-cluster
~/bd511/ch07/mongosh-cluster --quiet --eval 'print(db.hello().msg, "- shards :", db.adminCommand({ listShards: 1 }).shards.length)'
```

Résultat attendu :

```text
isdbgrid - shards : 0
```

`isdbgrid` est la signature d'un routeur `mongos` dans la réponse à `hello`. Le cluster ne compte encore aucun shard.

### 1.6 Ajouter les shards

Ajoutez RS1 au cluster. On désigne un shard par le nom de son replica set suivi d'un ou plusieurs membres : le routeur découvre les autres, arbitre compris.

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval 'sh.addShard("RS1/rs11:27011,rs12:27012")'
```

Résultat attendu :

```text
MongoServerError: Cannot add RS1/rs11:27011,rs12:27012 as a shard since the implicit default write concern on this shard is set to {w : 1}, because number of arbiters in the shard's configuration caused the number of writable voting members not to be strictly more than the voting majority. Change the shard configuration or set the cluster-wide write concern using the setDefaultRWConcern command and try again.
```

C'est la situation étudiée au chapitre 6 (partie 5.1) : avec un arbitre, le write concern par défaut implicite d'un replica set PSA est `{ w: 1 }`, alors que celui d'un cluster est `{ w: "majority" }`. MongoDB refuse d'ajouter un shard dont le défaut implicite diffère de celui du cluster : il faut d'abord fixer explicitement le **write concern par défaut du cluster** (*cluster-wide write concern*). On choisit `majority` : une écriture confirmée ne peut plus être perdue par un rollback.

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const r = db.adminCommand({ setDefaultRWConcern: 1, defaultWriteConcern: { w: "majority" }, writeConcern: { w: "majority" } });
  print("write concern par défaut du cluster :", EJSON.stringify(r.defaultWriteConcern), "(" + r.defaultWriteConcernSource + ")");
  for (const rs of ["RS1/rs11:27011,rs12:27012", "RS2/rs21:27021,rs22:27022"]) print("shard ajouté :", sh.addShard(rs).shardAdded);
  for (const s of db.adminCommand({ listShards: 1 }).shards) print(s._id, " ", s.host);'
```

Résultat attendu :

```text
write concern par défaut du cluster : {"w":"majority","wtimeout":0} (global)
shard ajouté : RS1
shard ajouté : RS2
RS1   RS1/rs11:27011,rs12:27012,rs1arb:27013
RS2   RS2/rs21:27021,rs22:27022,rs2arb:27023
```

Le routeur a complété la liste des membres de chaque shard, arbitre compris. Il tient cette chaîne à jour d'après la configuration du replica set : après un redémarrage, elle ne cite plus que les membres porteurs de données.

> **Le revers de `majority` avec des shards PSA.** Si le secondaire d'un shard tombe, les écritures sur ce shard attendent sans fin la confirmation de la majorité (`wtimeout: 0`) ; les migrations de données vers ou depuis ce shard s'arrêtent aussi. Les applications doivent donc préciser un `wtimeout`, et l'exploitant appliquer la procédure du chapitre 6 (retrait du vote du membre indisponible). En production, des shards PSS évitent le problème.

### 1.7 Observer le cluster

RS1 n'est pas arrivé vide : il apporte la base `bd511` du chapitre 6. Le routeur l'a enregistrée dans les métadonnées, avec RS1 comme **shard primaire** :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  db.getSiblingDB("config").databases.find().forEach(d => print("base", d._id, "- shard primaire :", d.primary));
  print("collections de bd511 :", db.getCollectionNames().sort().join(" "));'
```

Résultat attendu :

```text
base bd511 - shard primaire : RS1
collections de bd511 : commandes ecritures formations inscriptions stagiaires tests_wc
```

Ces collections ne sont pas shardées : elles restent entièrement sur le shard primaire de leur base, RS1, et le routeur y envoie toutes leurs requêtes.

De son côté, RS1 sait désormais qu'il est un shard : `addShard` a déposé sur son primaire un document d'identité, qui lui donne son nom et l'adresse des serveurs de configuration. Lisez-le par une connexion directe au replica set, avec le compte local `admin` :

```bash
~/bd511/ch07/mongosh-cluster --cible RS1 --quiet --eval 'printjson(db.getSiblingDB("admin").system.version.findOne({ _id: "shardIdentity" }))'
```

Résultat attendu (`clusterId` variable) :

```text
{
  _id: 'shardIdentity',
  shardName: 'RS1',
  clusterId: ObjectId('6adddca45818c78c26723c27'),
  configsvrConnectionString: 'RSCFG/config1:27041,config2:27042,config3:27043'
}
```

Conséquence pour les applications : la connexion directe au replica set, utilisée au chapitre 6, ne leur est plus permise. Comparez la même requête avec le compte `appli`, directement sur RS1 puis par le routeur :

```bash
~/bd511/ch07/mongosh-cluster --compte appli --cible RS1 --quiet --eval 'print(db.formations.countDocuments())'
~/bd511/ch07/mongosh-cluster --compte appli --quiet --eval 'print(db.formations.countDocuments())'
```

Résultat attendu :

```text
MongoServerError: You are connecting to a sharded cluster improperly by connecting directly to a shard. Please connect to the cluster via a router (mongos). Command: aggregate, Namespace: bd511.formations
24
```

Depuis MongoDB 8.0, un shard refuse les opérations reçues directement, sauf pour les comptes qui ont le rôle `directShardOperations` (inclus dans `root`) : elles sont réservées à la maintenance. Depuis la version 8.3, les opérations de définition des données (création d'index, de collection…) ne passent plus que par le routeur. Le script `mongosh-rs1` du chapitre 6 ne sert donc plus qu'à l'administrateur.

Enfin, ouvrez une session interactive sur le routeur et affichez l'état général du cluster :

```bash
~/bd511/ch07/mongosh-cluster
```

L'invite devient `[direct: mongos] bd511>`. Tapez :

```javascript
sh.status()
```

Résultat attendu (identifiants, horodatages et ordre des lignes de la section `balancer` variables ; la base `config` peut lister la collection `config.system.sessions`, créée quelques minutes après le démarrage du cluster) :

```text
shardingVersion
{
  _id: ObjectId('6adddca45818c78c26723c28'),
  clusterId: ObjectId('6adddca45818c78c26723c27')
}
---
shards
[
  {
    _id: 'RS1',
    host: 'RS1/rs11:27011,rs12:27012,rs1arb:27013',
    topologyTime: Timestamp({ t: 1792924865, i: 35 }),
    replSetConfigVersion: Long('-1')
  },
  {
    _id: 'RS2',
    host: 'RS2/rs21:27021,rs22:27022,rs2arb:27023',
    topologyTime: Timestamp({ t: 1792924866, i: 35 }),
    replSetConfigVersion: Long('-1')
  }
]
---
active mongoses
[ { '8.3.13': 1 } ]
---
autosplit
{ 'Currently enabled': 'yes' }
---
balancer
{
  'Currently enabled': 'yes',
  'Failed balancer rounds in last 5 attempts': 0,
  'Migration Results for the last 24 hours': 'No recent migrations',
  'Currently running': 'no'
}
---
shardedDataDistribution
[]
---
databases
[
  {
    database: {
      _id: 'bd511',
      primary: 'RS1',
      version: {
        uuid: UUID('e9e93b70-e673-408e-ac17-b185b85ded7c'),
        timestamp: Timestamp({ t: 1792924865, i: 35 }),
        lastMod: 1
      }
    },
    collections: {}
  },
  {
    database: { _id: 'config', primary: 'config', partitioned: true },
    collections: {}
  }
]
```

On y retrouve les deux shards, le routeur actif et sa version, l'état du **balancer** (actif, aucune migration pour l'instant) et la base `bd511`, qui n'a encore aucune collection shardée (`collections: {}`). La ligne `autosplit` n'a plus d'effet depuis MongoDB 6.0.3 : les chunks ne sont plus découpés automatiquement au fil des insertions, c'est le balancer qui découpe les plages au moment de les déplacer.

Quittez mongosh avec `exit`.

---

## Partie 2 – Sharder une collection, observer la répartition et le balancer

### 2.1 Générer le jeu de données

Le TP utilise un jeu de **200 000 ventes** d'une boutique en ligne, du 1er janvier 2025 au 30 septembre 2026. Chaque vente porte un numéro chronologique (`_id`), une date, un client parmi 20 000, la région du client (`EU` pour l'Europe, 60 % des clients ; `AM` pour les Amériques, 40 %), son pays, le canal de vente, le nombre d'articles et le montant.

Le générateur est **déterministe** (graine fixe) : il produit toujours exactement le même fichier, dont l'empreinte SHA-256 est connue. Le même fichier, compressé, est aussi fourni dans l'archive du TP (`donnees/ventes.json.gz`).

```bash
cat > ~/bd511/ch07/generer_ventes.py <<'EOF'
#!/usr/bin/env python3
"""generer_ventes.py - BD511 ch.7 : génère le jeu de données des ventes, au format JSON (un document par ligne).

Le générateur est déterministe (graine fixe) : il produit toujours exactement le même fichier,
dont la somme de contrôle figure dans donnees/SHA256SUMS.
Usage : python3 ~/bd511/ch07/generer_ventes.py > ~/bd511/ch07/donnees/ventes.json
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

NB_VENTES = 200_000
NB_CLIENTS = 20_000
PAYS = {"EU": ["FR", "DE", "ES", "IT", "BE", "NL"], "AM": ["US", "CA", "BR", "MX"]}
CANAUX = [("web", 0.55), ("magasin", 0.35), ("telephone", 0.10)]
DEBUT = datetime(2025, 1, 1, tzinfo=timezone.utc)
FIN = datetime(2026, 10, 1, tzinfo=timezone.utc)

alea = random.Random(511)


def tirer(choix):
    """Tire une valeur selon les poids donnés."""
    x, cumul = alea.random(), 0.0
    for valeur, poids in choix:
        cumul += poids
        if x < cumul:
            return valeur
    return choix[-1][0]


# Chaque client a un pays fixe : 60 % en Europe (EU), 40 % dans les Amériques (AM).
clients = []
for i in range(1, NB_CLIENTS + 1):
    region = "EU" if alea.random() < 0.6 else "AM"
    pays = PAYS[region][int(alea.random() * len(PAYS[region]))]
    clients.append((f"C{i:05d}", region, pays))

# Les ventes sont numérotées dans l'ordre chronologique, du 01/01/2025 au 30/09/2026.
pas = (FIN - DEBUT).total_seconds() / NB_VENTES
sortie = sys.stdout
for n in range(1, NB_VENTES + 1):
    date = DEBUT + timedelta(seconds=int((n - 1) * pas + alea.random() * pas))
    client, region, pays = clients[int(alea.random() * NB_CLIENTS)]
    articles = 1 + int(alea.random() ** 2 * 8)
    vente = {
        "_id": n,
        "date": {"$date": date.strftime("%Y-%m-%dT%H:%M:%SZ")},
        "client": client,
        "region": region,
        "pays": pays,
        "canal": tirer(CANAUX),
        "articles": articles,
        "montant": round(articles * (5 + alea.random() * 95), 2),
    }
    sortie.write(json.dumps(vente, separators=(",", ":")) + "\n")
EOF
cat > ~/bd511/ch07/donnees/SHA256SUMS <<'EOF'
326bb1749dc298c5145567e41853dee507fed51270c38ab88ba5431d7e0a58bd  ventes.json
EOF
python3 ~/bd511/ch07/generer_ventes.py > ~/bd511/ch07/donnees/ventes.json
cd ~/bd511/ch07/donnees && sha256sum -c SHA256SUMS
wc -l ventes.json
head -n 2 ventes.json
```

Résultat attendu (en quelques secondes) :

```text
ventes.json: OK
200000 ventes.json
{"_id":1,"date":{"$date":"2025-01-01T00:04:00Z"},"client":"C01913","region":"EU","pays":"NL","canal":"magasin","articles":4,"montant":96.98}
{"_id":2,"date":{"$date":"2025-01-01T00:09:11Z"},"client":"C01634","region":"AM","pays":"CA","canal":"web","articles":1,"montant":75.28}
```

Le fichier est au format JSON étendu de MongoDB (*Extended JSON*) : `{"$date": …}` sera importé comme une vraie date.

### 2.2 Importer les ventes dans une collection non shardée

Le script d'import passe par le routeur, avec le compte `appli`, et refuse d'écrire dans une collection qui contient déjà des documents. Comme au chapitre 6, le mot de passe transite par un fichier de configuration temporaire.

```bash
cat > ~/bd511/ch07/importer-ventes.sh <<'EOF'
#!/usr/bin/env bash
# importer-ventes.sh - BD511 ch.7 : importe le jeu de données des ventes dans une collection de la base bd511,
# par le routeur mongos1, avec le compte applicatif « appli ». La collection doit être vide ou inexistante.
# Le mot de passe passe par un fichier de configuration temporaire (mode 600, supprimé à la fin).
# Usage : bash ~/bd511/ch07/importer-ventes.sh <collection>        ex. : importer-ventes.sh ventes
set -euo pipefail
coll=${1:?"Usage : importer-ventes.sh <collection>"}
DONNEES="$HOME/bd511/ch07/donnees"
URI="mongodb://appli@mongos1:27017/?authSource=admin&appName=bd511-import"
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"

cd "$DONNEES"
sha256sum --quiet --check SHA256SUMS || { echo "ventes.json différent de la référence (partie 2.1)." >&2; exit 1; }
if [[ $("$MONGOSH" --compte appli --quiet --eval "print(db.getCollection('$coll').countDocuments({}, { limit: 1 }))") != 0 ]]; then
  echo "bd511.$coll contient déjà des documents : import annulé." >&2; exit 1
fi

conf=$(mktemp)
trap 'rm -f "$conf"' EXIT
printf 'password: "%s"\n' "$(< "$HOME/bd511/cluster/secrets/appli.pwd")" > "$conf"

# Écriture confirmée par la majorité des membres porteurs de données de chaque shard, arrêt à la première erreur.
debut=$SECONDS
mongoimport --config "$conf" --uri "$URI" --db bd511 --collection "$coll" --file ventes.json \
  --writeConcern '{w: "majority"}' --stopOnError --quiet
n=$("$MONGOSH" --compte appli --quiet --eval "print(db.getCollection('$coll').countDocuments())")
echo "bd511.$coll : $n documents importés en $((SECONDS - debut)) s"
EOF
bash ~/bd511/ch07/importer-ventes.sh ventes
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const s = db.ventes.stats();
  print("shardée :", s.sharded, "- shard(s) :", Object.keys(s.shards).join(", "), "-", s.count, "documents -", (s.size / 1048576).toFixed(1), "Mo");'
```

Résultat attendu (durée variable) :

```text
bd511.ventes : 200000 documents importés en 12 s
shardée : false - shard(s) : RS1 - 200000 documents - 23.5 Mo
```

La collection `ventes` n'est pas shardée : le routeur l'a créée sur le shard primaire de la base `bd511`, RS1, qui porte toutes ses données (23,5 Mo non compressés).

### 2.3 Choisir la clé de sharding

La **clé de sharding** est le champ (ou les champs) dont la valeur décide du shard qui reçoit chaque document. Une bonne clé a :

- une **forte cardinalité** : beaucoup de valeurs distinctes, sans quoi les données ne peuvent pas être découpées finement ;
- une **faible fréquence** : aucune valeur ne doit concentrer une grande partie des documents ;
- une progression **non monotone** : si chaque nouvelle valeur est plus grande que toutes les précédentes, toutes les insertions tombent dans le même chunk ;
- un lien avec les **requêtes** les plus fréquentes, que le routeur pourra alors envoyer à un seul shard.

Mesurez les champs candidats :

```bash
~/bd511/ch07/mongosh-cluster --compte appli --quiet --eval '
  for (const champ of ["region", "pays", "client", "date"]) {
    const n = db.ventes.aggregate([{ $group: { _id: "$" + champ } }, { $count: "n" }]).next().n;
    print(champ.padEnd(6), String(n).padStart(6), "valeurs distinctes");
  }
  const top = db.ventes.aggregate([{ $group: { _id: "$client", n: { $sum: 1 } } }, { $sort: { n: -1, _id: 1 } }, { $limit: 1 }]).next();
  print("client le plus fréquent :", top._id, "(" + top.n + " ventes)");'
```

Résultat attendu :

```text
region      2 valeurs distinctes
pays       10 valeurs distinctes
client  19998 valeurs distinctes
date   200000 valeurs distinctes
client le plus fréquent : C00710 (23 ventes)
```

| Candidate | Cardinalité | Fréquence maximale | Progression | Verdict |
| --- | --- | --- | --- | --- |
| `region` | 2 | 60 % des ventes | – | impossible : au plus deux chunks, donc deux shards utiles |
| `pays` | 10 | ≈ 15 % | – | trop peu de valeurs, et très inégales |
| `date` ou `_id` | 200 000 | unique | **croissante** | toutes les nouvelles ventes iraient sur le même shard (partie 3.2) |
| `client` | 19 998 | 23 ventes (0,01 %) | aléatoire | **retenue** : l'historique d'un client est la requête la plus fréquente de la boutique |

### 2.4 Sharder la collection

Pour observer l'état initial, arrêtez d'abord le balancer. Une collection qui contient déjà des données doit disposer d'un **index** dont la clé de sharding est le préfixe ; créez-le, puis shardez la collection :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  sh.stopBalancer();
  print("balancer actif :", sh.getBalancerState());
  print("index :", db.ventes.createIndex({ client: 1 }));
  print("collection shardée :", sh.shardCollection("bd511.ventes", { client: 1 }).collectionsharded);'
cat > ~/bd511/ch07/repartition.js <<'EOF'
// repartition.js - BD511 ch.7 : répartition d'une collection shardée de la base bd511 entre les shards
// Pour chaque shard : documents possédés, volume (données non compressées), chunks, documents orphelins.
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const config = db.getSiblingDB("config");
const coll = config.collections.findOne({ _id: ns });
if (!coll) { print(`${ns} n'est pas une collection shardée.`); quit(1); }

const chunks = {};
config.chunks.aggregate([{ $match: { uuid: coll.uuid } }, { $group: { _id: "$shard", n: { $sum: 1 } } }])
  .forEach(c => { chunks[c._id] = c.n; });
const repartition = db.getSiblingDB("admin").aggregate([{ $shardedDataDistribution: {} }, { $match: { ns } }]).toArray();
const parShard = Object.fromEntries((repartition[0]?.shards ?? []).map(s => [s.shardName, s]));
const total = Object.values(parShard).reduce((t, s) => t + s.numOwnedDocuments, 0);

print(`${ns}   clé de sharding ${EJSON.stringify(coll.key)}`);
for (const { _id: shard } of config.shards.find({}, { _id: 1 }).sort({ _id: 1 })) {
  const s = parShard[shard] ?? { numOwnedDocuments: 0, ownedSizeBytes: 0, numOrphanedDocs: 0 };
  const pct = total ? Math.round(100 * s.numOwnedDocuments / total) : 0;
  print(`  ${shard}  ${String(s.numOwnedDocuments).padStart(7)} documents ${String(pct).padStart(4)} %` +
        `  ${(s.ownedSizeBytes / 1048576).toFixed(1).padStart(5)} Mo  ${String(chunks[shard] ?? 0).padStart(3)} chunk(s)` +
        `  ${String(s.numOrphanedDocs).padStart(6)} orphelin(s)`);
}
EOF
COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const s = sh.balancerCollectionStatus("bd511.ventes");
  print("taille de chunk :", s.chunkSize, "Mo ; équilibrée :", s.balancerCompliant);'
```

Résultat attendu :

```text
balancer actif : false
index : client_1
collection shardée : bd511.ventes
bd511.ventes   clé de sharding {"client":1}
  RS1   200000 documents  100 %   23.5 Mo    1 chunk(s)       0 orphelin(s)
  RS2        0 documents    0 %    0.0 Mo    0 chunk(s)       0 orphelin(s)
taille de chunk : 128 Mo ; équilibrée : true
```

La collection est shardée, mais rien n'a bougé : un seul **chunk** couvre toutes les valeurs possibles de la clé, de `MinKey` à `MaxKey`, et il est sur RS1. Le script `repartition.js` lit ces informations dans les métadonnées (`config.chunks`) et dans l'étape d'agrégation `$shardedDataDistribution`.

Pour MongoDB, la collection est pourtant **équilibrée**. Depuis la version 6.0.3, le balancer compare le **volume de données** de chaque collection entre les shards. Il ne déplace des données que si l'écart atteint **trois fois la taille de chunk**, soit 384 Mo avec la valeur par défaut de 128 Mo. Ici, l'écart n'est que de 23,5 Mo.

### 2.5 Réduire la taille de chunk pour la démonstration

Pour voir le balancer à l'œuvre sur un petit volume, ramenez la taille de chunk de la collection à 1 Mo, la valeur minimale :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  print("réglage :", db.adminCommand({ configureCollectionBalancing: "bd511.ventes", chunkSize: 1 }).ok);
  const s = sh.balancerCollectionStatus("bd511.ventes");
  print("taille de chunk :", s.chunkSize, "Mo ; équilibrée :", s.balancerCompliant, "; motif :", s.firstComplianceViolation);'
```

Résultat attendu :

```text
réglage : 1
taille de chunk : 1 Mo ; équilibrée : false ; motif : chunksImbalance
```

L'écart toléré n'est plus que de 3 Mo : la collection est déséquilibrée (`chunksImbalance`).

> **En production**, on conserve la taille par défaut de 128 Mo. Des chunks minuscules multiplient les migrations, les entrées de métadonnées et la charge du balancer.

### 2.6 Démarrer le balancer et suivre les migrations

Le script suivant affiche l'état de départ, puis une ligne à chaque migration terminée, avec les documents et les chunks de chaque shard. Il s'arrête dès que la collection est équilibrée :

```bash
cat > ~/bd511/ch07/suivre-balancer.js <<'EOF'
// suivre-balancer.js - BD511 ch.7 : suit le travail du balancer sur une collection jusqu'à ce qu'elle soit équilibrée
// Une ligne au départ, puis à chaque migration terminée : documents et chunks de chaque shard, migrations depuis le sharding.
// S'arrête dès que la collection est équilibrée (balancerCompliant), ou au bout de DUREE secondes (300 par défaut).
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/suivre-balancer.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const duree = Number(process.env.DUREE || 300);
const config = db.getSiblingDB("config");
const { uuid } = config.collections.findOne({ _id: ns });
const shards = config.shards.find({}, { _id: 1 }).sort({ _id: 1 }).toArray().map(s => s._id);
const debut = Date.now();
const heure = () => new Date().toTimeString().slice(0, 8);

// Nombre de chunks de chaque shard, lu dans les métadonnées : il change quand une migration est validée (commit)
function chunksParShard() {
  const chunks = {};
  config.chunks.aggregate([{ $match: { uuid } }, { $group: { _id: "$shard", n: { $sum: 1 } } }]).forEach(c => { chunks[c._id] = c.n; });
  return shards.map(s => chunks[s] ?? 0);
}

function ligne(chunks) {
  const docs = {};
  const r = db.getSiblingDB("admin").aggregate([{ $shardedDataDistribution: {} }, { $match: { ns } }]).toArray();
  for (const s of r[0]?.shards ?? []) docs[s.shardName] = s.numOwnedDocuments;
  const migrations = config.changelog.countDocuments({ ns, what: "moveChunk.commit" });
  const texte = shards.map((s, i) => `${s} ${String(docs[s] ?? 0).padStart(6)} docs ${String(chunks[i]).padStart(2)} chunk(s)`).join(" | ");
  return `${heure()}  ${texte} | ${migrations} migration(s)`;
}

// Affiche une ligne si la répartition des chunks a changé depuis la dernière ligne affichée
let precedent = "";
function afficherSiChange(attente) {
  if (chunksParShard().join() === precedent) return;
  sleep(attente);                     // laisse la migration finir de s'enregistrer (orphelins, historique)
  const chunks = chunksParShard();
  print(ligne(chunks));
  precedent = chunks.join();
}

print(`${heure()}  suivi de ${ns} : taille de chunk ${sh.balancerCollectionStatus(ns).chunkSize} Mo, balancer ${sh.getBalancerState() ? "actif" : "arrêté"}`);
afficherSiChange(0);
for (;;) {
  if (sh.balancerCollectionStatus(ns).balancerCompliant) {
    sleep(2000);                      // une dernière migration peut encore être en cours de validation
    afficherSiChange(0);
    print(`${heure()}  collection équilibrée`);
    break;
  }
  afficherSiChange(400);
  if ((Date.now() - debut) / 1000 > duree) { print(`${heure()}  arrêt du suivi après ${duree} s`); break; }
  sleep(250);
}
EOF
~/bd511/ch07/mongosh-cluster --quiet --eval 'sh.startBalancer(); print("balancer actif :", sh.getBalancerState())'
COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/suivre-balancer.js
```

Résultat attendu (heures variables ; l'ensemble prend une vingtaine de secondes ; sur une VM très chargée, une ligne peut regrouper deux migrations) :

```text
balancer actif : true
12:21:27  suivi de bd511.ventes : taille de chunk 1 Mo, balancer actif
12:21:27  RS1 200000 docs  1 chunk(s) | RS2      0 docs  0 chunk(s) | 0 migration(s)
12:21:32  RS1 191479 docs  1 chunk(s) | RS2   8521 docs  1 chunk(s) | 1 migration(s)
12:21:34  RS1 182955 docs  1 chunk(s) | RS2  17045 docs  2 chunk(s) | 2 migration(s)
12:21:35  RS1 174432 docs  1 chunk(s) | RS2  25568 docs  3 chunk(s) | 3 migration(s)
12:21:36  RS1 165913 docs  1 chunk(s) | RS2  34087 docs  4 chunk(s) | 4 migration(s)
12:21:38  RS1 157391 docs  1 chunk(s) | RS2  42609 docs  5 chunk(s) | 5 migration(s)
12:21:39  RS1 148869 docs  1 chunk(s) | RS2  51131 docs  6 chunk(s) | 6 migration(s)
12:21:40  RS1 140354 docs  1 chunk(s) | RS2  59646 docs  7 chunk(s) | 7 migration(s)
12:21:42  RS1 131832 docs  1 chunk(s) | RS2  68168 docs  8 chunk(s) | 8 migration(s)
12:21:44  RS1 123312 docs  1 chunk(s) | RS2  76688 docs  9 chunk(s) | 9 migration(s)
12:21:45  RS1 114792 docs  1 chunk(s) | RS2  85208 docs 10 chunk(s) | 10 migration(s)
12:21:48  RS1 106268 docs  1 chunk(s) | RS2  93732 docs 11 chunk(s) | 11 migration(s)
12:21:48  collection équilibrée
```

À chaque **ronde**, le balancer, qui tourne sur le primaire de RSCFG, choisit une plage d'environ 1 Mo (≈ 8 500 ventes) en bas du chunk de RS1, découpe ce chunk et demande à RS1 de la **migrer** vers RS2. RS2 copie les documents, rattrape les écritures faites pendant la copie, puis RSCFG enregistre le nouveau propriétaire de la plage (*commit*). Un shard ne participe qu'à une migration à la fois ; les rondes s'enchaînent tant que l'écart dépasse 3 Mo. Pendant toute l'opération, la collection reste lisible et modifiable par le routeur.

### 2.7 Analyser le résultat

Affichez la nouvelle répartition, puis l'historique des migrations, que les serveurs de configuration conservent dans `config.changelog` :

```bash
COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const migrations = db.getSiblingDB("config").changelog.find({ ns: "bd511.ventes", what: "moveChunk.commit" }).sort({ time: 1 }).toArray();
  print(migrations.length, "migrations, dont les trois premières :");
  for (const m of migrations.slice(0, 3)) {
    const d = m.details;
    print(" ", d.from, "->", d.to, " plage", EJSON.stringify(d.min), "->", EJSON.stringify(d.max), " ", Number(d.counts.cloned), "documents");
  }'
```

Résultat attendu :

```text
bd511.ventes   clé de sharding {"client":1}
  RS1   106268 documents   53 %   12.5 Mo    1 chunk(s)   93732 orphelin(s)
  RS2    93732 documents   47 %   11.0 Mo   11 chunk(s)       0 orphelin(s)
11 migrations, dont les trois premières :
  RS1 -> RS2  plage {"client":{"$minKey":1}} -> {"client":"C00851"}   8521 documents
  RS1 -> RS2  plage {"client":"C00851"} -> {"client":"C01695"}   8524 documents
  RS1 -> RS2  plage {"client":"C01695"} -> {"client":"C02546"}   8523 documents
```

L'écart est désormais inférieur à 3 Mo. RS2 détient les plus petites valeurs de la clé (les clients `C00001` à `C09340`), RS1 les suivantes. Les 11 plages reçues par RS2 sont contiguës : l'**AutoMerger**, processus périodique du balancer, les fusionnera plus tard en un seul chunk. Le nombre de chunks de RS2 peut donc diminuer pendant la suite du TP.

La colonne **orphelins** mérite une explication. Après chaque migration, RS1, le shard donneur, conserve sa copie des documents partis : ce sont des **documents orphelins**. Il ne les supprime qu'après un délai, pour laisser se terminer les lectures qui avaient commencé avant la migration. Constatez-le en interrogeant RS1 directement, puis par le routeur :

```bash
~/bd511/ch07/mongosh-cluster --cible RS1 --quiet --eval '
  print("documents présents sur RS1 :", db.ventes.countDocuments());
  const taches = db.getSiblingDB("config").rangeDeletions.find({ nss: "bd511.ventes" }).toArray();
  print("suppressions de plages en attente :", taches.length, "-", taches.reduce((t, x) => t + Number(x.numOrphanDocs), 0), "documents orphelins");
  print("délai avant suppression :", db.adminCommand({ getParameter: 1, orphanCleanupDelaySecs: 1 }).orphanCleanupDelaySecs, "s");'
~/bd511/ch07/mongosh-cluster --quiet --eval 'print("documents vus par le routeur :", db.ventes.countDocuments())'
```

Résultat attendu (moins d'une heure après les migrations) :

```text
documents présents sur RS1 : 200000
suppressions de plages en attente : 11 - 93732 documents orphelins
délai avant suppression : 3600 s
documents vus par le routeur : 200000
```

RS1 contient encore physiquement les 200 000 ventes, dont 93 732 qui appartiennent désormais à RS2. Chaque plage migrée a donné lieu à une tâche de suppression, que le *range deleter* exécutera une heure après la migration (`orphanCleanupDelaySecs` vaut 3 600 s depuis MongoDB 8.2, contre 900 s auparavant). Par le routeur, en revanche, chaque vente n'est comptée qu'une fois : chaque shard filtre les documents qu'il ne possède plus d'après les métadonnées. C'est une raison de plus pour ne jamais lire les données d'un shard en direct.

mongosh fournit aussi une vue de synthèse de la répartition :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval 'db.ventes.getShardDistribution()'
```

Résultat attendu (moins d'une heure après les migrations ; l'ordre des shards peut varier) :

```text
Shard RS2 at RS2/rs21:27021,rs22:27022,rs2arb:27023
{
  data: '10.99MiB',
  docs: 93732,
  chunks: 11,
  'estimated data per chunk': '1023KiB',
  'estimated docs per chunk': 8521
}
---
Shard RS1 at RS1/rs11:27011,rs12:27012,rs1arb:27013
{
  data: '12.46MiB',
  docs: 200000,
  chunks: 1,
  'estimated data per chunk': '12.46MiB',
  'estimated docs per chunk': 200000
}
---
Totals
{
  data: '23.46MiB',
  docs: 293732,
  chunks: 12,
  'Shard RS2': [
    '46.86 % data',
    '31.91 % docs in cluster',
    '123B avg obj size on shard'
  ],
  'Shard RS1': [
    '53.13 % data',
    '68.08 % docs in cluster',
    '123B avg obj size on shard'
  ]
}
```

Attention aux nombres de documents : `getShardDistribution()` lit les statistiques de chaque shard, orphelins compris. Elle annonce donc 200 000 documents sur RS1 et 293 732 au total, pour 200 000 ventes réelles. Les volumes (`data`), eux, ne portent que sur les données possédées. Tant que des orphelins subsistent, seule l'étape `$shardedDataDistribution`, utilisée par `repartition.js`, sépare clairement les documents possédés des orphelins.

### 2.8 Requêtes ciblées et requêtes diffusées

Le routeur n'envoie une requête qu'aux shards qui peuvent détenir les documents demandés. Il ne le sait que si le filtre porte sur la clé de sharding. Le script suivant demande au routeur le plan d'exécution (`explain`) de cinq requêtes types et indique les shards interrogés :

```bash
cat > ~/bd511/ch07/routage.js <<'EOF'
// routage.js - BD511 ch.7 : comment mongos route quelques requêtes types sur une collection shardée
// « ciblée » : envoyée au seul shard concerné ; « diffusée » : envoyée à tous les shards (scatter-gather).
// Usage : COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
const coll = db.getCollection(process.env.COLL || "ventes");
const requetes = [
  ["un client", { client: "C01913" }],
  ["100 clients consécutifs", { client: { $gte: "C15000", $lt: "C15100" } }],
  ["un mois de ventes", { date: { $gte: ISODate("2026-09-01T00:00:00Z"), $lt: ISODate("2026-10-01T00:00:00Z") } }],
  ["une région", { region: "AM" }],
  ["une région et un client", { region: "EU", client: "C01913" }],
];
for (const [libelle, filtre] of requetes) {
  const plan = coll.find(filtre).explain().queryPlanner.winningPlan;
  const shards = plan.shards.map(s => s.shardName).sort();
  const routage = shards.length === 1 ? "ciblée" : "diffusée";
  print(`${libelle.padEnd(25)} ${routage.padEnd(8)}  ${plan.stage.padEnd(12)}  ${shards.join(", ")}`);
}
EOF
COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
```

Résultat attendu :

```text
un client                 ciblée    SINGLE_SHARD  RS2
100 clients consécutifs   ciblée    SINGLE_SHARD  RS1
un mois de ventes         diffusée  SHARD_MERGE   RS1, RS2
une région                diffusée  SHARD_MERGE   RS1, RS2
une région et un client   ciblée    SINGLE_SHARD  RS2
```

- Avec la clé `client` dans le filtre, la requête est **ciblée** (`SINGLE_SHARD`) : un seul shard travaille, quel que soit le nombre de shards du cluster. Une plage de clients voisins reste sur un seul shard, puisque la clé est **à intervalles** (*ranged sharding*) : les valeurs proches sont rangées ensemble.
- Sans la clé, la requête est **diffusée** à tous les shards (*scatter-gather*), puis le routeur fusionne leurs réponses (`SHARD_MERGE`). Son coût augmente avec le nombre de shards : c'est acceptable pour des rapports occasionnels, pas pour les requêtes les plus fréquentes.

### 2.9 Régler le balancer pour la production

Une migration consomme des ressources (copie, réplication, puis suppression des orphelins). En production, on la cantonne souvent à une **fenêtre** creuse, définie dans les métadonnées et interprétée dans le fuseau horaire du primaire de RSCFG (ici celui de la VM, monté dans les conteneurs) :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const config = db.getSiblingDB("config");
  config.settings.updateOne({ _id: "balancer" }, { $set: { activeWindow: { start: "23:00", stop: "06:00" } } }, { upsert: true });
  print("fenêtre :", EJSON.stringify(config.settings.findOne({ _id: "balancer" }).activeWindow));
  print("balancer actif :", sh.getBalancerState(), "; ronde en cours :", sh.isBalancerRunning().inBalancerRound);
  print("fenêtre supprimée :", config.settings.updateOne({ _id: "balancer" }, { $unset: { activeWindow: "" } }).modifiedCount);'
```

Résultat attendu :

```text
fenêtre : {"start":"23:00","stop":"06:00"}
balancer actif : true ; ronde en cours : false
fenêtre supprimée : 1
```

Le balancer reste actif, mais ne lance plus de migration en dehors de la fenêtre. Pour la suite du TP, la fenêtre a été supprimée. Retenez aussi :

- `sh.stopBalancer()` avant toute sauvegarde par copie des fichiers ou par instantané, puis `sh.startBalancer()` : une migration en cours rendrait la sauvegarde incohérente entre les shards ;
- `sh.disableBalancing("bd511.ventes")` exclut une seule collection du balancer ;
- la taille de chunk d'une collection se règle avec `configureCollectionBalancing` (partie 2.5) ; celle du cluster, avec le document `chunksize` de `config.settings`.

---

## Partie 3 – Comparer les méthodes de sharding

### 3.1 Le protocole

On compare trois autres façons de sharder les mêmes ventes, chacune dans sa propre collection. Comme en production, chaque collection est shardée **vide**, avant le chargement des données : le choix de la clé précède l'import. Pour chaque méthode, on mesure :

1. la **répartition des données** après l'import (`repartition.js`) ;
2. la **répartition des nouvelles écritures** : le script `inserer-ventes.js` simule l'activité d'octobre 2026 (10 000 nouvelles ventes, datées du 1er au 28 octobre, pour des clients existants) et compte les ventes reçues par chaque shard ;
3. le **routage** des cinq requêtes types de la partie 2.8 (`routage.js`).

Créez les deux derniers scripts, puis mesurez la référence : la collection `ventes` de la partie 2, shardée à intervalles sur `client`.

```bash
cat > ~/bd511/ch07/inserer-ventes.js <<'EOF'
// inserer-ventes.js - BD511 ch.7 : simule l'activité d'octobre 2026 (10 000 nouvelles ventes, numérotées
// à partir de 200 001) dans une collection, puis indique sur quel shard ces nouvelles ventes ont été écrites.
// Relançable : les ventes d'une exécution précédente sont d'abord supprimées.
// Usage : COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
const nom = process.env.COLL || "ventes";
const coll = db.getCollection(nom);
const NB = 10000, PREMIER = 200001, DEBUT = Date.parse("2026-10-01T00:00:00Z");
coll.deleteMany({ _id: { $gte: PREMIER } });

// Clients existants, avec leur région et leur pays ; tirage pseudo-aléatoire reproductible (générateur de Park et Miller)
const clients = coll.aggregate([
  { $match: { _id: { $lt: PREMIER } } },
  { $group: { _id: "$client", region: { $first: "$region" }, pays: { $first: "$pays" } } },
  { $sort: { _id: 1 } },
]).toArray();
let graine = 511;
const alea = () => (graine = (graine * 16807) % 2147483647) / 2147483647;

const t0 = Date.now();
for (let lot = 0; lot < NB / 1000; lot++) {
  const ventes = [];
  for (let i = 0; i < 1000; i++) {
    const n = lot * 1000 + i;
    const c = clients[Math.floor(alea() * clients.length)];
    const articles = 1 + Math.floor(alea() * alea() * 8);
    ventes.push({ _id: PREMIER + n, date: new Date(DEBUT + n * 240000), client: c._id, region: c.region, pays: c.pays,
                  canal: "web", articles, montant: Math.round(articles * (5 + alea() * 95) * 100) / 100 });
  }
  coll.insertMany(ventes, { ordered: false });
}
const duree = ((Date.now() - t0) / 1000).toFixed(1);

// Nombre de nouvelles ventes trouvées sur chaque shard (plan d'exécution de la requête diffusée correspondante)
const stats = coll.find({ _id: { $gte: PREMIER } }).explain("executionStats").executionStats.executionStages;
const parShard = stats.shards ?? [{ shardName: stats.shardName, nReturned: stats.nReturned }];
print(`bd511.${nom} : ${NB} nouvelles ventes (octobre 2026) insérées en ${duree} s`);
for (const s of parShard.sort((a, b) => a.shardName.localeCompare(b.shardName))) {
  const n = s.nReturned ?? s.executionStages?.nReturned;
  print(`  ${s.shardName}  ${String(n).padStart(6)} nouvelles ventes ${String(Math.round(100 * n / NB)).padStart(4)} %`);
}
EOF
cat > ~/bd511/ch07/chunks.js <<'EOF'
// chunks.js - BD511 ch.7 : liste les chunks d'une collection shardée, dans l'ordre de la clé, avec leur shard
// Puis les plages de zones éventuellement définies sur la collection.
// Usage : COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/chunks.js
const ns = `bd511.${process.env.COLL || "ventes"}`;
const config = db.getSiblingDB("config");
const coll = config.collections.findOne({ _id: ns });
if (!coll) { print(`${ns} n'est pas une collection shardée.`); quit(1); }
const texte = v => EJSON.stringify(v);
print(`${ns}   clé de sharding ${texte(coll.key)}`);
config.chunks.find({ uuid: coll.uuid }).sort({ min: 1 })
  .forEach(c => print(`  chunk  ${c.shard}  ${texte(c.min)}  ->  ${texte(c.max)}`));
config.tags.find({ ns }).sort({ min: 1 })
  .forEach(z => print(`  zone   ${z.tag}  ${texte(z.min)}  ->  ${texte(z.max)}`));
EOF
COLL=ventes ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
```

Résultat attendu (durée variable) :

```text
bd511.ventes : 10000 nouvelles ventes (octobre 2026) insérées en 0.5 s
  RS1    5352 nouvelles ventes   54 %
  RS2    4648 nouvelles ventes   46 %
```

Les nouvelles ventes se répartissent comme les clients : 54 % sur RS1, 46 % sur RS2. Les écritures sont partagées entre les deux shards.

### 3.2 Clé à intervalles croissante : `{ date: 1 }`

Avec une clé à intervalles, chaque chunk couvre une plage **contiguë** de valeurs. Si la clé croît sans cesse, comme une date, un numéro de commande ou un `ObjectId`, chaque nouveau document a une valeur plus grande que toutes les précédentes : il tombe toujours dans le **dernier** chunk, celui qui se termine par `MaxKey`.

Shardez la collection vide `ventes_date` sur la date. Pour partir d'une situation réaliste, où l'historique est déjà réparti, découpez la plage au 1er janvier 2026 et envoyez les ventes de 2025 sur RS2 :

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const ns = "bd511.ventes_date", janvier2026 = ISODate("2026-01-01T00:00:00Z");
  print("collection shardée :", sh.shardCollection(ns, { date: 1 }).collectionsharded);
  print("découpage au 01/01/2026 :", sh.splitAt(ns, { date: janvier2026 }).ok);
  print("migration de 2025 vers RS2 :", sh.moveRange(ns, "RS2", { date: MinKey }, { date: janvier2026 }).ok);'
COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/chunks.js
```

Résultat attendu :

```text
collection shardée : bd511.ventes_date
découpage au 01/01/2026 : 1
migration de 2025 vers RS2 : 1
bd511.ventes_date   clé de sharding {"date":1}
  chunk  RS2  {"date":{"$minKey":1}}  ->  {"date":{"$date":"2026-01-01T00:00:00Z"}}
  chunk  RS1  {"date":{"$date":"2026-01-01T00:00:00Z"}}  ->  {"date":{"$maxKey":1}}
```

La collection étant vide, `shardCollection` a créé lui-même l'index `{ date: 1 }`. `splitAt` et `moveRange` sont les commandes de découpage et de migration manuelles, que le balancer utilise aussi pour son propre compte. Importez les ventes, puis mesurez :

```bash
bash ~/bd511/ch07/importer-ventes.sh ventes_date
COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
COLL=ventes_date ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
```

Résultat attendu (durées variables) :

```text
bd511.ventes_date : 200000 documents importés en 13 s
bd511.ventes_date   clé de sharding {"date":1}
  RS1    85580 documents   43 %   10.0 Mo    1 chunk(s)       0 orphelin(s)
  RS2   114420 documents   57 %   13.4 Mo    1 chunk(s)       0 orphelin(s)
bd511.ventes_date : 10000 nouvelles ventes (octobre 2026) insérées en 0.4 s
  RS1   10000 nouvelles ventes  100 %
  RS2       0 nouvelles ventes    0 %
un client                 diffusée  SHARD_MERGE   RS1, RS2
100 clients consécutifs   diffusée  SHARD_MERGE   RS1, RS2
un mois de ventes         ciblée    SINGLE_SHARD  RS1
une région                diffusée  SHARD_MERGE   RS1, RS2
une région et un client   diffusée  SHARD_MERGE   RS1, RS2
```

Les données historiques sont réparties (57 % sur RS2 pour 2025, 43 % sur RS1 pour 2026), mais **100 % des nouvelles ventes** arrivent sur RS1, qui détient le dernier chunk : RS1 est un **shard chaud** (*hot shard*), RS2 ne reçoit aucune écriture. Rééquilibrer les données anciennes n'y changerait rien : le chunk qui reçoit les insertions reste unique, et il ne peut être que sur un seul shard. Seul avantage, les requêtes par période sont ciblées, car les dates voisines sont rangées ensemble.

### 3.3 Clé hachée : `{ client: "hashed" }`

Avec une clé **hachée**, MongoDB calcule un hachage de la valeur (un entier de 64 bits) et découpe les chunks selon ce hachage. Des valeurs voisines obtiennent des hachages sans rapport entre eux : les documents se dispersent uniformément entre les shards.

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval 'print("collection shardée :", sh.shardCollection("bd511.ventes_hash", { client: "hashed" }).collectionsharded)'
COLL=ventes_hash ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/chunks.js
```

Résultat attendu :

```text
collection shardée : bd511.ventes_hash
bd511.ventes_hash   clé de sharding {"client":"hashed"}
  chunk  RS2  {"client":{"$minKey":1}}  ->  {"client":0}
  chunk  RS1  {"client":0}  ->  {"client":{"$maxKey":1}}
```

Sur une collection vide, MongoDB crée d'emblée un chunk par shard : les hachages négatifs d'un côté, les positifs de l'autre. Importez et mesurez :

```bash
bash ~/bd511/ch07/importer-ventes.sh ventes_hash
COLL=ventes_hash ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
COLL=ventes_hash ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
COLL=ventes_hash ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
```

Résultat attendu (durées variables) :

```text
bd511.ventes_hash : 200000 documents importés en 15 s
bd511.ventes_hash   clé de sharding {"client":"hashed"}
  RS1    99285 documents   50 %   11.6 Mo    1 chunk(s)       0 orphelin(s)
  RS2   100715 documents   50 %   11.7 Mo    1 chunk(s)       0 orphelin(s)
bd511.ventes_hash : 10000 nouvelles ventes (octobre 2026) insérées en 0.5 s
  RS1    4997 nouvelles ventes   50 %
  RS2    5003 nouvelles ventes   50 %
un client                 ciblée    SINGLE_SHARD  RS1
100 clients consécutifs   diffusée  SHARD_MERGE   RS1, RS2
un mois de ventes         diffusée  SHARD_MERGE   RS1, RS2
une région                diffusée  SHARD_MERGE   RS1, RS2
une région et un client   ciblée    SINGLE_SHARD  RS1
```

Données et écritures sont réparties à parts égales dès l'import, sans aucune migration. La recherche d'un client reste ciblée, puisque le routeur sait calculer le hachage d'une valeur précise ; une **plage** de clients, en revanche, est diffusée, car le hachage ne conserve pas l'ordre des valeurs. Le hachage est aussi la bonne réponse à une clé croissante : `{ _id: "hashed" }` répartit les insertions même si `_id` est un `ObjectId`. Un index haché ne peut pas être unique.

### 3.4 Zones : `{ region: 1, client: 1 }`

Les **zones** attachent des plages de valeurs de la clé à des shards désignés. Elles servent à **localiser** les données : garder les clients européens sur des serveurs situés en Europe (protection des données, latence), placer les données anciennes sur du matériel moins coûteux. Ici, la zone `EUROPE` est attribuée à RS1 et la zone `AMERIQUES` à RS2. La clé commence par la région, pour que les plages de zone puissent s'exprimer sur ce préfixe.

```bash
~/bd511/ch07/mongosh-cluster --quiet --eval '
  const ns = "bd511.ventes_zone";
  print("RS1 dans la zone EUROPE :", sh.addShardToZone("RS1", "EUROPE").ok);
  print("RS2 dans la zone AMERIQUES :", sh.addShardToZone("RS2", "AMERIQUES").ok);
  print("plage AMERIQUES :", sh.updateZoneKeyRange(ns, { region: MinKey, client: MinKey }, { region: "EU", client: MinKey }, "AMERIQUES").ok);
  print("plage EUROPE :", sh.updateZoneKeyRange(ns, { region: "EU", client: MinKey }, { region: MaxKey, client: MaxKey }, "EUROPE").ok);
  print("collection shardée :", sh.shardCollection(ns, { region: 1, client: 1 }).collectionsharded);'
COLL=ventes_zone ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/chunks.js
```

Résultat attendu :

```text
RS1 dans la zone EUROPE : 1
RS2 dans la zone AMERIQUES : 1
plage AMERIQUES : 1
plage EUROPE : 1
collection shardée : bd511.ventes_zone
bd511.ventes_zone   clé de sharding {"region":1,"client":1}
  chunk  RS2  {"region":{"$minKey":1},"client":{"$minKey":1}}  ->  {"region":"EU","client":{"$minKey":1}}
  chunk  RS1  {"region":"EU","client":{"$minKey":1}}  ->  {"region":{"$maxKey":1},"client":{"$maxKey":1}}
  zone   AMERIQUES  {"region":{"$minKey":1},"client":{"$minKey":1}}  ->  {"region":"EU","client":{"$minKey":1}}
  zone   EUROPE  {"region":"EU","client":{"$minKey":1}}  ->  {"region":{"$maxKey":1},"client":{"$maxKey":1}}
```

Les zones ont été définies **avant** de sharder la collection vide : MongoDB a créé un chunk par plage de zone, directement sur le bon shard. Les deux plages se touchent et couvrent tout l'espace des clés : `AM` précède `EU` dans l'ordre alphabétique, donc toutes les ventes `AM` tombent dans la plage `AMERIQUES`, toutes les ventes `EU` dans la plage `EUROPE`. Ainsi, aucun chunk n'échappe aux zones, et une requête sur une région ne touche qu'un chunk.

```bash
bash ~/bd511/ch07/importer-ventes.sh ventes_zone
COLL=ventes_zone ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/repartition.js
COLL=ventes_zone ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/inserer-ventes.js
COLL=ventes_zone ~/bd511/ch07/mongosh-cluster --quiet ~/bd511/ch07/routage.js
```

Résultat attendu (durées variables) :

```text
bd511.ventes_zone : 200000 documents importés en 17 s
bd511.ventes_zone   clé de sharding {"region":1,"client":1}
  RS1   120303 documents   60 %   14.0 Mo    1 chunk(s)       0 orphelin(s)
  RS2    79697 documents   40 %    9.3 Mo    1 chunk(s)       0 orphelin(s)
bd511.ventes_zone : 10000 nouvelles ventes (octobre 2026) insérées en 0.5 s
  RS1    6104 nouvelles ventes   61 %
  RS2    3896 nouvelles ventes   39 %
un client                 diffusée  SHARD_MERGE   RS1, RS2
100 clients consécutifs   diffusée  SHARD_MERGE   RS1, RS2
un mois de ventes         diffusée  SHARD_MERGE   RS1, RS2
une région                ciblée    SINGLE_SHARD  RS2
une région et un client   ciblée    SINGLE_SHARD  RS1
```

Chaque vente est sur le shard de sa région : 60 % sur RS1 (Europe), 40 % sur RS2 (Amériques). La répartition suit la règle métier, et non l'équilibre : les zones priment sur le balancer, qui n'équilibre les données qu'**entre les shards d'une même zone**. Les requêtes par région sont ciblées. Celles qui portent sur un client sans préciser sa région sont diffusées : il manque le premier champ de la clé.

### 3.5 Synthèse

| Méthode (collection) | Clé | Données RS1 / RS2 | Nouvelles ventes RS1 / RS2 | Requêtes ciblées | À retenir |
| --- | --- | --- | --- | --- | --- |
| Intervalles (`ventes`) | `{ client: 1 }` | 53 / 47 % (balancer) | 54 / 46 % | un client, une plage de clients | la bonne clé : cardinalité forte, fréquence faible, valeurs non croissantes, liée à la requête principale |
| Intervalles, clé croissante (`ventes_date`) | `{ date: 1 }` | 43 / 57 % (découpage manuel) | **100 / 0 %** | une période | shard chaud : à éviter pour une collection qui reçoit beaucoup d'insertions |
| Hachée (`ventes_hash`) | `{ client: "hashed" }` | 50 / 50 % | 50 / 50 % | un client (valeur exacte) | répartition uniforme, sans migration ; les requêtes par plage sont diffusées |
| Zones (`ventes_zone`) | `{ region: 1, client: 1 }` | 60 / 40 % (par région) | 61 / 39 % | une région, une région et un client | localisation des données imposée ; l'équilibre n'est garanti qu'à l'intérieur d'une zone |

Changer d'avis reste possible, à un coût : `refineCollectionShardKey` ajoute des champs en fin de clé (sans déplacer de données) ; `reshardCollection` réécrit toute la collection avec une nouvelle clé, en ligne, mais demande du temps et de l'espace disque. Choisir la clé avant de charger les données reste la meilleure option.

---

## Partie 4 – Exploiter le cluster et conclure

### 4.1 Arrêter et redémarrer le cluster dans l'ordre

Un cluster shardé s'arrête dans un ordre précis : balancer désactivé, puis routeur(s), shards et enfin serveurs de configuration. Il redémarre dans l'ordre inverse. Le script suivant applique cette procédure aux conteneurs du TP :

```bash
cat > ~/bd511/ch07/cluster.sh <<'EOF'
#!/usr/bin/env bash
# cluster.sh - BD511 ch.7 : démarre ou arrête le cluster shardé dans l'ordre recommandé, ou affiche son état
#   demarrer : serveurs de configuration, puis shards, puis routeur ; réactive le balancer
#   arreter  : désactive le balancer, puis arrête le routeur, les shards et enfin les serveurs de configuration
# Usage : bash ~/bd511/ch07/cluster.sh demarrer|arreter|etat
set -euo pipefail
CONFIG=(config1 config2 config3)
SHARDS=(rs11 rs12 rs1arb rs21 rs22 rs2arb)
ROUTEURS=(mongos1)
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"
cd "$HOME/bd511/cluster"

case ${1:-} in
  demarrer)
    sudo docker compose up -d --wait "${CONFIG[@]}"
    sudo docker compose up -d --wait "${SHARDS[@]}"
    sudo docker compose up -d --wait "${ROUTEURS[@]}"
    "$MONGOSH" --quiet --eval 'sh.startBalancer(); print("balancer actif :", sh.getBalancerState())' ;;
  arreter)
    "$MONGOSH" --quiet --eval 'sh.stopBalancer(); print("balancer actif :", sh.getBalancerState())'
    sudo docker compose stop "${ROUTEURS[@]}"
    sudo docker compose stop "${SHARDS[@]}"
    sudo docker compose stop "${CONFIG[@]}" ;;
  etat)
    sudo docker compose ps -a --format 'table {{.Name}}\t{{.Status}}' "${CONFIG[@]}" "${SHARDS[@]}" "${ROUTEURS[@]}" ;;
  *)
    echo "Usage : $0 demarrer|arreter|etat" >&2; exit 1 ;;
esac
EOF
bash ~/bd511/ch07/cluster.sh arreter
bash ~/bd511/ch07/cluster.sh demarrer
```

Résultat attendu (durées variables ; l'arrêt prend une minute environ) :

```text
balancer actif : false
[+] stop 1/1
 ✔ Container mongos1 Stopped                                                   0.3s
[+] stop 6/6
 ✔ Container rs1arb Stopped                                                    0.4s
 ✔ Container rs2arb Stopped                                                    0.4s
 ✔ Container rs12   Stopped                                                   15.6s
 ✔ Container rs22   Stopped                                                   15.7s
 ✔ Container rs21   Stopped                                                   16.0s
 ✔ Container rs11   Stopped                                                   16.0s
[+] stop 3/3
 ✔ Container config3 Stopped                                                  15.4s
 ✔ Container config2 Stopped                                                  15.5s
 ✔ Container config1 Stopped                                                  15.8s
[+] up 3/3
 ✔ Container config1 Healthy                                                   3.6s
 ✔ Container config2 Healthy                                                   3.6s
 ✔ Container config3 Healthy                                                   3.6s
[+] up 6/6
 ✔ Container rs1arb Healthy                                                    3.1s
 ✔ Container rs2arb Healthy                                                    3.1s
 ✔ Container rs12   Healthy                                                    3.6s
 ✔ Container rs21   Healthy                                                    3.6s
 ✔ Container rs11   Healthy                                                    3.6s
 ✔ Container rs22   Healthy                                                    3.6s
[+] up 1/1
 ✔ Container mongos1 Healthy                                                   2.1s
balancer actif : true
```

`sh.stopBalancer()` attend la fin de la ronde en cours : aucune migration n'est interrompue par l'arrêt. Les conteneurs arrêtés par `docker compose stop` ne redémarrent pas seuls au démarrage de la VM : relancez alors `cluster.sh demarrer`.

### 4.2 Contrôle final

```bash
cat > ~/bd511/ch07/verifier-ch07.sh <<'EOF'
#!/usr/bin/env bash
# verifier-ch07.sh - BD511 ch.7 : contrôle final du cluster shardé et des collections du TP
# Usage : bash ~/bd511/ch07/verifier-ch07.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
cd "$HOME/bd511/cluster"
MONGOSH="$HOME/bd511/ch07/mongosh-cluster"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Conteneurs"
attendu="config1 config2 config3 mongos1 rs11 rs12 rs1arb rs21 rs22 rs2arb"
sains=$(sudo docker compose ps --format '{{.Name}} {{.Health}}' | awk '$2 == "healthy" {print $1}' | sort | tr '\n' ' ')
[[ $sains == "$attendu " ]]; res $? "10 conteneurs en bonne santé : $sains"

echo "== Cluster"
cfg=$("$MONGOSH" --cible RSCFG --quiet --eval '
  const s = rs.status(); print(s.set, db.hello().configsvr === 2 ? "configsvr" : "?", s.members.map(m => m.stateStr).sort().join(","))' 2>/dev/null)
[[ $cfg == "RSCFG configsvr PRIMARY,SECONDARY,SECONDARY" ]]; res $? "Serveurs de configuration : $cfg"
shards=$("$MONGOSH" --quiet --eval 'print(db.adminCommand({ listShards: 1 }).shards.map(s => s._id + "=" + s.host.split("/")[0]).join(" "))' 2>/dev/null)
[[ $shards == "RS1=RS1 RS2=RS2" ]]; res $? "Shards (nom=replica set) : $shards"
wc=$("$MONGOSH" --quiet --eval 'const r = db.adminCommand({ getDefaultRWConcern: 1 }); print(r.defaultWriteConcern.w, r.defaultWriteConcernSource)' 2>/dev/null)
[[ $wc == "majority global" ]]; res $? "Write concern par défaut du cluster : $wc"
comptes=$("$MONGOSH" --quiet --eval 'print(db.getSiblingDB("admin").getUsers().users.map(u => u.user + ":" + u.roles.map(r => r.role + "@" + r.db).join(",")).sort().join(" "))' 2>/dev/null)
[[ $comptes == "admin:root@admin appli:readWrite@bd511" ]]; res $? "Comptes du cluster : $comptes"
mongosh --quiet "mongodb://mongos1:27017/?appName=bd511-verif" --eval 'db.adminCommand({ listDatabases: 1 })' 2>&1 | grep -q "requires authentication"
res $? "Accès anonyme au routeur refusé"
[[ $("$MONGOSH" --quiet --eval 'print(sh.getBalancerState())' 2>/dev/null) == true ]]; res $? "Balancer actif"

echo "== Collections shardées de bd511"
while read -r coll cle; do
  r=$("$MONGOSH" --quiet --eval "
    const c = db.getSiblingDB('config').collections.findOne({ _id: 'bd511.$coll' });
    const shards = db.getSiblingDB('admin').aggregate([{ \$shardedDataDistribution: {} }, { \$match: { ns: 'bd511.$coll' } }])
      .toArray()[0].shards.filter(s => s.numOwnedDocuments > 0).length;
    print(EJSON.stringify(c.key), db.getCollection('$coll').countDocuments(), shards)" 2>/dev/null)
  [[ $r == "$cle 210000 2" ]]; res $? "$coll : clé, documents, shards occupés = $r"
done <<'LISTE'
ventes {"client":1}
ventes_date {"date":1}
ventes_hash {"client":"hashed"}
ventes_zone {"region":1,"client":1}
LISTE
zones=$("$MONGOSH" --quiet --eval '
  const e = db.ventes_zone.find({ region: "AM" }).explain().queryPlanner.winningPlan;
  print(db.getSiblingDB("config").shards.find().sort({ _id: 1 }).toArray().map(s => s._id + ":" + s.tags).join(" "), "AM->" + e.shards.map(s => s.shardName))' 2>/dev/null)
[[ $zones == "RS1:EUROPE RS2:AMERIQUES AM->RS2" ]]; res $? "Zones : $zones"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
EOF
bash ~/bd511/ch07/verifier-ch07.sh
```

Résultat attendu :

```text
== Conteneurs
  [OK] 10 conteneurs en bonne santé : config1 config2 config3 mongos1 rs11 rs12 rs1arb rs21 rs22 rs2arb 
== Cluster
  [OK] Serveurs de configuration : RSCFG configsvr PRIMARY,SECONDARY,SECONDARY
  [OK] Shards (nom=replica set) : RS1=RS1 RS2=RS2
  [OK] Write concern par défaut du cluster : majority global
  [OK] Comptes du cluster : admin:root@admin appli:readWrite@bd511
  [OK] Accès anonyme au routeur refusé
  [OK] Balancer actif
== Collections shardées de bd511
  [OK] ventes : clé, documents, shards occupés = {"client":1} 210000 2
  [OK] ventes_date : clé, documents, shards occupés = {"date":1} 210000 2
  [OK] ventes_hash : clé, documents, shards occupés = {"client":"hashed"} 210000 2
  [OK] ventes_zone : clé, documents, shards occupés = {"region":1,"client":1} 210000 2
  [OK] Zones : RS1:EUROPE RS2:AMERIQUES AM->RS2

Bilan : 12 OK, 0 KO
```

Enfin, mesurez la mémoire occupée par le cluster :

```bash
sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'
```

Résultat attendu (valeurs variables, ordre quelconque ; ces chiffres comprennent une partie du cache de fichiers du système, en plus de la mémoire propre des processus) :

```text
NAME      MEM USAGE / LIMIT
mongos1   25.3MiB / 1GiB
rs22      401.7MiB / 1GiB
rs2arb    236.1MiB / 512MiB
rs21      341.2MiB / 1GiB
config3   270.1MiB / 1GiB
config2   265.1MiB / 1GiB
config1   264.8MiB / 1GiB
rs12      450.8MiB / 1GiB
rs11      372.8MiB / 1GiB
rs1arb    234.9MiB / 512MiB
```

### 4.3 Ce qu'il faut retenir

- Un cluster shardé associe des **shards** (replica sets `--shardsvr`), des **serveurs de configuration** (replica set `--configsvr`, sans arbitre) et des **routeurs** `mongos`. On les déploie dans cet ordre : configuration, shards, routeurs.
- Les applications passent **toujours** par un routeur. Depuis MongoDB 8.0, un shard refuse les opérations directes des comptes ordinaires.
- Les **comptes du cluster** se créent par le routeur et sont stockés sur les serveurs de configuration ; chaque shard garde des **comptes locaux** pour la maintenance.
- Un shard PSA impose de fixer le **write concern par défaut du cluster** (`setDefaultRWConcern`) avant `addShard`.
- Une collection n'est répartie que si on la **sharde** ; les autres restent sur le **shard primaire** de leur base.
- Le **balancer** équilibre le **volume de données** de chaque collection entre les shards, par migrations de plages, au-delà d'un écart de trois tailles de chunk. Le shard donneur garde des **documents orphelins** pendant une heure, filtrés par le routeur.
- La **clé de sharding** décide de tout : répartition des données et des écritures, ciblage des requêtes. Une clé croissante crée un shard chaud ; le **hachage** répartit uniformément mais diffuse les requêtes par plage ; les **zones** imposent la localisation des données.

### 4.4 Bonnes pratiques de production appliquées

| Pratique | Mise en œuvre dans le TP |
| --- | --- |
| Serveurs de configuration en replica set de trois membres, sans arbitre | RSCFG : `config1`, `config2`, `config3` (partie 1.2) |
| Authentification interne par fichier de clé commun à tous les processus | fichier de clé du chapitre 6, monté dans les dix conteneurs |
| Comptes du cluster et comptes locaux de shard ; exceptions localhost refermées | parties 1.3 et 1.4 |
| Write concern par défaut du cluster explicite | `setDefaultRWConcern` à `majority` (partie 1.6) |
| Accès des applications par le routeur uniquement | `mongosh-cluster`, `importer-ventes.sh` (compte `appli`) |
| Clé de sharding choisie avant le chargement, d'après la cardinalité, la fréquence, la progression et les requêtes | parties 2.3 et 3 |
| Taille de chunk par défaut (128 Mo) | réduite à 1 Mo pour la seule démonstration de la partie 2.5 |
| Fenêtre de balancing, balancer arrêté pendant les sauvegardes | partie 2.9 |
| Arrêt et démarrage ordonnés du cluster | `cluster.sh` (partie 4.1) |
| À faire en production, au-delà du TP | shards PSS sans arbitre ; au moins deux routeurs ; chaque membre sur un serveur distinct ; authentification interne par certificats x.509 plutôt que par fichier de clé |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `00-prerequis.sh` : mémoire disponible insuffisante | VM à 4 Go, ou applications ouvertes | partie 0.1 ; fermez Compass et le navigateur |
| `00-prerequis.sh` : replica set RS1 indisponible | conteneurs RS1 arrêtés (redémarrage de la VM après `docker compose stop`) | `cd ~/bd511/cluster && sudo docker compose up -d --wait` |
| `00-prerequis.sh` : conteneurs du chapitre 7 déjà créés | TP déjà commencé | reprenez à la partie en cours, ou repartez de zéro (annexe C) |
| `docker compose up --wait mongos1` échoue : `mongos1 is unhealthy` | RSCFG pas encore initialisé | partie 1.2, puis relancez la commande |
| `init-rscfg.js` ou `init-rs2.js` : `already initialized` | replica set déjà initialisé | rien à faire ; vérifiez l'état avec `mongosh-cluster --cible RSCFG` ou `--cible RS2` |
| Création des comptes : `command createUser requires authentication` | un compte existe déjà, l'exception localhost est refermée | les comptes sont déjà créés : passez à la suite |
| `addShard` : `Cannot add … implicit default write concern … {w : 1}` | write concern par défaut du cluster non fixé | partie 1.6 |
| `addShard` : `… already a member of the existing shard` | shard déjà ajouté | rien à faire ; vérifiez avec `listShards` |
| `You are connecting to a sharded cluster improperly by connecting directly to a shard` | connexion directe à un shard avec un compte ordinaire | passez par le routeur (`mongosh-cluster` sans `--cible`) |
| `importer-ventes.sh` : `contient déjà des documents` | import déjà fait | rien à faire, ou `db.<collection>.drop()` par le routeur, puis refaites la partie concernée |
| `shardCollection` : `Please create an index that starts with the proposed shard key` | collection non vide sans index sur la clé | `db.ventes.createIndex({ client: 1 })` (partie 2.4) |
| `suivre-balancer.js` s'arrête sans migration (`collection équilibrée`) | taille de chunk restée à 128 Mo, ou balancer déjà passé | vérifiez la partie 2.5 ; consultez `repartition.js` |
| `suivre-balancer.js` : aucune migration avant l'arrêt du suivi | balancer arrêté | `sh.startBalancer()` par le routeur |
| Le nombre de chunks de RS2 pour `ventes` a diminué | fusion des chunks contigus par l'AutoMerger | comportement normal |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `~/bd511/ch07/00-prerequis.sh` | Contrôle de la VM et du cluster du chapitre 6 | 0.2 |
| `~/bd511/ch07/init-rscfg.js` | Initialisation du replica set des serveurs de configuration | 1.2 |
| `~/bd511/ch07/init-rs2.js` | Initialisation du replica set RS2 | 1.3 |
| `~/bd511/ch07/mongosh-cluster` | Connexion par le routeur, ou directe à RSCFG, RS1 ou RS2 | 1.5 |
| `~/bd511/ch07/generer_ventes.py` | Générateur déterministe des 200 000 ventes | 2.1 |
| `~/bd511/ch07/donnees/SHA256SUMS`, `ventes.json` | Empreinte de référence et jeu de données | 2.1 |
| `~/bd511/ch07/importer-ventes.sh` | Import des ventes par le routeur, compte `appli` | 2.2 |
| `~/bd511/ch07/repartition.js` | Répartition d'une collection : documents, volume, chunks, orphelins | 2.4 |
| `~/bd511/ch07/suivre-balancer.js` | Suivi des migrations jusqu'à l'équilibre | 2.6 |
| `~/bd511/ch07/routage.js` | Routage de cinq requêtes types (ciblées ou diffusées) | 2.8 |
| `~/bd511/ch07/inserer-ventes.js` | 10 000 nouvelles ventes et leur répartition par shard | 3.1 |
| `~/bd511/ch07/chunks.js` | Liste des chunks et des zones d'une collection | 3.1 |
| `~/bd511/ch07/cluster.sh` | Arrêt, démarrage et état du cluster, dans l'ordre | 4.1 |
| `~/bd511/ch07/verifier-ch07.sh` | Contrôle final | 4.2 |
| `~/bd511/cluster/` | Projet Docker Compose du chapitre 6, utilisé sans modification | – |
| `/srv/bd511/config1` … `/srv/bd511/rs2arb` | Données des nouveaux membres | 1.2, 1.3 |

## Annexe C – Exploiter le cluster

Toutes ces commandes s'exécutent dans `~/bd511/cluster`.

| Action | Commande |
| --- | --- |
| État des conteneurs du cluster | `bash ~/bd511/ch07/cluster.sh etat` |
| Arrêter, démarrer le cluster dans l'ordre | `bash ~/bd511/ch07/cluster.sh arreter`, `bash ~/bd511/ch07/cluster.sh demarrer` |
| Journal du routeur (JSON) | `sudo docker compose logs --no-log-prefix mongos1 \| jq -c '{t: .t["$date"], msg}'` |
| Migrations du balancer dans le journal du shard donneur | `sudo docker compose logs --no-log-prefix rs11 \| jq -c 'select(.c == "MIGRATE") \| {t: .t["$date"], msg}'` |
| État du balancer | `~/bd511/ch07/mongosh-cluster --quiet --eval 'printjson(sh.isBalancerRunning())'` |

**Repartir de zéro (note formateur).** RS1 porte désormais l'identité d'un shard et des collections shardées : le retirer du cluster serait long (vidage du shard par le balancer, puis retrait). Pour rejouer le TP, on supprime donc les conteneurs et les données de tous les membres, puis on reconstruit RS1 avec les scripts du chapitre 6 (parties 3.2, 3.3 et 3.5) :

```bash
cd ~/bd511/cluster
sudo docker compose --profile sharding down
sudo find /srv/bd511/config1 /srv/bd511/config2 /srv/bd511/config3 /srv/bd511/rs11 /srv/bd511/rs12 /srv/bd511/rs1arb \
  /srv/bd511/rs21 /srv/bd511/rs22 /srv/bd511/rs2arb -mindepth 1 -delete
sudo docker compose up -d --wait
sudo docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin < ~/bd511/ch06/init-rs1.js
sudo docker compose exec -T rs11 mongosh --port 27011 --quiet --file /dev/stdin <<EOF
const admin = db.getSiblingDB("admin");
const wc = { w: "majority", wtimeout: 10000 };
admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: [ "root" ] }, wc);
admin.auth("admin", "$(cat secrets/admin.pwd)");
admin.createUser({ user: "appli", pwd: "$(cat secrets/appli.pwd)", roles: [ { role: "readWrite", db: "bd511" } ] }, wc);
EOF
bash ~/bd511/ch06/importer-rs1.sh
rm -f ~/bd511/ch07/donnees/ventes.json
```

Reprenez ensuite à la partie 0.2. La base `bd511` ne contient alors que les collections `formations`, `inscriptions` et `stagiaires` (partie 1.7).

## Annexe D – Références

- Architecture : [Sharding](https://www.mongodb.com/docs/manual/sharding/), [Sharded Cluster Components](https://www.mongodb.com/docs/manual/core/sharded-cluster-components/), [Config Servers](https://www.mongodb.com/docs/manual/core/sharded-cluster-config-servers/), [mongos](https://www.mongodb.com/docs/manual/core/sharded-cluster-query-router/)
- Déploiement : [Deploy a Self-Managed Sharded Cluster](https://www.mongodb.com/docs/manual/tutorial/deploy-shard-cluster/), [Deploy Sharded Cluster with Keyfile Authentication](https://www.mongodb.com/docs/manual/tutorial/deploy-sharded-cluster-with-keyfile-access-control/), [addShard](https://www.mongodb.com/docs/manual/reference/command/addShard/), [setDefaultRWConcern](https://www.mongodb.com/docs/manual/reference/command/setDefaultRWConcern/), [directShardOperations](https://www.mongodb.com/docs/manual/reference/built-in-roles/#mongodb-authrole-directShardOperations)
- Clés et méthodes : [Shard Keys](https://www.mongodb.com/docs/manual/core/sharding-shard-key/), [Choose a Shard Key](https://www.mongodb.com/docs/manual/core/sharding-choose-a-shard-key/), [Hashed Sharding](https://www.mongodb.com/docs/manual/core/hashed-sharding/), [Ranged Sharding](https://www.mongodb.com/docs/manual/core/ranged-sharding/), [Zones](https://www.mongodb.com/docs/manual/core/zone-sharding/), [Reshard a Collection](https://www.mongodb.com/docs/manual/core/sharding-reshard-a-collection/)
- Balancer : [Sharded Cluster Balancer](https://www.mongodb.com/docs/manual/core/sharding-balancer-administration/), [Manage Sharded Cluster Balancer](https://www.mongodb.com/docs/manual/tutorial/manage-sharded-cluster-balancer/), [configureCollectionBalancing](https://www.mongodb.com/docs/manual/reference/command/configureCollectionBalancing/), [$shardedDataDistribution](https://www.mongodb.com/docs/manual/reference/operator/aggregation/shardedDataDistribution/), [Long-Running Secondary Reads (`orphanCleanupDelaySecs`)](https://www.mongodb.com/docs/manual/core/long-running-secondary-reads/)
- Version : [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
