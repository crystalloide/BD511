# `02-volume-xfs.sh` — explications

**Module BD511 · Chapitre 2 · Volume XFS dédié, monté avec `noatime`, pour les données MongoDB**

## En bref

En production, on recommande de placer les données MongoDB (`/var/lib/mongodb`) sur un **volume dédié**, formaté en **XFS** et monté avec l'option **`noatime`** :

- **XFS** est le système de fichiers recommandé pour WiredTiger, le moteur de stockage de MongoDB. Au démarrage, `mongod` affiche un avertissement s'il détecte un autre système de fichiers, comme ext4 ;
- **`noatime`** évite que le système écrive la date du dernier accès à chaque **lecture** d'un fichier, ce qui ferait des écritures inutiles.

La VM du TP n'a qu'un seul disque. Le script **simule donc un disque dédié** avec un fichier image (`/var/lib/mongodb-xfs.img`) utilisé comme un disque grâce à un **périphérique loop** (*loop device*) : le noyau présente un fichier ordinaire comme s'il s'agissait d'un disque.

```bash
sudo bash ~/bd511/ch02/02-volume-xfs.sh        # volume de 8 Go (valeur par défaut)
sudo bash ~/bd511/ch02/02-volume-xfs.sh 10     # volume de 10 Go
```

Le script est **idempotent** : on peut le relancer sans risque. Il vérifie à chaque étape si le travail a déjà été fait.

> À l'issue du script, `mongod` est **arrêté** : le script ne le relance pas. Démarrez-le quand le guide vous le demande (`sudo systemctl start mongod`).

---

## Explication instruction par instruction

### 1. En-tête, options et variables

```bash
#!/usr/bin/env bash
# 02-volume-xfs.sh - BD511 ch.2 : volume XFS dédié (noatime) pour /var/lib/mongodb
# Simule un disque dédié par un fichier image monté en boucle (loop).
# Usage : sudo bash ~/bd511/ch02/02-volume-xfs.sh [taille_en_Go]   (8 Go par défaut)
```

Le **shebang** indique que le fichier est un script bash ; les commentaires résument son rôle. Dans la ligne d'usage, les crochets `[taille_en_Go]` signalent un argument **facultatif**.

```bash
set -euo pipefail
```

- `-e` : arrêt dès qu'une commande échoue ;
- `-u` : arrêt si une variable non définie est utilisée ;
- `-o pipefail` : une chaîne `cmd1 | cmd2` échoue si l'une quelconque de ses commandes échoue.

```bash
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
```

Vérifie que le script tourne en `root` (`$EUID` vaut 0). Sinon, il affiche un message sur la sortie d'erreur (`>&2`) et s'arrête. Formater, monter un volume ou modifier `/etc/fstab` demande les droits administrateur.

```bash
IMAGE=/var/lib/mongodb-xfs.img
POINT=/var/lib/mongodb
TAILLE_GO=${1:-8}
```

Trois variables :

- `IMAGE` : le fichier qui jouera le rôle de disque ;
- `POINT` : le **point de montage**, c'est-à-dire le dossier où le contenu du volume apparaîtra. C'est le dossier de données de MongoDB ;
- `TAILLE_GO` : `$1` est le premier argument passé au script ; `${1:-8}` prend sa valeur, ou `8` si aucun argument n'a été donné.

### 2. Vérification des prérequis

```bash
getent passwd mongodb >/dev/null || { echo "Utilisateur mongodb absent : faites d'abord la partie 1." >&2; exit 1; }
```

- `getent passwd mongodb` cherche l'utilisateur système `mongodb` dans la base des comptes ;
- `>/dev/null` jette l'affichage : seul le code retour (trouvé ou non) nous intéresse.

L'utilisateur `mongodb` est créé par l'installation des paquets MongoDB (partie 1). Le script en a besoin pour lui donner la propriété du volume.

```bash
command -v mkfs.xfs >/dev/null || apt-get install -y xfsprogs
```

`command -v` vérifie si une commande existe. Si `mkfs.xfs` (l'outil qui formate en XFS) est absent, on installe le paquet `xfsprogs` qui le fournit.

### 3. Rien à faire si le volume est déjà en place

```bash
if findmnt -n -t xfs "$POINT" >/dev/null; then
  echo "$POINT est déjà un volume XFS monté : rien à faire."
  findmnt "$POINT"
  exit 0
fi
```

- `findmnt` affiche les systèmes de fichiers montés ; avec un chemin en argument, il cherche un montage **sur ce dossier précis** ;
- `-t xfs` : uniquement s'il est de type XFS ; `-n` supprime la ligne d'en-tête ;
- si c'est le cas, le script affiche le montage et s'arrête avec `exit 0` (succès).

C'est ce bloc qui rend le script **idempotent**.

### 4. Préparation du point de montage

```bash
# mongod ne doit pas tourner pendant la préparation du volume.
systemctl stop mongod 2>/dev/null || true
```

Le commentaire annonce l'objectif. La commande arrête le service `mongod` : on ne déplace pas les fichiers d'une base en cours d'utilisation. `2>/dev/null` masque l'erreur si le service n'existe pas ou ne tourne pas, et `|| true` empêche `set -e` d'arrêter le script dans ce cas.

```bash
# Le point de montage doit être vide : d'éventuelles données créées sur ext4 sont mises de côté.
if [[ -d $POINT && -n $(ls -A "$POINT") ]]; then
  sauvegarde="$POINT.ext4-$(date +%Y%m%d%H%M%S)"
  echo "Contenu existant de $POINT déplacé vers $sauvegarde"
  mv "$POINT" "$sauvegarde"
fi
mkdir -p "$POINT"
```

Un volume monté sur un dossier non vide **masque** le contenu de ce dossier. Le script met donc de côté ce qui s'y trouve déjà (par exemple les fichiers créés par `mongod` lors de son premier démarrage, en partie 1, sur le disque ext4) :

- `-d $POINT` : le dossier existe ;
- `ls -A` liste son contenu, fichiers cachés compris ; `-n $(...)` est vrai si cette liste n'est pas vide ;
- `date +%Y%m%d%H%M%S` produit un horodatage, par exemple `20261101153042`. Le dossier est renommé en `/var/lib/mongodb.ext4-20261101153042` : rien n'est supprimé ;
- `mkdir -p` recrée un dossier `/var/lib/mongodb` vide ; `-p` évite une erreur s'il existe déjà.

> Les éventuelles données de test de la partie 1 restent dans ce dossier de sauvegarde. Sur le nouveau volume, `mongod` repartira d'un répertoire de données vide.

### 5. Création du fichier image

```bash
if [[ ! -f $IMAGE ]]; then
```

`-f` teste si un fichier existe ; le `!` inverse le test. Le bloc suivant n'est exécuté que si l'image n'existe pas encore.

```bash
  libre=$(df --output=avail -BG "$(dirname "$IMAGE")" | tail -n 1 | tr -dc '0-9')
```

Calcule l'espace libre, en Go, sur le disque qui accueillera l'image :

- `dirname "$IMAGE"` donne le dossier du fichier (`/var/lib`) ;
- `df --output=avail -BG` affiche l'espace disponible en Go (par exemple `24G`) ;
- `tail -n 1` saute la ligne d'en-tête ;
- `tr -dc '0-9'` ne garde que les chiffres : `24G` devient `24`.

```bash
  (( libre - 3 < TAILLE_GO )) && TAILLE_GO=$(( libre - 3 ))
```

Si la taille demandée ne laisse pas au moins 3 Go libres sur le disque, elle est réduite à « espace libre − 3 Go ». Le disque de la VM ne doit jamais être plein, car le système lui-même en a besoin.

```bash
  (( TAILLE_GO >= 2 )) || { echo "Espace disque insuffisant (${libre} Go libres)." >&2; exit 1; }
```

En dessous de 2 Go, le volume serait inutilisable : le script s'arrête avec un message d'erreur.

```bash
  echo "Création de $IMAGE (${TAILLE_GO} Go)..."
  fallocate -l "${TAILLE_GO}G" "$IMAGE"
  chmod 600 "$IMAGE"
fi
```

- `fallocate -l 8G` crée un fichier de 8 Go en **réservant** directement l'espace sur le disque, sans écrire de zéros : c'est instantané, contrairement à `dd` ;
- `chmod 600` : seul le propriétaire (`root`) peut lire et écrire ce fichier, qui contiendra toutes les données de la base.

### 6. Formatage en XFS

```bash
if [[ $(blkid -p -s TYPE -o value "$IMAGE" 2>/dev/null || true) != xfs ]]; then
  echo "Formatage XFS..."
  mkfs.xfs -q -f -L mongodata "$IMAGE"
fi
```

**Avant de formater, on regarde si c'est déjà fait** : formater effacerait toutes les données.

- `blkid` identifie le type de système de fichiers d'un disque ou d'un fichier : `-p` analyse directement le contenu (sans cache), `-s TYPE` ne demande que le type, `-o value` n'affiche que la valeur (`xfs`, `ext4`… ou rien) ;
- `|| true` : `blkid` renvoie une erreur sur un fichier vierge, ce qui ne doit pas arrêter le script.

Si le type n'est pas `xfs`, on formate :

- `mkfs.xfs` crée un système de fichiers XFS dans le fichier image ;
- `-q` : mode silencieux ;
- `-f` (*force*) : écrase toute signature existante ;
- `-L mongodata` : donne l'étiquette (*label*) `mongodata` au volume.

### 7. Déclaration dans `/etc/fstab`

```bash
if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
  cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
  printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
fi
```

Le fichier `/etc/fstab` liste les volumes à monter **automatiquement au démarrage**. Sans lui, le montage disparaîtrait au prochain redémarrage.

- `grep -qE "^${IMAGE}[[:space:]]"` cherche une ligne commençant par le chemin de l'image suivi d'un espace ou d'une tabulation. On n'ajoute la ligne que si elle n'existe pas encore (`!`), pour ne jamais la dupliquer ;
- `cp /etc/fstab /etc/fstab.bak-<date>` : sauvegarde du fichier avant modification. Une erreur dans `fstab` peut empêcher la machine de démarrer correctement ;
- `printf ... >> /etc/fstab` ajoute la ligne à la **fin** du fichier (`>>` ajoute, alors que `>` écraserait). `\t` est une tabulation.

La ligne ajoutée comporte les 6 champs standard de `fstab` :

| Champ | Valeur | Signification |
|---|---|---|
| 1. Source | `/var/lib/mongodb-xfs.img` | ce qu'on monte (ici un fichier) |
| 2. Point de montage | `/var/lib/mongodb` | où le contenu apparaît |
| 3. Type | `xfs` | système de fichiers |
| 4. Options | `defaults,loop,noatime,nofail` | voir ci-dessous |
| 5. Dump | `0` | pas de sauvegarde par l'ancien outil `dump` |
| 6. Vérification | `0` | pas de vérification du volume au démarrage (`fsck`) |

Les options :

- `defaults` : options standard (lecture-écriture, etc.) ;
- `loop` : rattache automatiquement le fichier à un périphérique loop (`/dev/loop0`, par exemple) ;
- `noatime` : pas de mise à jour de la date d'accès à chaque lecture ;
- `nofail` : si le montage échoue, la machine démarre quand même au lieu de rester bloquée en mode de secours.

### 8. Montage et droits

```bash
systemctl daemon-reload
```

Au démarrage, systemd transforme chaque ligne de `/etc/fstab` en une « unité de montage ». Après une modification de `fstab`, cette commande lui fait relire la configuration ; sinon, `mount` signale que systemd utilise encore l'ancienne version du fichier.

```bash
mount "$POINT"
```

Monte le volume. Quand on ne donne que le point de montage, `mount` va chercher le reste (source, type, options) dans `/etc/fstab`. On vérifie ainsi au passage que la ligne ajoutée est correcte.

```bash
chown mongodb:mongodb "$POINT"
chmod 0750 "$POINT"
```

Un système de fichiers tout neuf appartient à `root`. Or `mongod` s'exécute sous l'utilisateur `mongodb` et doit pouvoir écrire dans ce dossier :

- `chown mongodb:mongodb` donne le dossier à l'utilisateur et au groupe `mongodb` ;
- `chmod 0750` : lecture/écriture/accès pour le propriétaire (`7`), lecture/accès pour le groupe (`5`), rien pour les autres (`0`).

```bash
findmnt "$POINT"
```

Affiche le résultat final pour contrôle.

---

## Ce que vous devez obtenir

Exemple de sortie de la dernière commande (le numéro du périphérique loop peut varier) :

```text
TARGET           SOURCE     FSTYPE OPTIONS
/var/lib/mongodb /dev/loop0 xfs    rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

Vérifiez les trois points essentiels : le type `xfs`, l'option `noatime` et la source `/dev/loopN`. Pour aller plus loin :

```bash
df -hT /var/lib/mongodb      # taille et type du volume
ls -ld /var/lib/mongodb      # propriétaire mongodb:mongodb, droits drwxr-x---
losetup -a                   # périphériques loop et fichiers associés
```
