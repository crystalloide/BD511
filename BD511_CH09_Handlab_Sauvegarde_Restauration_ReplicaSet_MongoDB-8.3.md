# BD511 – Chapitre 9 – Handlab : sauvegarde cohérente d'un replica set avec `mongodump --oplog` et restauration avec `mongorestore --oplogReplay`

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 9 – Sauvegarde, restauration et maintenance |
| **Durée indicative** | 1 h 30 |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop des chapitres précédents (2 vCPU, 4 Go de RAM) : Docker Engine et image `mongo:8.3.13` du chapitre 6, mongosh et Database Tools du chapitre 2 ; 1,5 Go de mémoire disponible, 5 Go libres sur le disque |
| **Versions vérifiées le 25/10/2026** | MongoDB Community Server **8.3.13** (image Docker officielle `mongo:8.3.13`) · mongosh **2.13.0** · Database Tools **100.19.1** (`mongodump`, `mongorestore`, `bsondump`) · Docker Engine **29.9.2** · Docker Compose **5.6.1** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. déployer un **replica set de trois membres porteurs de données** (PSS) avec les réglages de production, et des **comptes dédiés** à la sauvegarde et à la restauration ;
2. réaliser une **sauvegarde à chaud cohérente** avec `mongodump --oplog`, lue sur un secondaire, compressée, protégée et contrôlée par sommes de contrôle ;
3. **tester une restauration** sur une instance isolée, et démontrer qu'une sauvegarde logique n'est cohérente qu'une fois son oplog rejoué (`mongorestore --oplogReplay`) ;
4. après une suppression accidentelle, **restaurer le replica set à l'instant qui précède l'incident** : sauvegarde complète, puis rejeu de l'oplog sauvegardé jusqu'à l'incident (`--oplogLimit`).

## Le scénario

La boutique en ligne du cours gère son catalogue (`bd511.articles`, 20 000 articles) et ses commandes (`bd511.commandes`, 400 000 commandes) sur un replica set. Chaque commande est une **transaction** : le stock de l'article diminue de la quantité commandée **et** la commande est enregistrée, ou rien du tout. Pour chaque article, une règle est donc toujours vraie :

> **stock initial = stock restant + somme des quantités commandées**

L'application passe des commandes en continu, y compris pendant la sauvegarde : il n'y a pas de fenêtre d'arrêt. La sauvegarde doit pourtant restituer une boutique où la règle est vraie. Plus tard, un script de purge supprime par erreur la collection des commandes : il faudra revenir à l'état exact de la boutique juste avant cette erreur.

## L'architecture

Le replica set RS1 des chapitres 6 et 7 est devenu un **shard** : on ne sauvegarde pas un shard isolément, et `mongodump` n'est pas une méthode de sauvegarde pour un cluster shardé (partie 4 du cours). Ce TP déploie donc un replica set dédié, **RS9**, avec la même image Docker. Il suit le modèle **PSS** (*Primary-Secondary-Secondary*) recommandé en production : trois copies des données, et une majorité qui reste disponible si un membre tombe.

```text
                  VM Ubuntu (hôte Docker) - réseau « bd511-rs9 » 192.168.109.0/24
  ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐  ┌──────────────────────────┐
  │ rs91      .11 : 27091    │  │ rs92      .12 : 27092    │  │ rs93      .13 : 27093    │  │ restau    .20 : 27099    │
  │ PRIMARY   (priorité 2)   │─►│ SECONDARY                │  │ SECONDARY                │  │ instance de test isolée  │
  │ /srv/bd511-rs9/rs91      │  │ /srv/bd511-rs9/rs92      │  │ /srv/bd511-rs9/rs93      │  │ (profil Compose « test ») │
  └────────────▲─────────────┘  └────────────┬─────────────┘  └──────────────────────────┘  └────────────▲─────────────┘
               │ commandes (transactions)    │ mongodump --oplog : lecture sur un secondaire              │ tests de
        application boutique.js              ▼                                                            │ restauration
                                ~/BD511/sauvegardes (disque système, mode 700) ───────────────────────────┘
```

Les données sont sur un **volume XFS dédié** (`/srv/bd511-rs9`) ; les sauvegardes sont sur un **autre support** (le disque système). Une sauvegarde rangée sur le disque des données disparaîtrait avec lui.

## Organisation des fichiers

| Répertoire | Contenu |
| --- | --- |
| `~/BD511/ch09` | scripts du TP et jeu de données (`donnees/`) |
| `~/BD511/rs9` | projet Docker Compose du replica set RS9 : `docker-compose.yml`, `conf/`, `secrets/` (mode 700) |
| `~/BD511/sauvegardes` | sauvegardes complètes (`complete-<date>`) et sauvegardes de l'oplog (`oplog-<date>`), mode 700 |
| `/srv/bd511-rs9` | volume XFS des données : un répertoire par `mongod` |

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Préparation de la VM | 5 min |
| 1 | Déploiement du replica set RS9 et de ses comptes | 20 min |
| 2 | Jeu de données et application | 10 min |
| 3 | Sauvegarde cohérente avec `mongodump --oplog` | 15 min |
| 4 | Test de restauration sur une instance isolée, avec et sans `--oplogReplay` | 15 min |
| 5 | Incident, sauvegarde de l'oplog et restauration à un instant précis | 20 min |
| 6 | Bilan | 5 min |

## Conventions

- Les commandes s'exécutent dans un terminal (`Ctrl` + `Alt` + `T`). Les commandes Docker utilisent `sudo`, comme aux chapitres 6 et 7.
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Les heures, durées, horodatages (`Timestamp`), identifiants, chemins (`/home/stagiaire` : votre répertoire personnel) et les compteurs liés à l'activité de l'application (nombre de commandes, d'entrées d'oplog, écarts) varient d'une VM à l'autre ; tout le reste est identique.
- Chaque bloc retrouve lui-même la dernière sauvegarde (`ls -d ~/BD511/sauvegardes/complete-* | tail -n 1`) : il fonctionne dans n'importe quel terminal.

---

## Partie 0 – Préparer la VM

### 0.1 Libérer la mémoire et créer l'espace de travail

Le cluster shardé du chapitre 7 et la supervision du chapitre 8 occupent plus de 2 Go de mémoire : arrêtez-les, s'ils tournent encore. Leurs données sont conservées ; l'annexe C explique comment les relancer.

```bash
sudo docker ps -q -f name='^mongos1$' | grep -q . && bash ~/bd511/ch07/cluster.sh arreter
[ -f ~/BD511/supervision/docker-compose.yml ] && (cd ~/BD511/supervision && sudo docker compose stop)
mkdir -p ~/BD511/ch09/donnees ~/BD511/rs9/conf
install -d -m 700 ~/BD511/sauvegardes
```

Docker Compose affiche les conteneurs qu'il arrête (`✔ Container grafana Stopped`…) ; rien ne s'affiche si tout était déjà arrêté.

### 0.2 Contrôler les prérequis

```bash
cat > ~/BD511/ch09/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.9 : vérifie la VM avant le TP de sauvegarde et de restauration
# (Docker et image mongo:8.3.13 du chapitre 6, Database Tools, mémoire, disque, réseau et noms libres)
# Usage : bash ~/BD511/ch09/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Docker (chapitre 6)"
if sudo docker info >/dev/null 2>&1; then
  ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}'), Compose $(sudo docker compose version --short)"
else nok "Docker inactif ou absent : sudo systemctl start docker"; fi
if sudo docker image inspect mongo:8.3.13 >/dev/null 2>&1; then ok "Image mongo:8.3.13 présente"
else nok "Image mongo:8.3.13 absente : sudo docker pull mongo:8.3.13"; fi
actifs=$(sudo docker ps --format '{{.Names}}' | grep -cE '^(rs1[12]|rs1arb|rs2[12]|rs2arb|config[123]|mongos[12]|grafana|prometheus|mongodb-exporter)$')
if (( actifs == 0 )); then ok "Cluster du chapitre 7 et supervision du chapitre 8 arrêtés"
else nok "${actifs} conteneur(s) des chapitres 7 et 8 encore actif(s) : partie 0.1"; fi

echo "== Outils"
for outil in mongosh mongodump mongorestore bsondump mongoimport jq python3 openssl; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done
v=$(mongodump --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == 100.* ]]; then ok "Database Tools $v"; else nok "Database Tools 100.x attendues (trouvé : ${v:-aucune})"; fi

echo "== Ressources de la VM"
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; voir l'annexe A"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 5 )); then ok "Espace libre sur / : ${libre} Go (5 Go requis : volume de 3 Go et sauvegardes)"
else nok "Espace libre sur / : ${libre} Go (5 Go requis : volume de 3 Go et sauvegardes)"; fi

echo "== Réseau et noms"
if ip -4 route | grep -q '^192\.168\.109\.' && ! sudo docker network inspect bd511-rs9 >/dev/null 2>&1; then
  nok "Le réseau 192.168.109.0/24 est déjà utilisé sur la VM"
else ok "Réseau 192.168.109.0/24 disponible pour RS9"; fi
for nom in rs91 rs92 rs93 restau; do
  adresse=$(getent hosts "$nom" | awk '{print $1}')
  if [[ -z $adresse || $adresse == 192.168.109.* ]]; then ok "Nom $nom libre ou déjà réservé à RS9"
  else nok "Le nom $nom désigne déjà $adresse"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch09/00-prerequis.sh
```

Résultat attendu (valeurs variables) :

```text
== Docker (chapitre 6)
  [OK] Docker Engine 29.9.2, Compose 5.6.1
  [OK] Image mongo:8.3.13 présente
  [OK] Cluster du chapitre 7 et supervision du chapitre 8 arrêtés
== Outils
  [OK] mongosh présent
  [OK] mongodump présent
  [OK] mongorestore présent
  [OK] bsondump présent
  [OK] mongoimport présent
  [OK] jq présent
  [OK] python3 présent
  [OK] openssl présent
  [OK] Database Tools 100.19.1
== Ressources de la VM
  [OK] Mémoire disponible : 2104 Mo (1 536 Mo requis)
  [OK] Espace libre sur / : 8 Go (5 Go requis : volume de 3 Go et sauvegardes)
== Réseau et noms
  [OK] Réseau 192.168.109.0/24 disponible pour RS9
  [OK] Nom rs91 libre ou déjà réservé à RS9
  [OK] Nom rs92 libre ou déjà réservé à RS9
  [OK] Nom rs93 libre ou déjà réservé à RS9
  [OK] Nom restau libre ou déjà réservé à RS9

Résultat : VM prête pour le TP.
```

---

## Partie 1 – Déployer le replica set RS9

Les étapes sont celles du chapitre 6, regroupées en scripts.

### 1.1 Créer le volume XFS des données

Comme aux chapitres 2 et 6, les données vont sur un volume **XFS** monté en **`noatime`**, simulé par un fichier image de 3 Go. Le script crée un répertoire par `mongod`, propriété de l'uid 999 (compte `mongodb` de l'image), et empêche Docker de démarrer avant le montage du volume.

```bash
cat > ~/BD511/ch09/volume-rs9.sh <<'EOF'
#!/usr/bin/env bash
# volume-rs9.sh - BD511 ch.9 : volume XFS dédié (noatime) aux données du replica set RS9
# Simule un disque dédié par un fichier image monté en boucle sur /srv/bd511-rs9, puis crée un répertoire
# de données par mongod : rs91, rs92, rs93 (membres du replica set) et restau (instance de test des restaurations).
# Les sauvegardes, elles, iront sur un autre support (~/BD511/sauvegardes, sur le disque système).
# Usage : sudo bash ~/BD511/ch09/volume-rs9.sh [taille_en_Go]
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

TAILLE_GO=${1:-3}
IMAGE=/var/lib/bd511-rs9-xfs.img
POINT=/srv/bd511-rs9
UID_MONGODB=999      # utilisateur mongodb de l'image officielle mongo (uid et gid 999)

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
    mkfs.xfs -q -f -L bd511rs9 "$IMAGE"
  fi
  if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
    cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
    printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
  fi
  systemctl daemon-reload
  mount "$POINT"
fi
chmod 0755 "$POINT"
for rep in rs91 rs92 rs93 restau; do
  install -d -m 0750 -o "$UID_MONGODB" -g "$UID_MONGODB" "$POINT/$rep"
done

# Docker ne doit pas démarrer les conteneurs si le volume n'est pas monté
install -d /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/bd511-rs9-volume.conf <<CONF
# BD511 ch.9 : les conteneurs du replica set RS9 ont besoin du volume de données $POINT
[Unit]
RequiresMountsFor=$POINT
CONF
systemctl daemon-reload

findmnt "$POINT"
ls -ln "$POINT"
EOF
sudo bash ~/BD511/ch09/volume-rs9.sh
```

Résultat attendu (le numéro du périphérique `loop` varie ; selon le noyau, l'option `attr2` peut figurer dans la liste) :

```text
Création de /var/lib/bd511-rs9-xfs.img (3 Go)...
Formatage XFS...
TARGET         SOURCE      FSTYPE OPTIONS
/srv/bd511-rs9 /dev/loop10 xfs    rw,noatime,inode64,logbufs=8,logbsize=32k,noquota
total 0
drwxr-x--- 2 999 999 6 oct.  25 17:02 restau
drwxr-x--- 2 999 999 6 oct.  25 17:02 rs91
drwxr-x--- 2 999 999 6 oct.  25 17:02 rs92
drwxr-x--- 2 999 999 6 oct.  25 17:02 rs93
```

### 1.2 Déclarer les noms des membres

```bash
cat > ~/BD511/ch09/hosts-rs9.sh <<'EOF'
#!/usr/bin/env bash
# hosts-rs9.sh - BD511 ch.9 : déclare les noms des membres de RS9 et de l'instance de test dans /etc/hosts
# (les conteneurs se résolvent entre eux par le DNS de Docker ; la VM, elle, passe par /etc/hosts).
# Le bloc est délimité par deux marqueurs : le script peut être relancé sans créer de doublons.
# Usage : sudo bash ~/BD511/ch09/hosts-rs9.sh
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
DEBUT="# >>> BD511 replica set RS9 (généré par hosts-rs9.sh)"
FIN="# <<< BD511 replica set RS9"

cp /etc/hosts "/etc/hosts.bak-$(date +%Y%m%d%H%M%S)"
sed -i "/^${DEBUT}\$/,/^${FIN}\$/d" /etc/hosts
cat >> /etc/hosts <<BLOC
$DEBUT
192.168.109.11	rs91
192.168.109.12	rs92
192.168.109.13	rs93
192.168.109.20	restau
$FIN
BLOC
sed -n "/^${DEBUT}\$/,/^${FIN}\$/p" /etc/hosts
EOF
sudo bash ~/BD511/ch09/hosts-rs9.sh
```

Résultat attendu :

```text
# >>> BD511 replica set RS9 (généré par hosts-rs9.sh)
192.168.109.11	rs91
192.168.109.12	rs92
192.168.109.13	rs93
192.168.109.20	restau
# <<< BD511 replica set RS9
```

### 1.3 Générer le fichier de clé et les mots de passe

Le fichier de clé authentifie les membres entre eux. Quatre comptes recevront chacun un mot de passe de 24 caractères. Pour les trois comptes utilisés par les Database Tools, un petit fichier de configuration (`--config`) contient le mot de passe : il n'apparaîtra jamais sur une ligne de commande.

```bash
cd ~/BD511/rs9
install -d -m 700 secrets
openssl rand -base64 756 > secrets/keyfile
chmod 400 secrets/keyfile
sudo chown 999:999 secrets/keyfile
for compte in admin appli sauvegarde restauration; do
  ( umask 077; openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 > "secrets/$compte.pwd" )
done
for compte in appli sauvegarde restauration; do
  ( umask 077; printf 'password: "%s"\n' "$(< "secrets/$compte.pwd")" > "secrets/$compte.yaml" )
done
ls -ln secrets
```

Résultat attendu (uid de votre compte et dates variables) :

```text
total 32
-rw------- 1 1000 1000   24 oct.  25 17:02 admin.pwd
-rw------- 1 1000 1000   24 oct.  25 17:02 appli.pwd
-rw------- 1 1000 1000   37 oct.  25 17:02 appli.yaml
-r-------- 1  999  999 1024 oct.  25 17:02 keyfile
-rw------- 1 1000 1000   24 oct.  25 17:02 restauration.pwd
-rw------- 1 1000 1000   37 oct.  25 17:02 restauration.yaml
-rw------- 1 1000 1000   24 oct.  25 17:02 sauvegarde.pwd
-rw------- 1 1000 1000   37 oct.  25 17:02 sauvegarde.yaml
```

### 1.4 Écrire la configuration des `mongod`

La configuration commune aux trois membres de RS9 :

```bash
cat > ~/BD511/rs9/conf/mongod.conf <<'EOF'
# mongod.conf - BD511 ch.9 : configuration commune aux trois membres du replica set RS9
# Montée en lecture seule dans chaque conteneur : /etc/mongo/mongod.conf
# Les réglages propres à chaque membre (port, adresse d'écoute) sont passés en ligne de commande dans docker-compose.yml.

storage:
  dbPath: /data/db                 # volume XFS de l'hôte (/srv/bd511-rs9/<membre>) monté sur /data/db
  wiredTiger:
    engineConfig:
      # Plusieurs mongod partagent la même machine : le cache de chacun est borné explicitement.
      cacheSizeGB: 0.25
  # Fenêtre minimale de l'oplog : 24 h d'historique au moins, même si l'oplog dépasse oplogSizeMB.
  # Elle doit couvrir l'intervalle entre deux sauvegardes de l'oplog (restauration à un instant précis).
  oplogMinRetentionHours: 24

# Pas de section systemLog : le journal part sur la sortie standard, collectée par Docker
# (docker compose logs), avec la rotation définie dans /etc/docker/daemon.json (chapitre 6).

security:
  keyFile: /etc/mongo/keyfile      # authentification interne des membres
  authorization: enabled           # contrôle d'accès des clients

replication:
  replSetName: RS9
  oplogSizeMB: 1024                # taille de l'oplog choisie explicitement
EOF
```

Celle de l'instance de test des restaurations, un `mongod` autonome :

```bash
cat > ~/BD511/rs9/conf/restau.conf <<'EOF'
# restau.conf - BD511 ch.9 : instance isolée de test des restaurations (mongod autonome, hors replica set)
# Montée en lecture seule dans le conteneur restau : /etc/mongo/restau.conf

storage:
  dbPath: /data/db                 # /srv/bd511-rs9/restau sur l'hôte
  wiredTiger:
    engineConfig:
      cacheSizeGB: 0.25

net:
  port: 27099
  bindIp: localhost,192.168.109.20

security:
  authorization: enabled           # une copie des données de production se protège comme la production
EOF
```

| Réglage | Valeur | Pourquoi |
| --- | --- | --- |
| trois membres porteurs de données | `rs91`, `rs92`, `rs93` | modèle PSS : on peut sauvegarder sur un secondaire sans affaiblir la haute disponibilité |
| `oplogSizeMB` | 1024 | taille de l'oplog choisie explicitement |
| `oplogMinRetentionHours` | 24 | l'oplog garde au moins 24 h d'historique, même au-delà de sa taille : c'est la profondeur maximale d'une restauration à un instant précis à partir de la dernière sauvegarde de l'oplog |
| `cacheSizeGB` | 0.25 | plusieurs `mongod` partagent la VM |
| `keyFile`, `authorization` | activés | authentification interne et contrôle d'accès, y compris sur l'instance de test : une copie des données de production se protège comme la production |

### 1.5 Écrire le fichier Docker Compose et démarrer RS9

Le fichier reprend les choix du chapitre 6 : version d'image figée, adresses fixes, redémarrage automatique, arrêt propre, limites recommandées. L'instance de test porte le profil `test` : elle ne démarre que sur demande (partie 4).

```bash
cat > ~/BD511/rs9/docker-compose.yml <<'EOF'
# docker-compose.yml - BD511 ch.9 : replica set RS9 (trois membres porteurs de données) et instance de test
#   - services sans profil : rs91, rs92, rs93       -> replica set de production RS9
#   - profil « test »      : restau                 -> instance isolée de test des restaurations
# Usage : cd ~/BD511/rs9 && sudo docker compose up -d --wait
name: rs9

# Réglages communs à tous les mongod (ancre YAML reprise par chaque service)
x-mongodb: &mongodb
  image: mongo:8.3.13              # même image qu'aux chapitres 6 et 7, version figée
  restart: unless-stopped
  stop_grace_period: 1m            # temps laissé à mongod pour s'arrêter proprement
  mem_limit: 1g
  ulimits:                         # limites recommandées par les notes de production MongoDB
    nofile: { soft: 64000, hard: 64000 }
    nproc: { soft: 64000, hard: 64000 }

services:
  rs91:
    <<: *mongodb
    container_name: rs91
    hostname: rs91
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27091", "--bind_ip", "localhost,192.168.109.11"]
    networks:
      rs9: { ipv4_address: 192.168.109.11 }
    volumes:
      - /srv/bd511-rs9/rs91:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27091", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs92:
    <<: *mongodb
    container_name: rs92
    hostname: rs92
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27092", "--bind_ip", "localhost,192.168.109.12"]
    networks:
      rs9: { ipv4_address: 192.168.109.12 }
    volumes:
      - /srv/bd511-rs9/rs92:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27092", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  rs93:
    <<: *mongodb
    container_name: rs93
    hostname: rs93
    command: ["--config", "/etc/mongo/mongod.conf", "--port", "27093", "--bind_ip", "localhost,192.168.109.13"]
    networks:
      rs9: { ipv4_address: 192.168.109.13 }
    volumes:
      - /srv/bd511-rs9/rs93:/data/db
      - ./conf/mongod.conf:/etc/mongo/mongod.conf:ro
      - ./secrets/keyfile:/etc/mongo/keyfile:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27093", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

  # Instance isolée de test des restaurations : mongod autonome, ne fait pas partie de RS9
  restau:
    <<: *mongodb
    profiles: ["test"]
    container_name: restau
    hostname: restau
    command: ["--config", "/etc/mongo/restau.conf"]
    networks:
      rs9: { ipv4_address: 192.168.109.20 }
    volumes:
      - /srv/bd511-rs9/restau:/data/db
      - ./conf/restau.conf:/etc/mongo/restau.conf:ro
      - /etc/localtime:/etc/localtime:ro
    healthcheck:
      test: ["CMD", "mongosh", "--port", "27099", "--quiet", "--norc", "--eval", "db.adminCommand('ping')"]
      start_period: 1m
      start_interval: 2s

networks:
  rs9:
    name: bd511-rs9
    ipam:
      config:
        - subnet: 192.168.109.0/24
          gateway: 192.168.109.1
EOF
cd ~/BD511/rs9
sudo docker compose config --quiet && echo "docker-compose.yml : OK"
sudo docker compose up -d --wait
sudo docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
```

Résultat attendu (durées variables) :

```text
docker-compose.yml : OK
[+] up 4/4
 ✔ Network bd511-rs9 Created                                                    0.1s
 ✔ Container rs92    Healthy                                                   12.1s
 ✔ Container rs93    Healthy                                                   12.1s
 ✔ Container rs91    Healthy                                                   12.6s
NAME      IMAGE          STATUS
rs91      mongo:8.3.13   Up 13 seconds (healthy)
rs92      mongo:8.3.13   Up 13 seconds (healthy)
rs93      mongo:8.3.13   Up 13 seconds (healthy)
```

### 1.6 Initialiser RS9 et créer les comptes

Le script s'exécute dans le conteneur `rs91` grâce à l'**exception localhost** : tant qu'aucun compte n'existe, une connexion locale peut initialiser le replica set et créer le premier utilisateur.

```bash
cat > ~/BD511/ch09/init-rs9.sh <<'EOF'
#!/usr/bin/env bash
# init-rs9.sh - BD511 ch.9 : initialise le replica set RS9 et crée ses comptes
# Exécuté dans le conteneur rs91 grâce à l'exception localhost (aucun compte n'existe encore).
# Les mots de passe sont lus dans ~/BD511/rs9/secrets et transmis à mongosh par l'entrée standard.
#   admin        : root                         administration
#   appli        : readWrite sur bd511          application de la boutique
#   sauvegarde   : backup                       mongodump (données, comptes et oplog)
#   restauration : restore + rejeuOplog         mongorestore, y compris le rejeu de l'oplog (--oplogReplay)
# Usage : bash ~/BD511/ch09/init-rs9.sh      (demande le mot de passe sudo pour docker compose)
set -euo pipefail
cd "$HOME/BD511/rs9"
mdp() { cat "secrets/$1.pwd"; }

sudo docker compose exec -T rs91 mongosh --port 27091 --quiet --norc --file /dev/stdin <<JS
if (db.hello().setName) { print("RS9 est déjà initialisé : rien à faire."); quit(1); }
const r = rs.initiate({ _id: "RS9", members: [
  { _id: 0, host: "rs91:27091", priority: 2 },     // primaire préféré
  { _id: 1, host: "rs92:27092", priority: 1 },
  { _id: 2, host: "rs93:27093", priority: 1 } ] });
print("rs.initiate :", r.ok === 1 ? "ok" : EJSON.stringify(r));
for (let i = 0; i < 60 && !db.hello().isWritablePrimary; i++) sleep(1000);
print("rs91 primaire :", db.hello().isWritablePrimary);

const admin = db.getSiblingDB("admin"), wc = { w: "majority", wtimeout: 30000 };
admin.createUser({ user: "admin", pwd: "$(mdp admin)", roles: ["root"] }, wc);
admin.auth("admin", "$(mdp admin)");
// Rejouer l'oplog (mongorestore --oplogReplay) exige l'action anyAction sur anyResource :
// rôle réservé au compte de restauration, comme le recommande la documentation de mongorestore.
admin.createRole({ role: "rejeuOplog", privileges: [{ resource: { anyResource: true }, actions: ["anyAction"] }], roles: [] }, wc);
admin.createUser({ user: "appli", pwd: "$(mdp appli)", roles: [{ role: "readWrite", db: "bd511" }] }, wc);
admin.createUser({ user: "sauvegarde", pwd: "$(mdp sauvegarde)", roles: ["backup"] }, wc);
admin.createUser({ user: "restauration", pwd: "$(mdp restauration)", roles: ["restore", "rejeuOplog"] }, wc);
for (const u of admin.getUsers().users.sort((a, b) => a.user.localeCompare(b.user)))
  print(u.user.padEnd(13), u.roles.map(x => x.role + "@" + x.db).sort().join(", "));
JS
EOF
bash ~/BD511/ch09/init-rs9.sh
```

Résultat attendu :

```text
rs.initiate : ok
rs91 primaire : true
admin         root@admin
appli         readWrite@bd511
restauration  rejeuOplog@admin, restore@admin
sauvegarde    backup@admin
```

| Compte | Rôles | Usage |
| --- | --- | --- |
| `admin` | `root` | administration |
| `appli` | `readWrite` sur `bd511` | application de la boutique ; import du jeu de données |
| `sauvegarde` | `backup` | `mongodump` : lecture de toutes les bases, des comptes et de l'oplog |
| `restauration` | `restore`, `rejeuOplog` | `mongorestore` ; le rôle `rejeuOplog` (action `anyAction` sur `anyResource`) est exigé pour rejouer l'oplog, comme l'indique la documentation de `mongorestore` |

> **Le compte de restauration est un super-utilisateur** : rejouer l'oplog revient à exécuter n'importe quelle opération. On le réserve aux restaurations ; en production, on lui retire le rôle `rejeuOplog`, ou on change son mot de passe, en dehors de ces opérations.

### 1.7 Se connecter au replica set

Le script suivant ouvre mongosh sur la base `bd511` de RS9 (cible par défaut), d'un membre précis, ou de l'instance de test, avec l'un des quatre comptes (`appli` par défaut) :

```bash
cat > ~/BD511/ch09/mongosh-rs9 <<'EOF'
#!/usr/bin/env bash
# mongosh-rs9 - BD511 ch.9 : ouvre mongosh sur la base bd511 du replica set RS9, d'un de ses membres,
# ou de l'instance de test restau. Le mot de passe est lu dans ~/BD511/rs9/secrets/<compte>.pwd ; mongosh le
# masque ensuite dans la liste des processus. Compte par défaut : appli ; cible par défaut : rs9.
#   --compte appli|admin|sauvegarde|restauration
#   --cible  rs9 (replica set, lectures et écritures sur le primaire) | rs91 | rs92 | rs93 (un membre) | restau
# Nom d'application (opérations en cours, journaux) : bd511-ch09-<compte>, ou $APPNAME.
# Usage : ~/BD511/ch09/mongosh-rs9 [--compte admin] [--cible restau] [options et scripts mongosh...]
set -euo pipefail
compte=appli; cible=rs9
while [[ ${1:-} == --compte || ${1:-} == --cible ]]; do
  case $1 in --compte) compte=$2 ;; --cible) cible=$2 ;; esac
  shift 2
done
case $cible in
  rs9)            hotes="rs91:27091,rs92:27092,rs93:27093"; options="replicaSet=RS9" ;;
  rs91|rs92|rs93) hotes="$cible:2709${cible: -1}"; options="directConnection=true" ;;
  restau)         hotes="restau:27099"; options="directConnection=true" ;;
  *) echo "Cible inconnue : $cible (rs9, rs91, rs92, rs93 ou restau)" >&2; exit 1 ;;
esac
mdp=$(< "$HOME/BD511/rs9/secrets/$compte.pwd")
exec mongosh "mongodb://$compte:$mdp@$hotes/bd511?$options&authSource=admin&appName=${APPNAME:-bd511-ch09-$compte}" "$@"
EOF
chmod +x ~/BD511/ch09/mongosh-rs9
~/BD511/ch09/mongosh-rs9 --compte admin --quiet --eval '
  rs.status().members.forEach(m => print(m.name, m.stateStr));
  rs.printReplicationInfo()'
```

Résultat attendu (dates variables) :

```text
rs91:27091 PRIMARY
rs92:27092 SECONDARY
rs93:27093 SECONDARY
actual oplog size
'1024 MB'
---
configured oplog size
'1024 MB'
---
log length start to end
'11 secs (0 hrs)'
---
oplog first event time
'Sun Oct 25 2026 17:03:03 GMT+0100 (heure normale d’Europe centrale)'
---
oplog last event time
'Sun Oct 25 2026 17:03:14 GMT+0100 (heure normale d’Europe centrale)'
---
now
'Sun Oct 25 2026 17:03:15 GMT+0100 (heure normale d’Europe centrale)'
```

La **fenêtre de l'oplog** (*log length start to end*) mesure l'historique disponible. Elle grandira avec l'activité, jusqu'à la limite fixée par la taille de l'oplog et sa durée de rétention minimale.

---

## Partie 2 – Charger les données et démarrer l'application

### 2.1 Générer le jeu de données

Le générateur est **déterministe** : il produit toujours exactement les mêmes fichiers, dont les empreintes SHA-256 sont connues. Les mêmes fichiers, compressés, sont fournis dans l'archive du TP.

```bash
cat > ~/BD511/ch09/generer_donnees.py <<'EOF'
#!/usr/bin/env python3
"""generer_donnees.py - BD511 ch.9 : génère le catalogue et l'historique des commandes de la boutique en ligne.

Deux fichiers JSON (un document par ligne, format Extended JSON de MongoDB) dans le répertoire indiqué :
  articles.json   20 000 articles : stock initial, stock restant, prix ;
  commandes.json 400 000 commandes passées depuis le 01/01/2025 : article, quantité, montant.
Pour chaque article, stockInitial = stock + somme des quantités commandées : c'est l'invariant que la
sauvegarde devra préserver. Le générateur est déterministe (graine fixe) : il produit toujours exactement
les mêmes fichiers, dont les sommes de contrôle figurent dans donnees/SHA256SUMS.
Usage : python3 ~/BD511/ch09/generer_donnees.py ~/BD511/ch09/donnees
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

NB_ARTICLES, NB_COMMANDES, NB_CLIENTS = 20_000, 400_000, 50_000
CATEGORIES = ["livres", "musique", "jeux", "informatique", "maison", "jardin", "sport", "jouets"]
DEBUT = datetime(2025, 1, 1, tzinfo=timezone.utc)
DUREE_S = int((datetime(2026, 10, 1, tzinfo=timezone.utc) - DEBUT).total_seconds())

alea = random.Random(511)
dossier = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
dossier.mkdir(parents=True, exist_ok=True)

prix = [round(alea.uniform(2, 300), 2) for _ in range(NB_ARTICLES)]
commande_par_article = [0] * NB_ARTICLES
instants = sorted(alea.randrange(DUREE_S) for _ in range(NB_COMMANDES))   # commandes numérotées dans l'ordre chronologique

with open(dossier / "commandes.json", "w", encoding="utf-8") as f:
    for numero, instant in enumerate(instants, start=1):
        a = alea.randrange(NB_ARTICLES)
        quantite = alea.choice([1, 1, 1, 1, 2, 2, 3, 4, 5])
        commande_par_article[a] += quantite
        date = (DEBUT + timedelta(seconds=instant)).strftime("%Y-%m-%dT%H:%M:%SZ")
        f.write(json.dumps({"_id": numero, "date": {"$date": date}, "client": f"C{1 + alea.randrange(NB_CLIENTS):05d}",
                            "article": f"ART{a + 1:05d}", "quantite": quantite,
                            "montant": round(quantite * prix[a], 2)}, separators=(",", ":")) + "\n")

with open(dossier / "articles.json", "w", encoding="utf-8") as f:
    for a in range(NB_ARTICLES):
        stock = alea.randrange(200, 2000)                       # stock restant aujourd'hui
        f.write(json.dumps({"_id": f"ART{a + 1:05d}", "libelle": f"Article {a + 1}",
                            "categorie": CATEGORIES[a % len(CATEGORIES)], "prix": prix[a],
                            "stockInitial": stock + commande_par_article[a], "stock": stock},
                           separators=(",", ":")) + "\n")

print(f"{NB_ARTICLES} articles, {NB_COMMANDES} commandes, {sum(commande_par_article)} unités commandées")
EOF
cat > ~/BD511/ch09/donnees/SHA256SUMS <<'EOF'
d24b99a193e3736e7b5a2e201061b07e923acc7aa83a2e8fcbf99fc65aa33ee2  articles.json
a9f75d2031097b8f92df42fd8c6d7e8422cb0a165c8c0ad0899a695396c74ff2  commandes.json
EOF
python3 ~/BD511/ch09/generer_donnees.py ~/BD511/ch09/donnees
cd ~/BD511/ch09/donnees && sha256sum -c SHA256SUMS
```

Résultat attendu (en quelques secondes) :

```text
20000 articles, 400000 commandes, 889297 unités commandées
articles.json: Réussi
commandes.json: Réussi
```

### 2.2 Importer les données dans RS9

L'import passe par le compte `appli`, avec des écritures confirmées par la majorité des membres (`w: "majority"`). Le script crée ensuite l'index de la « fiche client » sur les commandes.

```bash
cat > ~/BD511/ch09/importer-donnees.sh <<'EOF'
#!/usr/bin/env bash
# importer-donnees.sh - BD511 ch.9 : (ré)importe le catalogue et les commandes dans la base bd511 de RS9
# Compte appli (mot de passe dans ~/BD511/rs9/secrets/appli.yaml), écritures confirmées par la majorité des membres.
# Les collections sont recréées (--drop), puis l'index de la « fiche client » est créé sur les commandes.
# Usage : bash ~/BD511/ch09/importer-donnees.sh
set -euo pipefail
CH09="$HOME/BD511/ch09"
cd "$CH09/donnees"
sha256sum --quiet --check SHA256SUMS || { echo "Fichiers différents de la référence (partie 2.1)." >&2; exit 1; }
debut=$SECONDS
for collection in articles commandes; do
  mongoimport --uri "mongodb://appli@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&appName=bd511-ch09-import" \
    --config "$HOME/BD511/rs9/secrets/appli.yaml" --db bd511 --collection "$collection" --drop --file "$collection.json" \
    --writeConcern '{ w: "majority" }' --numInsertionWorkers 2 --quiet
done
"$CH09/mongosh-rs9" --quiet --eval '
  db.commandes.createIndex({ client: 1, date: -1 });
  for (const c of ["articles", "commandes"])
    print(`bd511.${c} : ${db[c].countDocuments()} documents, index : ${db[c].getIndexes().map(i => i.name).join(", ")}`)'
echo "Import terminé en $((SECONDS - debut)) s"
EOF
bash ~/BD511/ch09/importer-donnees.sh
```

Résultat attendu (durée variable) :

```text
bd511.articles : 20000 documents, index : _id_
bd511.commandes : 400000 documents, index : _id_, client_1_date_-1
Import terminé en 21 s
```

### 2.3 Vérifier la règle de la boutique

Le script de contrôle calcule, pour la base entière et pour chaque article, si le stock initial est bien égal au stock restant plus les quantités commandées. Sur un replica set, il lit toutes les données dans un **même instantané** (session `snapshot`) : le contrôle reste exact pendant que l'application écrit.

```bash
cat > ~/BD511/ch09/coherence.js <<'EOF'
// coherence.js - BD511 ch.9 : vérifie l'invariant de la boutique sur la base bd511
//   pour chaque article : stockInitial = stock + somme des quantités de ses commandes
// Sur un replica set, toutes les lectures se font dans un même instantané (session « snapshot ») : le contrôle
// est exact même pendant que l'application écrit. Sur l'instance de test (mongod autonome), lectures ordinaires.
// Usage : ~/BD511/ch09/mongosh-rs9 [--cible restau] --quiet ~/BD511/ch09/coherence.js
const fmt = v => v.toLocaleString("fr-FR");
const replicaSet = Boolean(db.hello().setName);
const session = replicaSet ? db.getMongo().startSession({ snapshot: true }) : null;
const base = session ? session.getDatabase("bd511") : db.getSiblingDB("bd511");

const a = base.articles.aggregate([{ $group: { _id: null, n: { $sum: 1 }, initial: { $sum: "$stockInitial" },
                                                stock: { $sum: "$stock" } } }]).toArray()[0] ?? { n: 0, initial: 0, stock: 0 };
const c = base.commandes.aggregate([{ $group: { _id: null, n: { $sum: 1 }, quantite: { $sum: "$quantite" } } }])
  .toArray()[0] ?? { n: 0, quantite: 0 };
const parArticle = new Map(base.commandes.aggregate([{ $group: { _id: "$article", q: { $sum: "$quantite" } } }])
  .toArray().map(x => [x._id, x.q]));
let incoherents = 0;
base.articles.find({}, { stockInitial: 1, stock: 1 }).forEach(x => {
  if (x.stockInitial - x.stock !== (parArticle.get(x._id) ?? 0)) incoherents++;
});
const ecart = a.initial - a.stock - c.quantite;
const h = db.hello();
const cible = replicaSet ? `${h.me.split(":")[0]} (${h.isWritablePrimary ? "primaire" : "secondaire"} de ${h.setName})` : "restau (instance de test)";
print(`bd511 sur ${cible} : ${fmt(a.n)} articles, ${fmt(c.n)} commandes`);
print(`  stock initial ${fmt(a.initial)} = stock restant ${fmt(a.stock)} + quantités commandées ${fmt(c.quantite)} : ` +
      (ecart === 0 ? "COHÉRENT" : `INCOHÉRENT (écart de ${ecart > 0 ? "+" : ""}${fmt(ecart)} unités)`));
print(`  articles incohérents : ${fmt(incoherents)}`);
if (session) session.endSession();
EOF
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu :

```text
bd511 sur rs91 (primaire de RS9) : 20 000 articles, 400 000 commandes
  stock initial 22 884 242 = stock restant 21 994 945 + quantités commandées 889 297 : COHÉRENT
  articles incohérents : 0
```

### 2.4 Démarrer l'application

L'application passe 10 commandes par seconde, chacune dans une transaction, et écrit un bilan toutes les 10 secondes. Elle tourne en arrière-plan (deux heures au plus) jusqu'à la partie 5 ; elle s'arrête proprement (fin de la transaction en cours) quand on le lui demande.

```bash
cat > ~/BD511/ch09/boutique.js <<'EOF'
// boutique.js - BD511 ch.9 : l'application de la boutique en ligne, qui passe des commandes en continu
// Chaque commande est une transaction multi-documents : le stock de l'article diminue de la quantité commandée
// ET la commande est enregistrée, ou rien du tout. Pour chaque article, stockInitial = stock + quantités commandées.
// L'application vise RYTHME commandes par seconde (10 par défaut) pendant DUREE secondes (7200 par défaut) et
// s'arrête proprement dès que le fichier ~/BD511/ch09/boutique.stop existe. Toutes les 10 s, elle écrit un bilan.
// Usage : lancé par boutique.sh (~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/boutique.js)
const fs = require("fs");
const STOP = process.env.HOME + "/BD511/ch09/boutique.stop";
const rythme = Number(process.env.RYTHME || 10), duree = Number(process.env.DUREE || 7200);
const intervalle = 1000 / rythme, fin = Date.now() + duree * 1000;
const heure = () => new Date().toTimeString().slice(0, 8);
const hasard = n => Math.floor(Math.random() * n);
const QUANTITES = [1, 1, 1, 1, 2, 2, 3, 4, 5];

const session = db.getMongo().startSession();
const articles = session.getDatabase("bd511").articles, commandes = session.getDatabase("bd511").commandes;
let bilan = { commandes: 0, ruptures: 0, erreurs: 0, ms: 0 }, prochainBilan = Date.now() + 10000;
print(`${heure()}  début : ${rythme} commandes/s visées`);
while (Date.now() < fin && !fs.existsSync(STOP)) {
  const article = "ART" + String(1 + hasard(20000)).padStart(5, "0"), quantite = QUANTITES[hasard(QUANTITES.length)];
  const t0 = Date.now();
  try {
    session.withTransaction(() => {
      const a = articles.findOneAndUpdate({ _id: article, stock: { $gte: quantite } }, { $inc: { stock: -quantite } },
                                          { projection: { prix: 1 } });
      if (!a) { bilan.ruptures++; return; }                       // stock insuffisant : rien n'est écrit
      commandes.insertOne({ date: new Date(), client: "C" + String(1 + hasard(50000)).padStart(5, "0"), article,
                            quantite, montant: Math.round(quantite * a.prix * 100) / 100 });
      bilan.commandes++;
    });
  } catch (e) {
    bilan.erreurs++;
    print(`${heure()}  erreur : ${e.codeName ?? ""} ${e.message}`);
    sleep(1000);
  }
  bilan.ms += Date.now() - t0;
  if (Date.now() >= prochainBilan) {
    const n = bilan.commandes + bilan.ruptures;
    print(`${heure()}  commandes ${bilan.commandes} (moy. ${n ? Math.round(bilan.ms / n) : 0} ms), ruptures ${bilan.ruptures}, erreurs ${bilan.erreurs}`);
    bilan = { commandes: 0, ruptures: 0, erreurs: 0, ms: 0 }; prochainBilan += 10000;
  }
  sleep(Math.max(0, intervalle - (Date.now() - t0)));
}
session.endSession();
print(`${heure()}  fin`);
EOF
cat > ~/BD511/ch09/boutique.sh <<'EOF'
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
EOF
bash ~/BD511/ch09/boutique.sh demarrer
sleep 25
cat ~/BD511/ch09/boutique.log
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu (valeurs variables) :

```text
Application démarrée (journal : ~/BD511/ch09/boutique.log)
17:03:48  début : 10 commandes/s visées
17:03:58  commandes 101 (moy. 13 ms), ruptures 0, erreurs 0
17:04:08  commandes 98 (moy. 17 ms), ruptures 0, erreurs 0
bd511 sur rs91 (primaire de RS9) : 20 000 articles, 400 268 commandes
  stock initial 22 884 242 = stock restant 21 994 326 + quantités commandées 889 916 : COHÉRENT
  articles incohérents : 0
```

Le stock restant diminue, les quantités commandées augmentent d'autant : la règle reste vraie à chaque instant, grâce aux transactions.

---

## Partie 3 – Sauvegarder RS9 avec `mongodump --oplog`

L'application tourne toujours : la sauvegarde se fait à chaud.

### 3.1 Le problème : une sauvegarde logique dure

`mongodump` lit les collections une par une, document par document. La lecture prend du temps (quelques secondes ici, des heures sur une grosse base) et les écritures continuent pendant ce temps : chaque collection, voire chaque partie d'une collection, est copiée à un instant différent. Une commande validée pendant la sauvegarde peut ainsi figurer dans la copie de `commandes`, alors que la copie de `articles`, déjà terminée, contient encore l'ancien stock. La copie brute ne correspond à **aucun** état réel de la base.

L'option **`--oplog`** corrige ce défaut. Pendant toute la durée de la copie, `mongodump` enregistre aussi les entrées de l'**oplog** du membre qu'il lit, dans un fichier `oplog.bson`. À la restauration, `mongorestore --oplogReplay` recharge les collections, puis **rejoue** ces entrées : la base arrive dans l'état exact où elle était à la **fin** de la sauvegarde.

```text
   début de la sauvegarde                                              fin de la sauvegarde
          │  copie de articles ──┐                                             │
          │  copie de commandes ─┼──────────────────────────────────────────┐  │
          │◄──────────────── entrées de l'oplog enregistrées (oplog.bson) ──┼─►│
          ▼                      ▼                                          ▼  ▼
   restauration = collections copiées (instants différents) + rejeu de l'oplog = état exact à la fin
```

Le rejeu fonctionne parce que les entrées de l'oplog sont **idempotentes** : elles décrivent le résultat (« le stock de ART09980 vaut 1147 ») et non l'opération (« diminuer le stock de 1 »). Rejouer une entrée sur un document déjà à jour ne change rien.

### 3.2 Lancer la sauvegarde complète

```bash
SAUV=~/BD511/sauvegardes/complete-$(date +%Y%m%d-%H%M%S)
( umask 077
  mongodump --uri "mongodb://sauvegarde@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&readPreference=secondary&appName=bd511-ch09-sauvegarde" \
    --config ~/BD511/rs9/secrets/sauvegarde.yaml --oplog --gzip --out "$SAUV" )
```

Résultat attendu (chemins, heures et nombres de documents variables ; `bd511.articles` et `bd511.commandes` sont copiées en parallèle) :

```text
2026-10-25T17:04:18.735+0100	writing `admin.system.users` to `/home/stagiaire/BD511/sauvegardes/complete-20261025-170418/admin/system.users.bson.gz`
2026-10-25T17:04:18.738+0100	done dumping `admin.system.users` (4 documents)
2026-10-25T17:04:18.738+0100	writing `admin.system.roles` to `/home/stagiaire/BD511/sauvegardes/complete-20261025-170418/admin/system.roles.bson.gz`
2026-10-25T17:04:18.742+0100	done dumping `admin.system.roles` (1 document)
2026-10-25T17:04:18.742+0100	writing `admin.system.version` to `/home/stagiaire/BD511/sauvegardes/complete-20261025-170418/admin/system.version.bson.gz`
2026-10-25T17:04:18.743+0100	done dumping `admin.system.version` (1 document)
2026-10-25T17:04:18.743+0100	writing `bd511.commandes` to `/home/stagiaire/BD511/sauvegardes/complete-20261025-170418/bd511/commandes.bson.gz`
2026-10-25T17:04:18.743+0100	writing `bd511.articles` to `/home/stagiaire/BD511/sauvegardes/complete-20261025-170418/bd511/articles.bson.gz`
2026-10-25T17:04:18.857+0100	done dumping `bd511.articles` (20000 documents)
2026-10-25T17:04:21.006+0100	done dumping `bd511.commandes` (400322 documents)
2026-10-25T17:04:21.009+0100	writing captured oplog to ``
2026-10-25T17:04:21.010+0100		dumped 24 oplog entries
```

| Élément | Rôle |
| --- | --- |
| `--oplog` | enregistre les entrées de l'oplog écrites pendant la copie : la sauvegarde devient cohérente. Il ne fonctionne que sur un membre de replica set, et pour une copie de toute l'instance (pas de `--db` ni de `--collection`) |
| `readPreference=secondary` | la copie est lue sur un secondaire : le primaire, qui sert l'application, n'en supporte pas la charge |
| compte `sauvegarde`, `--config` | rôle `backup` seul ; le mot de passe est lu dans un fichier, jamais passé en ligne de commande |
| `--gzip` | chaque fichier est compressé (ici, 9 Mo au lieu de 42 Mo) |
| `umask 077` | la sauvegarde contient toutes les données **et** les comptes (empreintes des mots de passe) : elle n'est lisible que par vous |
| `--out` | un répertoire horodaté par sauvegarde |

Les 24 entrées d'oplog sont les commandes validées pendant les 2 secondes de la copie.

### 3.3 Compléter et protéger la sauvegarde

Deux compléments rendent la sauvegarde exploitable :

- un fichier `sauvegarde.json`, qui note l'horodatage de la **dernière entrée de l'oplog** : c'est l'instant exact que restitue la sauvegarde, et le point de départ des sauvegardes de l'oplog (partie 5) ;
- un fichier `SHA256SUMS`, avec l'empreinte de chaque fichier : on vérifiera l'intégrité de la sauvegarde avant de la restaurer.

Attention : avec `--gzip`, le fichier `oplog.bson` est **compressé**, malgré son nom. `bsondump`, qui convertit un fichier BSON en JSON, le lit donc après `gunzip`.

```bash
SAUV=$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)
( umask 077
  FIN=$(gunzip -c < "$SAUV/oplog.bson" | bsondump --quiet | tail -n 1 | jq -c '.ts')
  printf '{"sauvegarde":"complete","replicaSet":"RS9","finOplog":%s}\n' "$FIN" > "$SAUV/sauvegarde.json"
  cd "$SAUV" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS )
cat "$SAUV/sauvegarde.json"
du -sh "$SAUV"
cd "$SAUV" && find . -type f | sort | xargs ls -l | awk '{ print $1, $5, $9 }'
```

Résultat attendu (horodatage, tailles et chemins variables) :

```text
{"sauvegarde":"complete","replicaSet":"RS9","finOplog":{"$timestamp":{"t":1792944260,"i":10}}}
8,5M	/home/stagiaire/BD511/sauvegardes/complete-20261025-170418
-rw------- 141 ./admin/system.roles.bson.gz
-rw------- 184 ./admin/system.roles.metadata.json.gz
-rw------- 1158 ./admin/system.users.bson.gz
-rw------- 188 ./admin/system.users.metadata.json.gz
-rw------- 78 ./admin/system.version.bson.gz
-rw------- 157 ./admin/system.version.metadata.json.gz
-rw------- 367033 ./bd511/articles.bson.gz
-rw------- 153 ./bd511/articles.metadata.json.gz
-rw------- 8439141 ./bd511/commandes.bson.gz
-rw------- 181 ./bd511/commandes.metadata.json.gz
-rw------- 1638 ./oplog.bson
-rw------- 66 ./prelude.json.gz
-rw------- 95 ./sauvegarde.json
-rw------- 1232 ./SHA256SUMS
```

| Fichier | Contenu |
| --- | --- |
| `<base>/<collection>.bson.gz` | les documents de la collection, au format BSON compressé |
| `<base>/<collection>.metadata.json.gz` | options de la collection et **définitions** de ses index : les index ne sont pas copiés, ils seront reconstruits à la restauration |
| `admin/system.users`, `admin/system.roles` | les comptes et les rôles de l'instance |
| `oplog.bson` | les entrées de l'oplog enregistrées pendant la copie (compressées) |
| `prelude.json.gz` | versions du serveur et des outils |

### 3.4 Regarder l'oplog enregistré

```bash
SAUV=$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)
gunzip -c < "$SAUV/oplog.bson" | bsondump --quiet | jq -s -r '
  "\(length) entrées, de \(.[0].ts["$timestamp"].t | strflocaltime("%H:%M:%S")) à \(.[-1].ts["$timestamp"].t | strflocaltime("%H:%M:%S"))",
  (group_by(.op + " " + .ns)[] | "  \(length) × op \(.[0].op) sur \(.[0].ns)")'
gunzip -c < "$SAUV/oplog.bson" | bsondump --quiet | head -n 1 | jq '{ ts: .ts["$timestamp"], op, ns,
  transaction: .txnNumber["$numberLong"],
  operations: [.o.applyOps[] | if .op == "u" then "u \(.ns) \(.o2._id) : stock = \(.o.diff.u.stock["$numberInt"])"
                                else "i \(.ns) : article \(.o.article), quantité \(.o.quantite["$numberInt"])" end] }'
```

Résultat attendu (valeurs variables) :

```text
24 entrées, de 17:04:18 à 17:04:20
  24 × op c sur admin.$cmd
{
  "ts": {
    "t": 1792944258,
    "i": 7
  },
  "op": "c",
  "ns": "admin.$cmd",
  "transaction": "303",
  "operations": [
    "u bd511.articles ART09980 : stock = 1147",
    "i bd511.commandes : article ART09980, quantité 1"
  ]
}
```

Chaque transaction validée est **une** entrée de l'oplog, de type commande (`op: "c"`), qui regroupe ses opérations dans un tableau `applyOps` : ici, la mise à jour du stock (`u`) et l'insertion de la commande (`i`). Le champ `ts` (*timestamp* : secondes depuis 1970 et numéro d'ordre dans la seconde) ordonne toutes les entrées : c'est lui qui servira à désigner un instant précis en partie 5.

---

## Partie 4 – Tester la restauration sur une instance isolée

Une sauvegarde qu'on n'a jamais restaurée n'est qu'une hypothèse. On la teste sur une instance **isolée** : jamais sur la production.

### 4.1 Démarrer l'instance de test

```bash
cat > ~/BD511/ch09/init-restau.sh <<'EOF'
#!/usr/bin/env bash
# init-restau.sh - BD511 ch.9 : démarre l'instance isolée de test des restaurations (conteneur restau)
# et y crée, par l'exception localhost, les comptes admin et restauration : mêmes rôles et mêmes mots de passe
# que sur RS9, pour que les comptes contenus dans les sauvegardes restent utilisables après une restauration.
# Usage : bash ~/BD511/ch09/init-restau.sh      (demande le mot de passe sudo pour docker compose)
set -euo pipefail
cd "$HOME/BD511/rs9"
sudo docker compose --profile test up -d --wait restau
sudo docker compose exec -T restau mongosh --port 27099 --quiet --norc --file /dev/stdin <<JS
const admin = db.getSiblingDB("admin");
try {
  admin.createUser({ user: "admin", pwd: "$(cat secrets/admin.pwd)", roles: ["root"] });
} catch (e) { print("restau est déjà initialisée : rien à faire."); quit(0); }
admin.auth("admin", "$(cat secrets/admin.pwd)");
admin.createRole({ role: "rejeuOplog", privileges: [{ resource: { anyResource: true }, actions: ["anyAction"] }], roles: [] });
admin.createUser({ user: "restauration", pwd: "$(cat secrets/restauration.pwd)", roles: ["restore", "rejeuOplog"] });
print("restau : comptes", admin.getUsers().users.map(u => u.user).sort().join(", "), "; bases :",
      admin.runCommand({ listDatabases: 1, nameOnly: true }).databases.map(d => d.name).sort().join(", "));
JS
EOF
bash ~/BD511/ch09/init-restau.sh
```

Résultat attendu (fin de l'affichage) :

```text
[+] up 1/1
 ✔ Container restau Healthy                                                     5.6s
restau : comptes admin, restauration ; bases : admin, config, local
```

### 4.2 Restaurer sans rejouer l'oplog

Commencez par vérifier l'intégrité de la sauvegarde, puis restaurez-la **sans** `--oplogReplay` : c'est exactement ce qu'aurait donné une sauvegarde sans `--oplog`.

```bash
SAUV=$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)
(cd "$SAUV" && sha256sum --quiet -c SHA256SUMS) && echo "$(basename "$SAUV") : intègre"
mongorestore --uri "mongodb://restauration@restau:27099/?authSource=admin&appName=bd511-ch09-restauration" \
  --config ~/BD511/rs9/secrets/restauration.yaml --gzip --dir "$SAUV" 2>&1 | tail -n 1
~/BD511/ch09/mongosh-rs9 --cible restau --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu (nombres et écart variables) :

```text
complete-20261025-170418 : intègre
2026-10-25T17:04:32.251+0100	420322 document(s) restored successfully. 0 document(s) failed to restore.
bd511 sur restau (instance de test) : 20 000 articles, 400 322 commandes
  stock initial 22 884 242 = stock restant 21 994 239 + quantités commandées 890 044 : INCOHÉRENT (écart de -41 unités)
  articles incohérents : 19
```

La copie brute est **incohérente** : des commandes validées pendant la sauvegarde y figurent, sans la baisse de stock correspondante (ou l'inverse). Une telle base mettrait en vente des articles déjà vendus. Le nombre d'articles incohérents dépend du nombre de commandes passées pendant la copie, mais il n'est jamais nul quand l'application écrit.

### 4.3 Restaurer en rejouant l'oplog

On recommence sur une base vide : supprimez la base `bd511` de l'instance de test, puis restaurez avec `--oplogReplay`.

```bash
SAUV=$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)
~/BD511/ch09/mongosh-rs9 --cible restau --compte restauration --quiet --eval 'printjson(db.dropDatabase())'
mongorestore --uri "mongodb://restauration@restau:27099/?authSource=admin&appName=bd511-ch09-restauration" \
  --config ~/BD511/rs9/secrets/restauration.yaml --gzip --oplogReplay --dir "$SAUV" 2>&1 \
  | grep -E 'replaying oplog|applied|restored successfully|Failed'
~/BD511/ch09/mongosh-rs9 --cible restau --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu (nombres variables) :

```text
{
  ok: 1,
  dropped: 'bd511'
}
2026-10-25T17:04:45.840+0100	replaying oplog
2026-10-25T17:04:45.876+0100	applied 48 oplog entries
2026-10-25T17:04:47.020+0100	420322 document(s) restored successfully. 0 document(s) failed to restore.
bd511 sur restau (instance de test) : 20 000 articles, 400 326 commandes
  stock initial 22 884 242 = stock restant 21 994 188 + quantités commandées 890 054 : COHÉRENT
  articles incohérents : 0
```

Après le rejeu des 24 transactions (48 opérations), la base est **cohérente** : elle restitue la boutique telle qu'elle était à la fin de la sauvegarde, à la commande près. La sauvegarde est validée.

| Restauration | Commandes | Règle de la boutique |
| --- | --- | --- |
| collections seules | copiées à des instants différents | **violée** |
| collections + `--oplogReplay` | état exact à la fin de la sauvegarde | respectée |

> **Pourquoi supprimer la base au lieu d'utiliser `--drop` ?** L'option `--drop` supprime chaque collection avant de la restaurer, mais elle **remplace aussi les comptes** de l'instance par ceux de la sauvegarde. Sur l'instance de test, le compte `restauration` a été créé localement : `--drop` le remplacerait en pleine restauration, et la suite échouerait (`Command applyOps requires authentication`). Sans `--drop`, `mongorestore` ajoute les comptes absents et laisse les autres en place. Sur RS9, d'où vient la sauvegarde, les comptes sont identiques : la partie 5 y utilise `--drop`.

### 4.4 Arrêter l'instance de test

L'instance de test a rempli son rôle : arrêtez-la pour libérer sa mémoire. Elle garde ses données et pourra servir au prochain test.

```bash
cd ~/BD511/rs9 && sudo docker compose --profile test stop restau
```

Résultat attendu :

```text
[+] stop 1/1
 ✔ Container restau Stopped                                                     0.6s
```

---

## Partie 5 – Restaurer RS9 à l'instant qui précède un incident

La sauvegarde complète restitue la boutique telle qu'elle était à la fin de la sauvegarde. Les commandes passées depuis n'y sont pas : restaurer seulement cette sauvegarde les ferait perdre. Pour revenir à un **instant précis** (*point-in-time recovery*), on rejoue en plus l'oplog écrit depuis la sauvegarde, en s'arrêtant juste avant l'instant choisi.

### 5.1 L'incident

Un script de purge, lancé avec le compte de l'application, devait supprimer l'ancienne collection `commandes_archive`. Une erreur de nom lui fait supprimer `commandes` :

```bash
cat > ~/BD511/ch09/incident.js <<'EOF'
// incident.js - BD511 ch.9 : l'incident à réparer. Un script de purge, lancé avec le compte de l'application,
// devait supprimer l'ancienne collection commandes_archive ; une erreur de nom lui fait supprimer commandes.
// Le script note l'heure et le nombre de commandes juste avant la suppression, pour vérifier la restauration.
// Usage : ~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/incident.js
const collection = "commandes";                       // l'erreur : "commandes" au lieu de "commandes_archive"
const avant = db.getCollection(collection).countDocuments();
print(`${new Date().toTimeString().slice(0, 8)}  purge de bd511.${collection} (${avant} documents)`);
db.getCollection(collection).drop();
print(`${new Date().toTimeString().slice(0, 8)}  collection bd511.${collection} supprimée`);
EOF
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/incident.js
sleep 15
tail -n 2 ~/BD511/ch09/boutique.log
```

Résultat attendu (heures et nombres variables) :

```text
17:04:54  purge de bd511.commandes (400651 documents)
17:04:54  collection bd511.commandes supprimée
17:04:58  commandes 100 (moy. 13 ms), ruptures 0, erreurs 0
17:05:08  commandes 100 (moy. 11 ms), ruptures 0, erreurs 0
```

L'application ne remarque rien : sa prochaine transaction recrée automatiquement la collection `commandes`, vide, et continue d'y enregistrer les nouvelles commandes.

### 5.2 Constater les dégâts et arrêter l'application

Le contrôle de cohérence, lui, révèle l'incident. Le premier réflexe est d'arrêter les écritures : chaque nouvelle commande s'ajoute à une base fausse.

```bash
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/coherence.js
bash ~/BD511/ch09/boutique.sh arreter
```

Résultat attendu (nombres variables) :

```text
bd511 sur rs91 (primaire de RS9) : 20 000 articles, 163 commandes
  stock initial 22 884 242 = stock restant 21 993 075 + quantités commandées 369 : INCOHÉRENT (écart de +890 798 unités)
  articles incohérents : 20 000
Application arrêtée : 17:05:08  commandes 100 (moy. 11 ms), ruptures 0, erreurs 0
```

### 5.3 Sauvegarder l'oplog

L'oplog de RS9 contient tout ce qui s'est passé depuis la sauvegarde complète : les commandes d'avant l'incident, l'incident lui-même, et les commandes d'après. On le copie **avant** toute restauration : la restauration ajoutera ses propres entrées à l'oplog, et l'oplog, de taille limitée, finit toujours par effacer ses entrées les plus anciennes.

Le script suivant copie les entrées postérieures à la fin de la sauvegarde complète (`finOplog` de son fichier `sauvegarde.json`), après avoir vérifié que l'oplog les contient encore toutes. En production, ce même script tourne à intervalles réguliers (toutes les heures, par exemple) : c'est la **sauvegarde incrémentale** qui permet de restaurer à n'importe quel instant.

```bash
cat > ~/BD511/ch09/sauvegarder-oplog.sh <<'EOF'
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
EOF
bash ~/BD511/ch09/sauvegarder-oplog.sh "$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)"
```

Résultat attendu (dates et nombre d'entrées variables) :

```text
Oplog disponible depuis le 25/10/2026 17:03:03 : il couvre la fin de la sauvegarde complète (25/10/2026 17:04:20)
oplog-20261025-170514 : 493 entrées, du 25/10/2026 17:04:21 au 25/10/2026 17:05:10
```

### 5.4 Situer l'incident dans l'oplog sauvegardé

L'incident est une entrée de commande (`op: "c"`) qui supprime une collection (`drop`). Cherchez-la dans la sauvegarde de l'oplog, et non dans l'oplog de RS9, que les restaurations vont modifier :

```bash
OPLOG=$(ls -d ~/BD511/sauvegardes/oplog-* | tail -n 1)
bsondump --quiet "$OPLOG/local/oplog.rs.bson" | jq -c 'select(.op == "c" and .o.drop) | {
  heure: (.wall["$date"]["$numberLong"] | tonumber / 1000 | strflocaltime("%H:%M:%S")), ts: .ts["$timestamp"], ns, o,
  documents: (.o2.numRecords | if type == "object" then (to_entries[0].value | tonumber) else . end) }'
```

Résultat attendu (heure, horodatage et nombre de documents variables) :

```text
{"heure":"17:04:54","ts":{"t":1792944294,"i":3},"ns":"bd511.$cmd","o":{"drop":"commandes"},"documents":400652}
```

L'horodatage `ts` (ici `1792944294:3`) désigne l'incident sans ambiguïté, même si d'autres opérations ont eu lieu dans la même seconde. L'entrée indique aussi le nombre de documents supprimés : c'est le nombre de commandes que la restauration doit retrouver. Il peut dépasser d'une ou deux unités celui qu'a affiché le script de purge : des commandes ont pu être validées entre son comptage et la suppression.

### 5.5 Restaurer la sauvegarde complète

On restaure sur le replica set, par son primaire ; les secondaires reçoivent les données par la réplication. Vérifiez d'abord l'intégrité des deux sauvegardes.

L'option `--drop` supprime chaque collection avant de la restaurer : la collection `commandes` recréée après l'incident disparaît. Elle remplace aussi les comptes de la base `admin` par ceux de la sauvegarde, identiques ici, puisque la sauvegarde vient de RS9.

```bash
SAUV=$(ls -d ~/BD511/sauvegardes/complete-* | tail -n 1)
OPLOG=$(ls -d ~/BD511/sauvegardes/oplog-* | tail -n 1)
(cd "$SAUV" && sha256sum --quiet -c SHA256SUMS) && (cd "$OPLOG" && sha256sum --quiet -c SHA256SUMS) \
  && echo "Sauvegardes intègres : $(basename "$SAUV"), $(basename "$OPLOG")"
mongorestore --uri "mongodb://restauration@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&appName=bd511-ch09-restauration" \
  --config ~/BD511/rs9/secrets/restauration.yaml --gzip --drop --oplogReplay --dir "$SAUV" 2>&1 \
  | grep -E 'dropping|replaying oplog|applied|restored successfully|Failed'
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu (nombres variables, identiques à ceux de la partie 4.3) :

```text
Sauvegardes intègres : complete-20261025-170418, oplog-20261025-170514
2026-10-25T17:05:14.489+0100	dropping collection `bd511.commandes` before restoring
2026-10-25T17:05:14.489+0100	dropping collection `bd511.articles` before restoring
2026-10-25T17:05:26.222+0100	replaying oplog
2026-10-25T17:05:26.341+0100	applied 48 oplog entries
2026-10-25T17:05:28.306+0100	420322 document(s) restored successfully. 0 document(s) failed to restore.
bd511 sur rs91 (primaire de RS9) : 20 000 articles, 400 326 commandes
  stock initial 22 884 242 = stock restant 21 994 188 + quantités commandées 890 054 : COHÉRENT
  articles incohérents : 0
```

La boutique est revenue à la fin de la sauvegarde complète : cohérente, mais il manque les commandes passées ensuite.

### 5.6 Rejouer l'oplog jusqu'à l'incident

`--oplogFile` désigne la sauvegarde de l'oplog ; `--oplogLimit` arrête le rejeu **avant** l'entrée indiquée : l'incident et tout ce qui le suit sont exclus. Comme il n'y a aucune collection à recharger, `--dir` désigne un répertoire vide.

```bash
OPLOG=$(ls -d ~/BD511/sauvegardes/oplog-* | tail -n 1)
LIMITE=$(bsondump --quiet "$OPLOG/local/oplog.rs.bson" \
  | jq -r 'select(.op == "c" and .o.drop == "commandes") | .ts["$timestamp"] | "\(.t):\(.i)"' | head -n 1)
echo "Rejeu de $(basename "$OPLOG") jusqu'à l'incident exclu : --oplogLimit $LIMITE"
mongorestore --uri "mongodb://restauration@rs91:27091,rs92:27092,rs93:27093/?replicaSet=RS9&authSource=admin&appName=bd511-ch09-restauration" \
  --config ~/BD511/rs9/secrets/restauration.yaml --oplogReplay --oplogFile "$OPLOG/local/oplog.rs.bson" \
  --oplogLimit "$LIMITE" --dir "$(mktemp -d)" 2>&1 | grep -E 'replaying oplog|applied|Failed'
~/BD511/ch09/mongosh-rs9 --quiet ~/BD511/ch09/coherence.js
```

Résultat attendu (nombres variables ; le rejeu prend de quelques secondes à une ou deux minutes, selon le temps écoulé entre la sauvegarde complète et l'incident) :

```text
Rejeu de oplog-20261025-170514 jusqu'à l'incident exclu : --oplogLimit 1792944294:3
2026-10-25T17:05:33.674+0100	replaying oplog
2026-10-25T17:05:36.022+0100	applied 652 oplog entries
bd511 sur rs91 (primaire de RS9) : 20 000 articles, 400 652 commandes
  stock initial 22 884 242 = stock restant 21 993 444 + quantités commandées 890 798 : COHÉRENT
  articles incohérents : 0
```

La base compte de nouveau **exactement** le nombre de commandes de l'entrée `drop` (partie 5.4), et la règle de la boutique est respectée : RS9 est revenu à l'instant qui précède l'incident.

| Étape | Commandes | Règle |
| --- | --- | --- |
| juste avant l'incident | 400 652 | respectée |
| après l'incident (5.2) | 163 | **violée** |
| sauvegarde complète restaurée (5.5) | 400 326 | respectée, mais commandes récentes manquantes |
| + oplog rejoué jusqu'à l'incident (5.6) | 400 652 | respectée, rien ne manque |

### 5.7 Vérifier les secondaires

La restauration est passée par le primaire ; les secondaires ont reçu les mêmes écritures par la réplication. Contrôlez-les directement :

```bash
for membre in rs92 rs93; do ~/BD511/ch09/mongosh-rs9 --cible "$membre" --quiet ~/BD511/ch09/coherence.js | head -n 2; done
```

Résultat attendu (mêmes nombres qu'en 5.6) :

```text
bd511 sur rs92 (secondaire de RS9) : 20 000 articles, 400 652 commandes
  stock initial 22 884 242 = stock restant 21 993 444 + quantités commandées 890 798 : COHÉRENT
bd511 sur rs93 (secondaire de RS9) : 20 000 articles, 400 652 commandes
  stock initial 22 884 242 = stock restant 21 993 444 + quantités commandées 890 798 : COHÉRENT
```

### 5.8 Remettre l'application en service

```bash
bash ~/BD511/ch09/boutique.sh demarrer
sleep 15
bash ~/BD511/ch09/boutique.sh etat
```

Résultat attendu :

```text
Application démarrée (journal : ~/BD511/ch09/boutique.log)
17:06:04  commandes 101 (moy. 12 ms), ruptures 0, erreurs 0
```

Deux remarques d'exploitation :

- les commandes enregistrées **après** l'incident (entre la purge et l'arrêt de l'application) ont été écartées avec lui : elles avaient été passées sur une base sans historique. On les retrouverait dans la sauvegarde de l'oplog, ou dans les journaux de l'application, pour les ressaisir ;
- en production, on prend une **nouvelle sauvegarde complète** juste après une restauration : elle devient la référence des sauvegardes suivantes de l'oplog.

---

## Partie 6 – Bilan

### 6.1 Contrôle final

```bash
cat > ~/BD511/ch09/verifier-ch09.sh <<'EOF'
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
EOF
bash ~/BD511/ch09/verifier-ch09.sh
```

Résultat attendu :

```text
== Replica set RS9
  [OK] Données sur un volume XFS monté en noatime : /srv/bd511-rs9
  [OK] Membres : rs91:PRIMARY rs92:SECONDARY rs93:SECONDARY
  [OK] Réglages (oplog en Mo, rétention en h, cache en Go, contrôle d'accès, keyFile) : 1024 24 0.25 enabled true
  [OK] Comptes : admin:root appli:readWrite restauration:rejeuOplog+restore sauvegarde:backup
== Sauvegardes
  [OK] Répertoire des sauvegardes réservé à son propriétaire (mode 700)
  [OK] Sauvegarde complète intègre, avec son oplog : complete-20261025-170418
  [OK] Sauvegarde de l'oplog intègre : oplog-20261025-170514
== Données restaurées et application
  [OK] bd511 sur rs91 : COHÉRENT
  [OK] bd511 sur rs92 : COHÉRENT
  [OK] bd511 sur rs93 : COHÉRENT
  [OK] Application en service : 17:06:34  commandes 99 (moy. 16 ms), ruptures 0, erreurs 0

Bilan : 11 OK, 0 KO
```

### 6.2 Ce qu'il faut retenir

- Une sauvegarde logique à chaud copie les collections à des instants différents : **sans son oplog, elle est incohérente**. `mongodump --oplog` enregistre l'oplog pendant la copie ; `mongorestore --oplogReplay` le rejoue et restitue l'état exact de la fin de la sauvegarde.
- `--oplog` exige un membre de replica set et une copie de toute l'instance. On sauvegarde de préférence sur un **secondaire**, avec un compte limité au rôle `backup`. Rejouer l'oplog exige, en plus du rôle `restore`, l'action `anyAction` sur `anyResource` : un compte de restauration dédié.
- La restauration à **un instant précis** combine la dernière sauvegarde complète et les sauvegardes de l'oplog qui la suivent, rejouées jusqu'à l'horodatage choisi (`--oplogLimit`, entrée exclue). Elle n'est possible que si l'oplog couvre l'intervalle entre deux sauvegardes : taille de l'oplog et `oplogMinRetentionHours` se dimensionnent en conséquence.
- `--drop` supprime chaque collection avant de la restaurer, mais remplace aussi les **comptes** de l'instance par ceux de la sauvegarde.
- Une sauvegarde **se teste** : restauration régulière sur une instance isolée, contrôles d'intégrité (empreintes SHA-256) et contrôles métier (ici, la règle de la boutique).
- `mongodump` lit toutes les données et `mongorestore` reconstruit tous les index : sur de gros volumes, les durées de sauvegarde et surtout de restauration (RTO) deviennent prohibitives. On passe alors aux sauvegardes **physiques** : instantanés du système de fichiers (LVM, cloud), Percona Backup for MongoDB, Ops Manager ou Atlas. Pour un cluster shardé, `mongodump` n'est pas une méthode de sauvegarde.

### 6.3 Bonnes pratiques de production appliquées

| Pratique | Mise en œuvre dans le TP |
| --- | --- |
| Replica set de trois membres porteurs de données | RS9 en PSS (partie 1) |
| Sauvegarde à chaud cohérente, lue sur un secondaire | `mongodump --oplog`, `readPreference=secondary` (partie 3.2) |
| Comptes dédiés et minimaux, mots de passe hors des lignes de commande | `sauvegarde` (`backup`), `restauration` (`restore` + `rejeuOplog`), fichiers `--config` en mode 600 |
| Sauvegardes compressées, protégées, sur un autre support que les données | `--gzip`, `umask 077`, répertoire en mode 700 sur le disque système, données sur `/srv/bd511-rs9` |
| Intégrité vérifiée avant toute restauration | `SHA256SUMS` (parties 3.3 et 5.5) |
| Tests de restauration sur une instance isolée | conteneur `restau`, contrôle de cohérence (partie 4) |
| Sauvegardes incrémentales de l'oplog, fenêtre d'oplog dimensionnée | `sauvegarder-oplog.sh`, `oplogMinRetentionHours: 24` (parties 1.4 et 5.3) |
| Procédure de restauration à un instant précis, écrite et répétée | partie 5 |
| À faire en production, au-delà du TP | sauvegardes planifiées et surveillées (âge de la dernière sauvegarde réussie) ; règle 3-2-1 : trois copies, deux supports, une hors site ; chiffrement des sauvegardes ; durée de conservation définie ; secondaire caché (`hidden`) dédié aux sauvegardes ; sauvegardes physiques pour les gros volumes |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `00-prerequis.sh` : conteneurs des chapitres 7 et 8 actifs | clusters encore démarrés | partie 0.1 |
| `00-prerequis.sh` : mémoire disponible insuffisante | instance `mongod` du chapitre 2, ou applications ouvertes | `sudo systemctl stop mongod` pendant le TP (`start` à la fin) ; fermez Compass et le navigateur |
| `00-prerequis.sh` : image `mongo:8.3.13` absente | VM sans le chapitre 6 | `sudo docker pull mongo:8.3.13` |
| `volume-rs9.sh` : `/srv/bd511-rs9 n'est pas vide` | tentative précédente interrompue | `sudo umount /srv/bd511-rs9` s'il est monté, puis vérifiez son contenu |
| `up --wait` : `rs91 is unhealthy`, journal `permissions on /etc/mongo/keyfile are too open` | droits du fichier de clé | partie 1.3 : `chmod 400` puis `chown 999:999` |
| `init-rs9.sh` : `RS9 est déjà initialisé` | script déjà exécuté | rien à faire ; vérifiez avec la partie 1.7 |
| `mongodump` : `bad option: --oplog mode only supported on full dumps` | `--db` ou `--collection` ajouté | `--oplog` exige une copie de toute l'instance |
| `mongodump --oplog` : `not authorized on config to execute command { find: "transactions"…` | compte sans le rôle `backup` | utilisez le compte `sauvegarde` |
| `bsondump` ou `mongorestore --oplogFile` : `unexpected EOF` sur `oplog.bson` | fichier compressé par `--gzip` | `gunzip -c < oplog.bson \| bsondump --quiet` ; pour `--oplogFile`, utilisez la sauvegarde de l'oplog (non compressée) |
| `mongorestore` : `Command applyOps requires authentication` | `--drop` a remplacé le compte qui restaure par celui de la sauvegarde, différent | sans `--drop` : supprimez d'abord la base à restaurer (partie 4.3) |
| `mongorestore` : `error applying transaction op: applyOps … not authorized on admin` | compte limité au rôle `restore` | utilisez le compte `restauration` |
| `mongorestore` : `cannot use --oplogReplay with excludes specified` | `--nsExclude` ou `--nsInclude` avec `--oplogReplay` | le rejeu de l'oplog porte sur toute l'instance |
| `sauvegarder-oplog.sh` : `Oplog tronqué` | l'oplog ne remonte plus jusqu'à la fin de la sauvegarde complète | prenez une nouvelle sauvegarde complète ; agrandissez l'oplog ou `oplogMinRetentionHours` |
| Partie 5.6 : `LIMITE` vide | incident absent de la sauvegarde de l'oplog (sauvegarde prise avant l'incident) | refaites la partie 5.3 |
| Partie 4.2 : `COHÉRENT` au lieu d'`INCOHÉRENT` | application arrêtée pendant la sauvegarde | `boutique.sh etat`, puis refaites les parties 3.2 à 4.3 avec l'application démarrée |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `~/BD511/ch09/00-prerequis.sh` | Contrôle de la VM | 0.2 |
| `~/BD511/ch09/volume-rs9.sh` | Volume XFS dédié aux données de RS9 | 1.1 |
| `~/BD511/ch09/hosts-rs9.sh` | Noms des membres dans `/etc/hosts` | 1.2 |
| `~/BD511/rs9/secrets/` | Fichier de clé, mots de passe (`*.pwd`), fichiers `--config` des Database Tools (`*.yaml`) | 1.3 |
| `~/BD511/rs9/conf/mongod.conf`, `restau.conf` | Configuration des membres de RS9 et de l'instance de test | 1.4 |
| `~/BD511/rs9/docker-compose.yml` | Projet Compose : RS9 et `restau` (profil `test`) | 1.5 |
| `~/BD511/ch09/init-rs9.sh` | Initialisation de RS9 et création des comptes | 1.6 |
| `~/BD511/ch09/mongosh-rs9` | Connexion à RS9, à un membre ou à `restau`, avec un compte du TP | 1.7 |
| `~/BD511/ch09/generer_donnees.py`, `donnees/SHA256SUMS` | Générateur déterministe et empreintes de référence | 2.1 |
| `~/BD511/ch09/importer-donnees.sh` | Import du catalogue et des commandes | 2.2 |
| `~/BD511/ch09/coherence.js` | Contrôle de la règle de la boutique | 2.3 |
| `~/BD511/ch09/boutique.js`, `boutique.sh` | Application : commandes transactionnelles en continu | 2.4 |
| `~/BD511/sauvegardes/complete-<date>/` | Sauvegarde complète : données, comptes, `oplog.bson`, `sauvegarde.json`, `SHA256SUMS` | 3 |
| `~/BD511/ch09/init-restau.sh` | Instance de test et ses comptes | 4.1 |
| `~/BD511/ch09/incident.js` | Suppression accidentelle de `bd511.commandes` | 5.1 |
| `~/BD511/ch09/sauvegarder-oplog.sh` | Sauvegarde incrémentale de l'oplog | 5.3 |
| `~/BD511/sauvegardes/oplog-<date>/` | Sauvegarde de l'oplog : `local/oplog.rs.bson`, `sauvegarde.json`, `SHA256SUMS` | 5.3 |
| `~/BD511/ch09/verifier-ch09.sh` | Contrôle final | 6.1 |

## Annexe C – Exploiter RS9 et remettre la VM en état

| Action | Commande |
| --- | --- |
| État des conteneurs | `cd ~/BD511/rs9 && sudo docker compose --profile test ps -a` |
| Arrêter l'application, puis RS9 | `bash ~/BD511/ch09/boutique.sh arreter` ; `cd ~/BD511/rs9 && sudo docker compose stop` |
| Redémarrer RS9, puis l'application | `cd ~/BD511/rs9 && sudo docker compose up -d --wait` ; `bash ~/BD511/ch09/boutique.sh demarrer` |
| Taille et contenu des sauvegardes | `du -sh ~/BD511/sauvegardes/*` ; `jq -c . ~/BD511/sauvegardes/*/sauvegarde.json` |
| Supprimer les sauvegardes de plus de 7 jours | `find ~/BD511/sauvegardes -mindepth 1 -maxdepth 1 -type d -mtime +7 -exec rm -rf {} +` |
| Fenêtre de l'oplog | `~/BD511/ch09/mongosh-rs9 --compte admin --quiet --eval 'rs.printReplicationInfo()'` |
| Relancer le cluster du chapitre 7 (RS9 arrêté, faute de mémoire) | `bash ~/bd511/ch07/cluster.sh demarrer` |
| Relancer la supervision du chapitre 8 | `cd ~/BD511/supervision && sudo docker compose up -d --wait` |

**Repartir de zéro (note formateur).** Les commandes suivantes arrêtent l'application, suppriment les conteneurs, les données de RS9 et de `restau`, et les sauvegardes. Le volume, les noms d'hôtes, les secrets et les fichiers du TP sont conservés.

```bash
bash ~/BD511/ch09/boutique.sh arreter
cd ~/BD511/rs9 && sudo docker compose --profile test down
sudo find /srv/bd511-rs9/rs91 /srv/bd511-rs9/rs92 /srv/bd511-rs9/rs93 /srv/bd511-rs9/restau -mindepth 1 -delete
rm -rf ~/BD511/sauvegardes/complete-* ~/BD511/sauvegardes/oplog-*
sudo docker compose up -d --wait
bash ~/BD511/ch09/init-rs9.sh
```

Reprenez ensuite à la partie 2.2.

## Annexe D – Références

- Sauvegarde et restauration : [Backup Methods for a Self-Managed Deployment](https://www.mongodb.com/docs/manual/core/backups/), [Back Up and Restore a Self-Managed Deployment with MongoDB Tools](https://www.mongodb.com/docs/manual/tutorial/backup-and-restore-tools/), [Restore a Self-Managed Replica Set from MongoDB Backups](https://www.mongodb.com/docs/manual/tutorial/restore-replica-set-from-backup/)
- Outils : [mongodump](https://www.mongodb.com/docs/database-tools/mongodump/) (`--oplog`, rôle `backup`), [mongorestore](https://www.mongodb.com/docs/database-tools/mongorestore/) (`--oplogReplay`, `--oplogLimit`, `--oplogFile`, droits nécessaires au rejeu de l'oplog), [bsondump](https://www.mongodb.com/docs/database-tools/bsondump/)
- Oplog : [Replica Set Oplog](https://www.mongodb.com/docs/manual/core/replica-set-oplog/), [`storage.oplogMinRetentionHours`](https://www.mongodb.com/docs/manual/reference/configuration-options/#mongodb-setting-storage.oplogMinRetentionHours), [Change the Size of the Oplog](https://www.mongodb.com/docs/manual/tutorial/change-oplog-size/)
- Rôles : [Built-In Roles (`backup`, `restore`)](https://www.mongodb.com/docs/manual/reference/built-in-roles/), [Localhost Exception](https://www.mongodb.com/docs/manual/core/localhost-exception/)
- Alternatives : [Back Up with Filesystem Snapshots](https://www.mongodb.com/docs/manual/tutorial/backup-with-filesystem-snapshots/), [Percona Backup for MongoDB](https://docs.percona.com/percona-backup-mongodb/)
- Version : [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
