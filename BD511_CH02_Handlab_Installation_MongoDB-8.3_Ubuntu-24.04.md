# BD511 – Chapitre 2 – Handlab : installation et configuration de MongoDB 8.3 sous Ubuntu 24.04

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 2 – Installation et configuration |
| **Durée indicative** | 1 h 10 (+ 5 min si la VM doit redémarrer sur un autre noyau) |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop x86_64, 2 vCPU, 4 Go de RAM, 15 Go libres, compte avec `sudo`, accès Internet HTTPS |
| **Versions vérifiées le 19/10/2026** | MongoDB Community Server **8.3.13** · mongosh **2.13.0** · Database Tools **100.19.1** · Compass **1.53.0** · noyau Ubuntu GA **6.8** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. installer le serveur `mongod` et les outils clients (mongosh, Database Tools) depuis le dépôt APT officiel de MongoDB ;
2. appliquer à Ubuntu les réglages système recommandés par MongoDB pour la production, puis démarrer et superviser le service `mongod` avec systemd ;
3. vous connecter à l'instance avec mongosh, importer un jeu de données et l'interroger ;
4. installer le client graphique MongoDB Compass ;
5. vous connecter à l'instance avec Compass et vérifier que les deux clients voient les mêmes données.

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Préparation de la VM : prérequis, contrôle du noyau | 10 min |
| 1 | Installation du serveur et des outils clients depuis le dépôt officiel | 10 min |
| 2 | Réglages système de production et démarrage du service `mongod` | 20 min |
| 3 | Premiers tests de connexion avec mongosh | 10 min |
| 4 | Installation du client graphique Compass | 5 min |
| 5 | Premiers tests de connexion avec Compass | 10 min |
| 6 | Bilan et contrôle final | 5 min |

## Conventions

- Toutes les commandes s'exécutent dans un **terminal** de la VM (`Ctrl` + `Alt` + `T`), avec votre compte habituel ; `sudo` est indiqué quand des droits d'administration sont nécessaires.
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'` ou `sudo tee fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs intitulés « Résultat attendu » montrent la sortie à obtenir ; les valeurs variables (dates, identifiants, PID) diffèrent sur votre VM.
- Tous les fichiers du TP sont générés dans `~/bd511/ch02` ou à leur emplacement système ; l'annexe C en donne la liste complète.

> **Note formateur.** La partie 0.4 (changement de noyau) et le téléchargement de Compass (partie 4.1) peuvent être faits une fois pour toutes dans le modèle de VM : les stagiaires gagnent alors une dizaine de minutes et la bande passante de la salle est préservée.

---

## Partie 0 – Préparation de la VM

### 0.1 Créer l'espace de travail et sécuriser les commandes `apt`

Juste après le démarrage d'Ubuntu Desktop, les mises à jour automatiques (`unattended-upgrades`) occupent souvent le gestionnaire de paquets, et `apt-get` échoue alors avec « Could not get lock ». Le petit fichier de configuration ci-dessous fait patienter `apt-get` jusqu'à 10 minutes au lieu d'échouer.

```bash
su - user

mkdir -p ~/bd511/ch02 && cd ~/bd511/ch02
echo 'DPkg::Lock::Timeout "600";' | sudo tee /etc/apt/apt.conf.d/90-bd511-lock-timeout
```

### 0.2 Mettre le système à jour et installer les outils nécessaires

Les notes de production de MongoDB recommandent d'utiliser la dernière mise à jour de la bibliothèque C du système (glibc). Mettez donc la VM à jour, puis installez les outils utilisés dans ce TP : `curl` et `gnupg` pour la clé du dépôt, `xfsprogs` pour formater le volume de données en XFS, `jq` pour lire les journaux JSON de MongoDB.

```bash
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
sudo apt-get install -y curl gnupg ca-certificates xfsprogs jq
```

La mise à jour peut prendre quelques minutes si la VM n'a pas été mise à jour récemment.

### 0.3 Vérifier la plate-forme

MongoDB 8.3 a plusieurs exigences matérielles et logicielles :

- **Ubuntu 24.04 LTS** (« Noble ») ou 22.04, en 64 bits ;
- sur x86_64, un processeur avec le jeu d'instructions **AVX** (exigé depuis MongoDB 5.0) ;
- un **noyau Linux hors de la plage 6.19 à 7.0.13**. Ces noyaux ont modifié le comportement des *restartable sequences* (rseq) utilisées par l'allocateur mémoire TCMalloc de MongoDB, ce qui peut faire planter `mongod`. MongoDB 8.3 lit donc la version du noyau au démarrage (`uname -r`) et **refuse de démarrer** si elle se trouve dans cette plage (ticket SERVER-121912).

Le script suivant contrôle ces points. Générez-le :

```bash
cat > ~/bd511/ch02/00-verif-plateforme.sh <<'EOF'
#!/usr/bin/env bash
# 00-verif-plateforme.sh - BD511 ch.2 : prérequis plate-forme pour MongoDB 8.3
# Usage : bash ~/bd511/ch02/00-verif-plateforme.sh
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

# Règle appliquée par mongod 8.3.x au démarrage : noyaux 6.19.0 à 7.0.13 refusés.
noyau_compatible() {
  [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
  local v=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} ))
  (( v < 6019000 || v > 7000013 ))
}

echo "== Système"
. /etc/os-release
if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]]; then
  ok "$PRETTY_NAME"
else
  nok "Ubuntu 24.04 attendu (trouvé : ${PRETTY_NAME:-inconnu})"
fi

case $(uname -m) in
  x86_64)
    if grep -qw avx /proc/cpuinfo; then ok "Processeur x86_64 avec AVX"
    else nok "Processeur x86_64 SANS AVX : mongod ne pourra pas démarrer (voir annexe A)"; fi ;;
  aarch64)
    ok "Processeur aarch64 (ARMv8.2-A minimum ; Compass n'existe pas pour Linux ARM64)" ;;
  *)
    nok "Architecture non supportée : $(uname -m)" ;;
esac

mem_mo=$(awk '/^MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo)
if (( mem_mo >= 3500 )); then ok "Mémoire : ${mem_mo} Mo"; else nok "Mémoire : ${mem_mo} Mo (4 Go recommandés)"; fi

libre_go=$(df --output=avail -BG /var/lib | tail -n 1 | tr -dc '0-9')
if (( libre_go >= 12 )); then ok "Espace libre sous /var/lib : ${libre_go} Go"
else nok "Espace libre sous /var/lib : ${libre_go} Go (12 Go recommandés)"; fi

echo "== Noyau"
courant=$(uname -r)
if noyau_compatible "$courant"; then ok "Noyau en cours d'exécution : $courant"
else nok "Noyau en cours d'exécution : $courant (incompatible avec MongoDB 8.3.13)"; fi

for image in /boot/vmlinuz-*; do
  [[ -e $image ]] || continue
  version=${image#/boot/vmlinuz-}
  noyau_compatible "$version" || nok "Noyau installé incompatible : $version"
done

if dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-*-hwe-24.04' 2>/dev/null | grep -q '^ii'; then
  nok "Pile noyau HWE installée : elle installera des noyaux 6.19 ou plus récents"
fi

echo
if (( ko == 0 )); then
  echo "Résultat : plate-forme conforme, passez à la partie 1."
else
  echo "Résultat : ${ko} point(s) à corriger (voir la partie 0.4 pour le noyau)."
fi
exit $(( ko > 0 ))
EOF
```

Exécutez-le :

```bash
bash ~/bd511/ch02/00-verif-plateforme.sh
```

Résultat attendu sur une VM Ubuntu 24.04.5 Desktop fraîchement installée :

```text
== Système
  [OK] Ubuntu 24.04.5 LTS
  [OK] Processeur x86_64 avec AVX
  [OK] Mémoire : 3915 Mo
  [OK] Espace libre sous /var/lib : 31 Go
== Noyau
  [KO] Noyau en cours d'exécution : 7.0.0-38-generic (incompatible avec MongoDB 8.3.13)
  [KO] Noyau installé incompatible : 7.0.0-38-generic
  [KO] Pile noyau HWE installée : elle installera des noyaux 6.19 ou plus récents

Résultat : 3 point(s) à corriger (voir la partie 0.4 pour le noyau).
```

- Si **tous les points sont OK**, passez directement à la partie 1.
- Si **seuls les points « Noyau » sont KO**, réalisez la partie 0.4.
- Si le point **AVX** est KO, consultez l'annexe A avant d'aller plus loin : sans AVX, `mongod` s'arrête immédiatement avec `Illegal instruction`.

### 0.4 Passer sur le noyau GA d'Ubuntu 24.04 (si nécessaire)

**Pourquoi ?** Ubuntu 24.04 propose deux familles de noyaux :

- le noyau **GA** (*General Availability*), version **6.8**, maintenu pendant toute la vie d'Ubuntu 24.04 : c'est le noyau par défaut d'**Ubuntu Server** ;
- la pile **HWE** (*Hardware Enablement*), qui suit les noyaux des versions intermédiaires d'Ubuntu pour supporter le matériel récent : c'est le choix par défaut d'**Ubuntu Desktop**, et Ubuntu 24.04.5 l'a fait passer au noyau **7.0**.

Le noyau HWE 7.0 d'Ubuntu s'affiche `7.0.0-xx-generic`. MongoDB 8.3.13 lit `7.0.0`, le classe dans la plage incompatible et refuse de démarrer avec le message « MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility with this version of MongoDB ». La reconnaissance des noyaux Ubuntu corrigés est annoncée pour MongoDB 8.3.14 (ticket SERVER-131779), qui n'est pas encore publiée.

Sur un serveur de bases de données, le noyau GA est de toute façon le choix recommandé : c'est le noyau stock de la distribution, celui que MongoDB supporte et teste. Le script ci-dessous installe le noyau GA, retire la pile HWE (pour qu'elle ne revienne pas lors des mises à jour) et régénère la configuration du chargeur d'amorçage GRUB.

```bash
cat > ~/bd511/ch02/01-noyau-ga.sh <<'EOF'
#!/usr/bin/env bash
# 01-noyau-ga.sh - BD511 ch.2 : remplace la pile noyau HWE par le noyau GA 6.8 d'Ubuntu 24.04
# Usage : sudo bash ~/bd511/ch02/01-noyau-ga.sh   puis   sudo reboot
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
. /etc/os-release
[[ ${VERSION_CODENAME:-} == noble ]] || { echo "Script prévu pour Ubuntu 24.04 (noble)." >&2; exit 1; }

# Mode non interactif : autorise la suppression du noyau en cours d'exécution
# (le noyau GA est installé avant, et la VM redémarre juste après).
export DEBIAN_FRONTEND=noninteractive

echo "1/4 Installation du noyau GA (paquet linux-generic)..."
apt-get update -qq
apt-get install -y linux-generic

noyau_ga=$(find /boot -maxdepth 1 -name 'vmlinuz-6.8.0-*-generic' -printf '%f\n' | sort -V | tail -n 1)
[[ -n $noyau_ga ]] || { echo "Noyau GA 6.8 introuvable dans /boot : arrêt sans rien supprimer." >&2; exit 1; }
echo "    Noyau GA installé : ${noyau_ga#vmlinuz-}"

echo "2/4 Recherche des paquets de la pile HWE..."
mapfile -t paquets < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*' 2>/dev/null |
    awk '$1 ~ /^ii/ {print $2}' |
    grep -E -- '-hwe-24\.04$|^linux-hwe-|-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(-[a-z0-9]+)?$' |
    grep -v -E -- '-6\.8\.0-[0-9]+(-[a-z0-9]+)?$' || true
)

if (( ${#paquets[@]} == 0 )); then
  echo "    Aucun paquet HWE installé."
else
  printf '    %s\n' "${paquets[@]}"
  echo "3/4 Suppression de la pile HWE..."
  apt-get purge -y "${paquets[@]}"
fi

echo "4/4 Mise à jour de la configuration GRUB..."
update-grub

echo
echo "Terminé. Redémarrez la VM maintenant : sudo reboot"
EOF
sudo bash ~/bd511/ch02/01-noyau-ga.sh
```

Le script affiche la liste des paquets supprimés, puis un avertissement normal à cette étape : `W: Removing the running kernel`. Redémarrez la VM :

```bash
sudo reboot
```

Après le redémarrage, rouvrez un terminal et relancez le contrôle : tous les points doivent être OK.

```bash
uname -r
bash ~/bd511/ch02/00-verif-plateforme.sh
```

Résultat attendu (extrait) :

```text
6.8.0-147-generic
...
== Noyau
  [OK] Noyau en cours d'exécution : 6.8.0-147-generic

Résultat : plate-forme conforme, passez à la partie 1.
```

> **VirtualBox.** Si les Additions invité sont installées, elles sont recompilées automatiquement pour le nouveau noyau (presse-papiers partagé, redimensionnement de l'écran). Si ces fonctions ne reviennent pas, réinstallez-les depuis le menu *Périphériques ▸ Insérer l'image CD des Additions invité*.

---

## Partie 1 – Installation du serveur et des outils clients depuis le dépôt officiel

MongoDB publie ses propres dépôts APT. **N'installez jamais le paquet `mongodb` de la distribution** : il n'est pas maintenu par MongoDB et entre en conflit avec les paquets officiels `mongodb-org`.

### 1.1 Importer la clé de signature du dépôt

Le dépôt de la branche 8.3 est signé avec la clé « MongoDB 8.0 Release Signing Key ». La commande la télécharge et la convertit au format binaire attendu par APT :

```bash
curl -fsSL https://pgp.mongodb.com/server-8.0.asc | \
  sudo gpg --yes -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor
```

Vérifiez son empreinte, qui doit être `4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05` :

```bash
gpg --show-keys --with-colons /usr/share/keyrings/mongodb-server-8.0.gpg | awk -F: '/^fpr/ {print $10; exit}'
```

Résultat attendu :

```text
4B0752C1BCA238C0B4EE14DC41DE058A4E7DCA05
```

### 1.2 Déclarer le dépôt MongoDB 8.3

L'option `signed-by` limite la confiance accordée à cette clé au seul dépôt MongoDB :

```bash
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg ] https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.3 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-8.3.list
sudo apt-get update
```

Contrôlez que la version proposée provient bien du dépôt MongoDB :

```bash
apt-cache policy mongodb-org
```

Résultat attendu (extrait) :

```text
mongodb-org:
  Installed: (none)
  Candidate: 8.3.13
  Version table:
     8.3.13 500
        500 https://repo.mongodb.org/apt/ubuntu noble/mongodb-org/8.3/multiverse amd64 Packages
```

### 1.3 Installer le serveur et les outils clients

Le métapaquet `mongodb-org` installe l'ensemble des composants :

| Paquet | Contenu |
| --- | --- |
| `mongodb-org-database` | métapaquet du serveur : tire `mongodb-org-server` et `mongodb-org-mongos` |
| `mongodb-org-server` | démon `mongod`, unité systemd `mongod.service`, fichier `/etc/mongod.conf`, utilisateur système `mongodb` |
| `mongodb-org-mongos` | routeur `mongos` (utilisé au chapitre 7) |
| `mongodb-mongosh` | shell `mongosh` |
| `mongodb-org-tools` | métapaquet des outils : tire `mongodb-database-tools` et `mongodb-org-database-tools-extra` |
| `mongodb-database-tools` | `mongodump`, `mongorestore`, `mongoimport`, `mongoexport`, `mongostat`, `mongotop`, `bsondump`, `mongofiles` |
| `mongodb-org-database-tools-extra` | script `install_compass` (non utilisé : Compass est installé à la partie 4) |
| `mongodb-org-shell` | paquet de compatibilité, vide depuis le retrait de l'ancien shell `mongo` |

```bash
sudo apt-get install -y mongodb-org
```

### 1.4 Figer les versions installées

En production, une montée de version de MongoDB se planifie (chapitre 9). Pour qu'une mise à jour système ne change pas de version à votre insu, mettez les paquets MongoDB installés en attente (*hold*) :

```bash
sudo apt-mark hold $(dpkg -l 'mongodb-*' | awk '/^ii/ {print $2}')
apt-mark showhold
```

Résultat attendu :

```text
mongodb-database-tools
mongodb-mongosh
mongodb-org
mongodb-org-database
mongodb-org-database-tools-extra
mongodb-org-mongos
mongodb-org-server
mongodb-org-shell
mongodb-org-tools
```

### 1.5 Vérifier l'installation

```bash
mongod --version
mongosh --version
mongoimport --version | head -n 1
```

Résultat attendu (extrait) :

```text
db version v8.3.13
Build Info: {
    "version": "8.3.13",
    "gitVersion": "98a36356ecff0a17fe3c31286c17cd63b85cf4b9",
    "openSSLVersion": "OpenSSL 3.0.13 30 Jan 2024",
    "modules": [],
    "allocator": "tcmalloc-google",
    "environment": {
        "distmod": "ubuntu2404",
        "distarch": "x86_64",
        "target_arch": "x86_64"
    }
}
2.13.0
mongoimport version: 100.19.1
```

Notez l'allocateur `tcmalloc-google` : c'est la version de TCMalloc introduite en 8.0, qui explique les nouvelles recommandations sur les Transparent Huge Pages (partie 2.2).

Repérez les emplacements créés par le paquet serveur, puis affichez l'unité systemd fournie :

```bash
dpkg -L mongodb-org-server | grep -E '^/(etc|usr/bin|lib|usr/lib)/' | grep -v '/share/'
id mongodb
systemctl cat mongod
```

Points à observer dans `mongod.service` :

- le service tourne sous l'utilisateur système **`mongodb`**, jamais sous `root` ;
- `ExecStart=/usr/bin/mongod --config /etc/mongod.conf` : toute la configuration du serveur est dans `/etc/mongod.conf` ;
- `Environment="GLIBC_TUNABLES=glibc.pthread.rseq=0"` : empêche la glibc d'enregistrer la structure rseq avant TCMalloc, ce qui permet à TCMalloc d'utiliser ses **caches par CPU** (recommandation de production déjà appliquée par le paquet) ;
- `LimitNOFILE=64000` et `LimitNPROC=64000` : les limites `ulimit` recommandées (fichiers ouverts, processus et threads). En dessous de 64000 fichiers ouverts, `mongod` émet un avertissement au démarrage.

Le paquet **ne démarre pas** `mongod` et ne l'active pas au démarrage de la VM :

```bash
systemctl is-enabled mongod; systemctl is-active mongod
```

Résultat attendu :

```text
disabled
inactive
```

C'est voulu : vous allez d'abord préparer le système et le stockage, car `mongod` crée ses fichiers de données dès son premier démarrage.

---

## Partie 2 – Réglages système de production et démarrage du service `mongod`

Le tableau ci-dessous récapitule les recommandations des *Production Notes* de MongoDB 8.3 pour Linux et l'endroit où ce TP les applique.

| Recommandation | Mise en œuvre dans ce TP | Contrôle |
| --- | --- | --- |
| Noyau stock de la distribution, hors 6.19 à 7.0.13 | Noyau GA 6.8 (partie 0.4) | `uname -r` |
| Système de fichiers XFS pour les données | Volume XFS dédié (2.1) | `findmnt` |
| `atime` désactivé sur le volume de données | Option de montage `noatime` (2.1) | `findmnt` |
| THP activées : `always`, `defer+madvise`, `max_ptes_none = 0`, `overcommit_memory = 1` | Service systemd officiel (2.2) | `/sys/kernel/mm/transparent_hugepage/` |
| `vm.swappiness` à 0 ou 1, `vm.zone_reclaim_mode = 0`, `tcp_keepalive_time = 120` | Fichier sysctl (2.3) | `sysctl` |
| `vm.max_map_count` au moins égal à 2 fois le nombre maximal de connexions | Fichier sysctl (2.3) | `sysctl` |
| Ordonnanceur d'E/S `none` pour les disques d'une VM | Règle udev (2.4) | `/sys/block/*/queue/scheduler` |
| *Readahead* entre 8 et 32 secteurs sur le volume de données | Complément de l'unité `mongod` (2.5) | `blockdev --getra` |
| `ulimit` : 64000 fichiers ouverts et processus | Unité `mongod.service` du paquet | `/proc/<pid>/limits` |
| glibc rseq désactivé (caches TCMalloc par CPU) | Unité `mongod.service` du paquet | `serverStatus` |
| NUMA : un seul nœud, ou `numactl --interleave=all` | VM à un seul nœud | `lscpu` |
| Horloges synchronisées par NTP | `systemd-timesyncd`, actif par défaut | `timedatectl` |

### 2.1 Créer un volume XFS dédié aux données

MongoDB recommande fortement **XFS** pour les données du moteur WiredTiger ; sur ext4 (le système de fichiers par défaut d'Ubuntu), `mongod` émet l'avertissement « Using the XFS filesystem is strongly recommended with the WiredTiger storage engine ». En production, les données sont placées sur un disque ou un volume logique dédié, formaté en XFS et monté avec l'option `noatime` (pas de mise à jour de la date de dernier accès à chaque lecture).

La VM du TP n'a qu'un disque : le script simule un disque dédié par un **fichier image formaté en XFS**, monté en boucle (*loop device*) sur `/var/lib/mongodb` à chaque démarrage via `/etc/fstab`. Pour un vrai disque, seule la source change dans `/etc/fstab` (par exemple `UUID=… /var/lib/mongodb xfs defaults,noatime 0 0`).

```bash
cat > ~/bd511/ch02/02-volume-xfs.sh <<'EOF'
#!/usr/bin/env bash
# 02-volume-xfs.sh - BD511 ch.2 : volume XFS dédié (noatime) pour /var/lib/mongodb
# Simule un disque dédié par un fichier image monté en boucle (loop).
# Usage : sudo bash ~/bd511/ch02/02-volume-xfs.sh [taille_en_Go]   (8 Go par défaut)
set -euo pipefail
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }

IMAGE=/var/lib/mongodb-xfs.img
POINT=/var/lib/mongodb
TAILLE_GO=${1:-8}

getent passwd mongodb >/dev/null || { echo "Utilisateur mongodb absent : faites d'abord la partie 1." >&2; exit 1; }
command -v mkfs.xfs >/dev/null || apt-get install -y xfsprogs

if findmnt -n -t xfs "$POINT" >/dev/null; then
  echo "$POINT est déjà un volume XFS monté : rien à faire."
  findmnt "$POINT"
  exit 0
fi

# mongod ne doit pas tourner pendant la préparation du volume.
systemctl stop mongod 2>/dev/null || true

# Le point de montage doit être vide : d'éventuelles données créées sur ext4 sont mises de côté.
if [[ -d $POINT && -n $(ls -A "$POINT") ]]; then
  sauvegarde="$POINT.ext4-$(date +%Y%m%d%H%M%S)"
  echo "Contenu existant de $POINT déplacé vers $sauvegarde"
  mv "$POINT" "$sauvegarde"
fi
mkdir -p "$POINT"

if [[ ! -f $IMAGE ]]; then
  libre=$(df --output=avail -BG "$(dirname "$IMAGE")" | tail -n 1 | tr -dc '0-9')
  (( libre - 3 < TAILLE_GO )) && TAILLE_GO=$(( libre - 3 ))
  (( TAILLE_GO >= 2 )) || { echo "Espace disque insuffisant (${libre} Go libres)." >&2; exit 1; }
  echo "Création de $IMAGE (${TAILLE_GO} Go)..."
  fallocate -l "${TAILLE_GO}G" "$IMAGE"
  chmod 600 "$IMAGE"
fi

if [[ $(blkid -p -s TYPE -o value "$IMAGE" 2>/dev/null || true) != xfs ]]; then
  echo "Formatage XFS..."
  mkfs.xfs -q -f -L mongodata "$IMAGE"
fi

if ! grep -qE "^${IMAGE}[[:space:]]" /etc/fstab; then
  cp /etc/fstab "/etc/fstab.bak-$(date +%Y%m%d%H%M%S)"
  printf '%s\t%s\txfs\tdefaults,loop,noatime,nofail\t0\t0\n' "$IMAGE" "$POINT" >> /etc/fstab
fi

systemctl daemon-reload
mount "$POINT"
chown mongodb:mongodb "$POINT"
chmod 0750 "$POINT"
findmnt "$POINT"
EOF
sudo bash ~/bd511/ch02/02-volume-xfs.sh
```

Résultat attendu (le numéro du périphérique `loop` varie) :

```text
Création de /var/lib/mongodb-xfs.img (8 Go)...
Formatage XFS...
TARGET           SOURCE     FSTYPE OPTIONS
/var/lib/mongodb /dev/loop8 xfs    rw,noatime,attr2,inode64,logbufs=8,logbsize=32k,noquota
```

L'option `nofail` évite qu'un volume de données absent bloque le démarrage de la VM ; dans ce cas c'est `mongod` qui ne démarrera pas (partie 2.5), ce qui est le comportement souhaité.

### 2.2 Activer les Transparent Huge Pages (THP)

**La recommandation a changé avec MongoDB 8.0.** Jusqu'en 7.0, il fallait désactiver les THP. Depuis 8.0, MongoDB utilise une version récente de TCMalloc qui tire parti des pages de 2 Mo : il faut au contraire **les activer**, avec une défragmentation différée (`defer+madvise`) et `khugepaged/max_ptes_none = 0` pour limiter la mémoire gaspillée. Le service officiel fixe aussi `vm.overcommit_memory = 1`.

Ubuntu 24.04 configure par défaut les THP en mode `madvise`. Créez le service systemd fourni par la documentation MongoDB, qui applique ces réglages à chaque démarrage, avant `mongod` :

```bash
sudo tee /etc/systemd/system/enable-transparent-huge-pages.service > /dev/null <<'EOF'
[Unit]
Description=Enable Transparent Hugepages (THP)
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=mongod.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo always | tee /sys/kernel/mm/transparent_hugepage/enabled > /dev/null && echo defer+madvise | tee /sys/kernel/mm/transparent_hugepage/defrag > /dev/null && echo 0 | tee /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none > /dev/null && echo 1 | tee /proc/sys/vm/overcommit_memory > /dev/null'

[Install]
WantedBy=basic.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now enable-transparent-huge-pages
```

Vérifiez :

```bash
cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/defrag \
    /sys/kernel/mm/transparent_hugepage/khugepaged/max_ptes_none /proc/sys/vm/overcommit_memory
```

Résultat attendu (la valeur active est entre crochets) :

```text
[always] madvise never
always defer [defer+madvise] madvise never
0
1
```

### 2.3 Régler les paramètres du noyau (sysctl)

```bash
sudo tee /etc/sysctl.d/90-mongodb.conf > /dev/null <<'EOF'
# BD511 - Paramètres noyau recommandés pour MongoDB (Production Notes)
# vm.overcommit_memory = 1 est appliqué par enable-transparent-huge-pages.service.

# Ne swapper qu'en dernier recours : le swap dégrade fortement les performances.
vm.swappiness = 1

# Pas de récupération de mémoire locale au nœud NUMA (évite des blocages).
vm.zone_reclaim_mode = 0

# Détection plus rapide des connexions TCP mortes (replica sets, clients derrière un pare-feu).
net.ipv4.tcp_keepalive_time = 120

# Au moins 2 x le nombre maximal de connexions entrantes de mongod,
# sinon avertissement « vm.max_map_count is too low » au démarrage.
vm.max_map_count = 1048576
EOF
sudo sysctl -p /etc/sysctl.d/90-mongodb.conf
```

Résultat attendu :

```text
vm.swappiness = 1
vm.zone_reclaim_mode = 0
net.ipv4.tcp_keepalive_time = 120
vm.max_map_count = 1048576
```

Avec `LimitNOFILE=64000`, `mongod` accepte au plus 80 % de la moitié des descripteurs, soit 25 600 connexions : `vm.max_map_count` doit donc valoir au moins 51 200. Ubuntu 24.04 fixe déjà 1 048 576 ; le fichier rend cette valeur explicite et portable.

### 2.4 Choisir l'ordonnanceur d'E/S des disques

Dans une machine virtuelle, c'est l'hyperviseur qui ordonnance réellement les accès disque. MongoDB recommande donc l'ordonnanceur **`none`** dans le système invité (Ubuntu utilise `mq-deadline` par défaut pour les disques SATA/SCSI). Une règle udev l'applique à chaque démarrage :

```bash
sudo mkdir -p /etc/udev/rules.d
sudo tee /etc/udev/rules.d/60-mongodb-io-scheduler.rules > /dev/null <<'EOF'
# BD511 - Ordonnanceur d'E/S « none » pour les disques d'une VM (recommandation MongoDB)
ACTION=="add|change", SUBSYSTEM=="block", ENV{DEVTYPE}=="disk", KERNEL=="sd[a-z]|vd[a-z]|xvd[a-z]|nvme[0-9]*n[0-9]*", ATTR{queue/scheduler}="none"
EOF
sudo udevadm control --reload
sudo udevadm trigger --action=change --subsystem-match=block --property-match=DEVTYPE=disk
grep -H . /sys/block/{sd,vd,xvd,nvme}*/queue/scheduler 2>/dev/null
```

Résultat attendu (exemple avec un disque SATA VirtualBox) :

```text
/sys/block/sda/queue/scheduler:[none] mq-deadline
```

Sur un serveur physique, la recommandation est `none` pour les SSD et NVMe, `mq-deadline` pour les disques rotatifs.

### 2.5 Compléter l'unité systemd de `mongod`

On ne modifie jamais `/lib/systemd/system/mongod.service`, qui appartient au paquet et serait écrasée à la prochaine mise à jour. On crée un **fichier complémentaire** (*drop-in*) dans `/etc/systemd/system/mongod.service.d/` :

- `RequiresMountsFor` : `mongod` ne démarre que si le volume de données est monté ; sans lui, `mongod` écrirait dans le répertoire vide du disque système ;
- `Wants` et `After` : les THP sont configurées avant `mongod` ;
- `ExecStartPre` : fixe le *readahead* du volume de données à 32 secteurs de 512 octets (16 Kio), dans la plage recommandée de 8 à 32. Le préfixe `+` exécute cette commande avec les droits root (le service tourne sous `mongodb`), le préfixe `-` évite qu'un échec bloque le démarrage.

```bash
sudo mkdir -p /etc/systemd/system/mongod.service.d
sudo tee /etc/systemd/system/mongod.service.d/10-bd511.conf > /dev/null <<'EOF'
# BD511 - Complément à l'unité mongod.service du paquet mongodb-org-server
[Unit]
RequiresMountsFor=/var/lib/mongodb
Wants=enable-transparent-huge-pages.service
After=enable-transparent-huge-pages.service

[Service]
ExecStartPre=-+/bin/sh -c '/usr/sbin/blockdev --setra 32 "$$(/usr/bin/findmnt -n -o SOURCE --target /var/lib/mongodb)"'
EOF
sudo systemctl daemon-reload
systemctl cat mongod | tail -n 9
```

> **NUMA.** Sur un serveur physique à plusieurs nœuds NUMA (`lscpu | grep 'NUMA node(s)'` supérieur à 1), le même fichier complémentaire servirait aussi à lancer `mongod` sous `numactl --interleave=all` : une ligne `ExecStart=` vide, puis `ExecStart=/usr/bin/numactl --interleave=all /usr/bin/mongod --config /etc/mongod.conf`. La VM du TP n'a qu'un nœud : ce réglage est inutile ici.

### 2.6 Écrire le fichier de configuration `/etc/mongod.conf`

Le fichier de configuration est au format **YAML** : la hiérarchie est donnée par l'indentation, **toujours avec des espaces, jamais de tabulation**. Conservez une copie du fichier d'origine, puis remplacez-le par la version commentée du TP :

```bash
[ -f /etc/mongod.conf.orig ] || sudo cp /etc/mongod.conf /etc/mongod.conf.orig
sudo tee /etc/mongod.conf > /dev/null <<'EOF'
# /etc/mongod.conf - BD511, chapitre 2
# Référence : https://www.mongodb.com/docs/manual/reference/configuration-options/
# Format YAML : indentation par espaces uniquement (jamais de tabulation).

# --- Stockage -----------------------------------------------------------------
storage:
  # Répertoire des données : volume XFS dédié, monté en noatime (partie 2.1).
  dbPath: /var/lib/mongodb
  # Le journal WiredTiger est toujours actif (il n'est plus désactivable depuis la 6.1).
  # Cache WiredTiger par défaut : 50 % de (RAM - 1 Go), 256 Mo au minimum.
  # Ne le fixer que si d'autres processus partagent la machine, par exemple :
  # wiredTiger:
  #   engineConfig:
  #     cacheSizeGB: 1

# --- Journalisation -------------------------------------------------------------
systemLog:
  destination: file
  path: /var/log/mongodb/mongod.log
  # Ajoute au fichier existant au redémarrage au lieu de le renommer.
  logAppend: true

# --- Réseau ----------------------------------------------------------------------
net:
  port: 27017
  # Écoute sur l'interface locale uniquement : aucune connexion depuis le réseau.
  # L'ouverture réseau se fera avec l'authentification et le pare-feu (chapitre 5).
  bindIp: 127.0.0.1

# --- Gestion du processus --------------------------------------------------------
processManagement:
  # Base des fuseaux horaires (opérateurs de date de l'agrégation).
  timeZoneInfo: /usr/share/zoneinfo
  # Pas de « fork: true » : le processus est supervisé par systemd.

# --- Sections activées dans les chapitres suivants -------------------------------
#security:            # chapitre 5 - authentification et rôles
#  authorization: enabled
#replication:         # chapitre 6 - replica set
#sharding:            # chapitre 7 - cluster shardé
#operationProfiling:  # chapitre 8 - profiler et requêtes lentes
EOF
```

Contrôlez la syntaxe YAML avant le démarrage (aucune sortie = aucune tabulation dans le fichier) :

```bash
grep -nP '\t' /etc/mongod.conf
```

### 2.7 Démarrer le service et l'activer au démarrage de la VM

```bash
sudo systemctl enable --now mongod
systemctl status mongod --no-pager
```

Résultat attendu (extrait) :

```text
● mongod.service - MongoDB Database Server
     Loaded: loaded (/usr/lib/systemd/system/mongod.service; enabled; preset: enabled)
    Drop-In: /etc/systemd/system/mongod.service.d
             └─10-bd511.conf
     Active: active (running) since ...
       Docs: https://docs.mongodb.org/manual
    Process: ... ExecStartPre=/bin/sh -c ... (code=exited, status=0/SUCCESS)
   Main PID: ... (mongod)
```

Les commandes de gestion du service à connaître :

| Action | Commande |
| --- | --- |
| Démarrer / arrêter / redémarrer | `sudo systemctl start mongod` · `stop` · `restart` |
| Activer / désactiver au démarrage de la VM | `sudo systemctl enable mongod` · `disable` |
| État du service | `systemctl status mongod` |
| Messages de systemd sur le service | `journalctl -u mongod` |
| Journal de MongoDB | `/var/log/mongodb/mongod.log` (une ligne JSON par événement) |

Le journal de MongoDB est au **format JSON structuré** (depuis la 4.4). Avec `jq`, affichez le message indiquant que le serveur est prêt :

```bash
sudo jq -c 'select(.msg == "Waiting for connections") | {date: .t["$date"], msg, port: .attr.port}' \
  /var/log/mongodb/mongod.log | tail -n 1
```

Résultat attendu :

```text
{"date":"2026-10-19T21:02:11.347+02:00","msg":"Waiting for connections","port":27017}
```

Vérifiez ensuite les points qui ne se voient qu'une fois le processus lancé : adresse d'écoute, limites `ulimit` et variable d'environnement rseq.

```bash
sudo ss -ltnp 'sport = :27017'
grep -E 'Max open files|Max processes' /proc/$(pidof mongod)/limits
sudo cat /proc/$(pidof mongod)/environ | tr '\0' '\n' | grep GLIBC_TUNABLES
```

Résultat attendu :

```text
State  Recv-Q Send-Q Local Address:Port  Peer Address:Port Process
LISTEN 0      4096       127.0.0.1:27017      0.0.0.0:*     users:(("mongod",pid=4242,fd=14))
Max processes             64000                64000                processes
Max open files            64000                64000                files
GLIBC_TUNABLES=glibc.pthread.rseq=0
```

### 2.8 Générer le script de contrôle global

Ce script vérifie en une fois l'ensemble des réglages de production et l'état du serveur. Il servira à la fin du TP (partie 6) et après chaque redémarrage de la VM.

```bash
cat > ~/bd511/ch02/check-mongodb.sh <<'EOF'
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
EOF
```

Le seul avertissement de démarrage toléré à ce stade est « Access control is not enabled for the database » : l'authentification sera activée au chapitre 5.

---

## Partie 3 – Premiers tests de connexion avec mongosh

### 3.1 Connexion interactive

Sans argument, `mongosh` se connecte à `mongodb://127.0.0.1:27017`, l'instance locale :

```bash
mongosh
```

Résultat attendu :

```text
Current Mongosh Log ID: 6714f0a2c3b5e1d2a9f87b31
Connecting to:          mongodb://127.0.0.1:27017/?directConnection=true&serverSelectionTimeoutMS=2000&appName=mongosh+2.13.0
Using MongoDB:          8.3.13
Using Mongosh:          2.13.0

For mongosh info see: https://www.mongodb.com/docs/mongodb-shell/

------
   The server generated these startup warnings when booting
   2026-10-19T21:02:11.120+02:00: Access control is not enabled for the database. Read and write access to data and configuration is unrestricted
------

test>
```

- Au tout premier lancement, mongosh affiche aussi un message sur la collecte de données d'usage anonymes ; la commande `disableTelemetry()` la désactive.
- La liste des avertissements de démarrage (*startup warnings*) est le meilleur indicateur de la qualité d'une installation : grâce aux réglages de la partie 2, il ne reste que l'absence de contrôle d'accès. Sur une installation par défaut, vous auriez vu en plus des avertissements sur XFS, les THP, `max_ptes_none` et `vm.swappiness`.
- L'invite `test>` indique la base courante : `test` par défaut.

Dans mongosh, tapez les commandes suivantes une par une et observez les résultats :

```javascript
db.version()
db.hello().isWritablePrimary
show dbs
db.serverStatus().tcmalloc.usingPerCPUCaches
db.hostInfo().extra.kernelVersion
db.adminCommand({ getCmdLineOpts: 1 }).parsed
db.adminCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg)
```

| Commande | Résultat attendu | Signification |
| --- | --- | --- |
| `db.version()` | `8.3.13` | version du serveur |
| `db.hello().isWritablePrimary` | `true` | instance autonome (*standalone*) qui accepte les écritures |
| `show dbs` | `admin`, `config`, `local` | bases système créées au premier démarrage |
| `…tcmalloc.usingPerCPUCaches` | `true` | TCMalloc utilise ses caches par CPU (rseq désactivé dans la glibc) |
| `…extra.kernelVersion` | `6.8.0-147-generic` | noyau vu par le serveur |
| `getCmdLineOpts` | contenu de `/etc/mongod.conf` | configuration effectivement chargée |
| `getLog` | un seul message | avertissements de démarrage |

Quittez mongosh :

```javascript
exit
```

### 3.2 Importer le jeu de données du TP

Le jeu de données est un catalogue **fictif** de 24 formations, au format JSON *Extended* (une ligne par document). Il illustre les types BSON vus au chapitre 1 : chaînes, entiers, booléens, nombres décimaux exacts (`$numberDecimal` pour les prix), dates (`$date`), tableaux et documents imbriqués (les sessions). Certains champs ne sont présents que dans une partie des documents, ce qui montre la souplesse du schéma.

```bash
cat > ~/bd511/ch02/formations.json <<'EOF'
{"_id":"BD511","titre":"NoSQL MongoDB : mise en œuvre et administration","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-10-18T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-16T09:00:00Z"},"ville":"Paris","places":12,"inscrits":9},{"debut":{"$date":"2026-12-14T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":4},{"debut":{"$date":"2027-01-25T09:00:00Z"},"ville":"À distance","places":12,"inscrits":2}],"tags":["mongodb","nosql","administration","replica set","sharding"],"note_moyenne":4.7}
{"_id":"BD512","titre":"MongoDB pour les développeurs","domaine":"Bases de données","niveau":"Fondamental","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-09-02T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-23T09:00:00Z"},"ville":"Paris","places":12,"inscrits":11},{"debut":{"$date":"2027-02-08T09:00:00Z"},"ville":"Nantes","places":10,"inscrits":3}],"tags":["mongodb","développement","agrégation","drivers"],"note_moyenne":4.5}
{"_id":"BD513","titre":"Apache Cassandra : architecture et exploitation","domaine":"Bases de données","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2290.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-06-15T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Paris","places":8,"inscrits":5}],"tags":["cassandra","nosql","cql","haute disponibilité"],"prerequis":["BD511"]}
{"_id":"BD514","titre":"Redis : cache, structures de données et haute disponibilité","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-05-20T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-30T09:00:00Z"},"ville":"À distance","places":14,"inscrits":7}],"tags":["redis","clé-valeur","cache","sentinel"],"note_moyenne":4.4}
{"_id":"BD515","titre":"Neo4j et le langage Cypher","domaine":"Bases de données","niveau":"Fondamental","duree_jours":2,"prix_ht":{"$numberDecimal":"1390.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-03-11T00:00:00Z"},"sessions":[],"tags":["neo4j","graphes","cypher"]}
{"_id":"BD516","titre":"Elastic Stack : Elasticsearch, Logstash et Kibana","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-10-05T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-09T09:00:00Z"},"ville":"Paris","places":12,"inscrits":10},{"debut":{"$date":"2027-01-18T09:00:00Z"},"ville":"Toulouse","places":10,"inscrits":1}],"tags":["elasticsearch","logstash","kibana","recherche"],"note_moyenne":4.6}
{"_id":"BD520","titre":"PostgreSQL : administration","domaine":"Bases de données","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2590.00"},"modalites":["présentiel","classe virtuelle","intra-entreprise"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-08-28T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-01T09:00:00Z"},"ville":"Paris","places":12,"inscrits":12},{"debut":{"$date":"2027-03-08T09:00:00Z"},"ville":"Lille","places":10,"inscrits":0}],"tags":["postgresql","sql","administration","sauvegarde"],"note_moyenne":4.8}
{"_id":"BG601","titre":"Hadoop et HDFS : les fondamentaux","domaine":"Big Data","niveau":"Fondamental","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-04-02T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-16T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":6}],"tags":["hadoop","hdfs","yarn"]}
{"_id":"BG602","titre":"Apache Spark avancé","domaine":"Big Data","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2390.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-07-21T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"À distance","places":12,"inscrits":8}],"tags":["spark","dataframe","streaming","optimisation"],"prerequis":["BG601"],"note_moyenne":4.6}
{"_id":"BG603","titre":"Apache Kafka : streaming d'événements","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-09-14T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-02T09:00:00Z"},"ville":"Paris","places":12,"inscrits":12},{"debut":{"$date":"2027-01-11T09:00:00Z"},"ville":"Bordeaux","places":10,"inscrits":5}],"tags":["kafka","événements","streaming","event sourcing"],"note_moyenne":4.7}
{"_id":"BG604","titre":"Apache NiFi : conception de flux de données","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1590.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-02-17T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-02-15T09:00:00Z"},"ville":"À distance","places":12,"inscrits":3}],"tags":["nifi","ingestion","etl"]}
{"_id":"BG605","titre":"Apache Airflow : orchestration de pipelines","domaine":"Big Data","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1590.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-07-19T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-10T09:00:00Z"},"ville":"Paris","places":12,"inscrits":4}],"tags":["airflow","orchestration","dag","python"],"note_moyenne":4.3}
{"_id":"BG606","titre":"Apache Hive : entrepôt de données sur Hadoop","domaine":"Big Data","niveau":"Avancé","duree_jours":2,"prix_ht":{"$numberDecimal":"1690.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-01T00:00:00Z"},"sessions":[],"tags":["hive","hiveql","tez","llap"],"prerequis":["BG601"]}
{"_id":"IA101","titre":"IA générative : panorama et usages","domaine":"Intelligence artificielle","niveau":"Fondamental","duree_jours":1,"prix_ht":{"$numberDecimal":"790.00"},"modalites":["classe virtuelle","intra-entreprise"],"certifiante":false,"mise_a_jour":{"$date":"2026-09-30T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-05T09:00:00Z"},"ville":"À distance","places":20,"inscrits":17},{"debut":{"$date":"2026-12-03T09:00:00Z"},"ville":"À distance","places":20,"inscrits":6}],"tags":["ia générative","llm","prompt"],"note_moyenne":4.5}
{"_id":"IA102","titre":"IA agentique : conception d'applications multi-agents avec des LLM","domaine":"Intelligence artificielle","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-10T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-14T09:00:00Z"},"ville":"Paris","places":10,"inscrits":7}],"tags":["agents","langgraph","rag","llm"],"prerequis":["IA101","PY201"]}
{"_id":"IA103","titre":"Machine learning avec Python","domaine":"Intelligence artificielle","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2690.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-06-03T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-23T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":10},{"debut":{"$date":"2027-02-01T09:00:00Z"},"ville":"Paris","places":12,"inscrits":3}],"tags":["machine learning","scikit-learn","python"],"prerequis":["PY201"],"note_moyenne":4.6}
{"_id":"DO301","titre":"Docker : conteneuriser ses applications","domaine":"DevOps","niveau":"Fondamental","duree_jours":2,"prix_ht":{"$numberDecimal":"1390.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-08-12T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-12T09:00:00Z"},"ville":"Paris","places":12,"inscrits":8},{"debut":{"$date":"2026-12-17T09:00:00Z"},"ville":"Marseille","places":10,"inscrits":2}],"tags":["docker","conteneurs","compose"],"note_moyenne":4.6}
{"_id":"DO302","titre":"Kubernetes : déploiement et exploitation","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":4,"prix_ht":{"$numberDecimal":"2690.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"mise_a_jour":{"$date":"2026-09-22T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-12-01T09:00:00Z"},"ville":"À distance","places":12,"inscrits":9}],"tags":["kubernetes","orchestration","helm"],"prerequis":["DO301"],"note_moyenne":4.7}
{"_id":"DO303","titre":"Ansible : automatisation de l'infrastructure","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-05-06T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-01-20T09:00:00Z"},"ville":"Rennes","places":10,"inscrits":4}],"tags":["ansible","automatisation","infrastructure as code"]}
{"_id":"DO304","titre":"Supervision avec Prometheus et Grafana","domaine":"DevOps","niveau":"Intermédiaire","duree_jours":2,"prix_ht":{"$numberDecimal":"1490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-10-12T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-26T09:00:00Z"},"ville":"Paris","places":12,"inscrits":6}],"tags":["prometheus","grafana","alerting","supervision"],"note_moyenne":4.5}
{"_id":"SY401","titre":"Administration Linux : les fondamentaux","domaine":"Systèmes","niveau":"Fondamental","duree_jours":5,"prix_ht":{"$numberDecimal":"2490.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-01-14T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-02T09:00:00Z"},"ville":"Paris","places":12,"inscrits":11},{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Lyon","places":10,"inscrits":5},{"debut":{"$date":"2027-01-11T09:00:00Z"},"ville":"À distance","places":14,"inscrits":3}],"tags":["linux","bash","systemd","administration"],"note_moyenne":4.4}
{"_id":"SY402","titre":"Linux : performances et optimisation","domaine":"Systèmes","niveau":"Avancé","duree_jours":3,"prix_ht":{"$numberDecimal":"2190.00"},"modalites":["présentiel"],"certifiante":false,"mise_a_jour":{"$date":"2026-04-28T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-02-22T09:00:00Z"},"ville":"Paris","places":8,"inscrits":2}],"tags":["linux","performances","noyau","sysctl"],"prerequis":["SY401"]}
{"_id":"PY201","titre":"Python : les fondamentaux","domaine":"Programmation","niveau":"Fondamental","duree_jours":4,"prix_ht":{"$numberDecimal":"1990.00"},"modalites":["présentiel","classe virtuelle"],"certifiante":true,"eligible_cpf":true,"mise_a_jour":{"$date":"2026-07-01T00:00:00Z"},"sessions":[{"debut":{"$date":"2026-11-09T09:00:00Z"},"ville":"À distance","places":16,"inscrits":14},{"debut":{"$date":"2026-12-07T09:00:00Z"},"ville":"Nantes","places":10,"inscrits":6}],"tags":["python","programmation"],"note_moyenne":4.8}
{"_id":"PY202","titre":"Python pour l'analyse de données","domaine":"Programmation","niveau":"Intermédiaire","duree_jours":3,"prix_ht":{"$numberDecimal":"1790.00"},"modalites":["classe virtuelle"],"certifiante":false,"mise_a_jour":{"$date":"2026-08-25T00:00:00Z"},"sessions":[{"debut":{"$date":"2027-01-25T09:00:00Z"},"ville":"À distance","places":16,"inscrits":5}],"tags":["python","pandas","visualisation"],"prerequis":["PY201"]}
EOF
wc -l ~/bd511/ch02/formations.json
```

Résultat attendu :

```text
24 /home/<votre-compte>/bd511/ch02/formations.json
```

Importez le fichier avec `mongoimport` (Database Tools) dans la collection `formations` de la base `bd511`. L'option `--drop` vide la collection avant l'import, ce qui permet de relancer la commande sans créer de doublons :

```bash
mongoimport --uri "mongodb://127.0.0.1:27017" --db bd511 --collection formations \
  --drop --file ~/bd511/ch02/formations.json
```

Résultat attendu :

```text
2026-10-19T21:10:42.512+0200	connected to: mongodb://127.0.0.1:27017
2026-10-19T21:10:42.513+0200	dropping: bd511.formations
2026-10-19T21:10:42.561+0200	24 document(s) imported successfully. 0 document(s) failed to import.
```

### 3.3 Interroger les données

Connectez-vous en indiquant cette fois une **chaîne de connexion** (URI) complète, qui sélectionne directement la base `bd511` :

```bash
mongosh "mongodb://127.0.0.1:27017/bd511"
```

Puis, dans mongosh :

```javascript
db.getName()
show collections
db.formations.countDocuments()
db.formations.countDocuments({ domaine: "Bases de données" })
db.formations.find({ domaine: "Bases de données" }, { titre: 1, duree_jours: 1 }).sort({ _id: 1 })
db.formations.findOne({ _id: "BD511" })
```

Résultats attendus :

| Commande | Résultat |
| --- | --- |
| `db.getName()` | `bd511` |
| `show collections` | `formations` |
| `countDocuments()` | `24` |
| `countDocuments({ domaine: "Bases de données" })` | `7` |
| `find(...)` | 7 documents, de `BD511` à `BD520`, avec seulement `_id`, `titre` et `duree_jours` |

Le document `BD511` affiché par `findOne` montre les types BSON restitués par mongosh :

```text
{
  _id: 'BD511',
  titre: 'NoSQL MongoDB : mise en œuvre et administration',
  domaine: 'Bases de données',
  niveau: 'Intermédiaire',
  duree_jours: 3,
  prix_ht: Decimal128('2190.00'),
  modalites: [ 'présentiel', 'classe virtuelle' ],
  certifiante: false,
  eligible_cpf: true,
  mise_a_jour: ISODate('2026-10-18T00:00:00.000Z'),
  sessions: [
    {
      debut: ISODate('2026-11-16T09:00:00.000Z'),
      ville: 'Paris',
      places: 12,
      inscrits: 9
    },
...
```

Quittez avec `exit`.

### 3.4 Utiliser mongosh de façon non interactive

mongosh s'utilise aussi dans des scripts d'exploitation, avec `--eval` pour une commande courte ou `--file` pour un fichier JavaScript. L'option `--quiet` supprime la bannière.

```bash
mongosh --quiet --eval 'db.getSiblingDB("bd511").formations.distinct("domaine").sort()'
```

Résultat attendu :

```text
[
  'Bases de données',
  'Big Data',
  'DevOps',
  'Intelligence artificielle',
  'Programmation',
  'Systèmes'
]
```

Générez le script de test de connexion, qui rassemble les informations utiles après une installation :

```bash
cat > ~/bd511/ch02/test-connexion.js <<'EOF'
// test-connexion.js - BD511 ch.2 : informations de connexion après installation
// Usage : mongosh --quiet --file ~/bd511/ch02/test-connexion.js
const admin = db.getSiblingDB("admin");
const build = admin.runCommand({ buildInfo: 1 });
const statut = admin.runCommand({ serverStatus: 1 });
const options = admin.runCommand({ getCmdLineOpts: 1 }).parsed;
const hote = admin.runCommand({ hostInfo: 1 });
const avertissements = admin.runCommand({ getLog: "startupWarnings" }).log.map(l => JSON.parse(l).msg);
const bases = admin.runCommand({ listDatabases: 1, nameOnly: true }).databases.map(b => b.name);
const formations = db.getSiblingDB("bd511").formations;

const ligne = (libelle, valeur) => print(libelle.padEnd(28) + ": " + valeur);
ligne("Serveur MongoDB", build.version + " (allocateur " + build.allocator + ")");
ligne("Shell mongosh", version());
ligne("Noyau Linux", hote.extra.kernelVersion);
ligne("Processus mongod", "PID " + String(statut.pid) + ", démarré depuis " + statut.uptime + " s");
ligne("Moteur de stockage", statut.storageEngine.name);
ligne("dbPath", options.storage.dbPath);
ligne("Écoute", options.net.bindIp + ":" + options.net.port);
ligne("Caches TCMalloc par CPU", statut.tcmalloc.usingPerCPUCaches);
ligne("Connexions", statut.connections.current + " ouverte(s), " + statut.connections.available + " disponible(s)");
ligne("Bases", bases.join(", "));
ligne("bd511.formations", formations.countDocuments() + " document(s)");
ligne("Avertissements de démarrage", avertissements.length);
avertissements.forEach(a => print("  - " + a));
EOF
mongosh --quiet --file ~/bd511/ch02/test-connexion.js
```

Résultat attendu :

```text
Serveur MongoDB             : 8.3.13 (allocateur tcmalloc-google)
Shell mongosh               : 2.13.0
Noyau Linux                 : 6.8.0-147-generic
Processus mongod            : PID 4242, démarré depuis 612 s
Moteur de stockage          : wiredTiger
dbPath                      : /var/lib/mongodb
Écoute                      : 127.0.0.1:27017
Caches TCMalloc par CPU     : true
Connexions                  : 1 ouverte(s), 25599 disponible(s)
Bases                       : admin, bd511, config, local
bd511.formations            : 24 document(s)
Avertissements de démarrage : 1
  - Access control is not enabled for the database. Read and write access to data and configuration is unrestricted
```

Le nombre de connexions disponibles confirme le calcul de la partie 2.3 : 80 % de la moitié de 64 000 descripteurs, soit 25 600 connexions au total.

---

## Partie 4 – Installation du client graphique MongoDB Compass

Compass est distribué **séparément** du serveur, sous forme de paquet `.deb` (Ubuntu 20.04 ou plus récent, x86_64 uniquement). Il nécessite un serveur MongoDB 7.0 ou plus récent.

### 4.1 Télécharger le paquet

```bash
cd ~/bd511/ch02
COMPASS_VERSION=1.53.0
curl -fLO "https://downloads.mongodb.com/compass/mongodb-compass_${COMPASS_VERSION}_amd64.deb"
dpkg-deb -f "mongodb-compass_${COMPASS_VERSION}_amd64.deb" Package Version
```

Résultat attendu (après la barre de progression du téléchargement, environ 130 Mo) :

```text
Package: mongodb-compass
Version: 1.53.0
```

### 4.2 Installer le paquet

L'installation avec `apt-get` (et non `dpkg -i`) résout automatiquement les dépendances (bibliothèques GTK, NSS, trousseau GNOME…) :

```bash
cd ~/bd511/ch02
COMPASS_VERSION=1.53.0
sudo apt-get install -y "./mongodb-compass_${COMPASS_VERSION}_amd64.deb"
```

Vérifiez l'installation :

```bash
mongodb-compass --version --no-sandbox
dpkg -s mongodb-compass | grep -E '^(Status|Version)'
ls -l /usr/lib/mongodb-compass/chrome-sandbox
```

Résultat attendu (des messages techniques d'Electron peuvent s'afficher en plus) :

```text
MongoDB Compass 1.53.0
Status: install ok installed
Version: 1.53.0
-rwsr-xr-x 1 root root 15232 ... /usr/lib/mongodb-compass/chrome-sandbox
```

Compass est une application Electron (moteur Chromium). Ubuntu 24.04 restreint par AppArmor la création d'espaces de noms utilisateur, que Chromium utilise pour isoler ses processus ; Compass se replie alors sur l'utilitaire `chrome-sandbox`, qui doit appartenir à `root` et porter le bit **setuid** (`s` dans `-rwsr-xr-x`). Le paquet le configure ainsi ; si ces droits sont modifiés, Compass ne démarre plus (voir l'annexe A).

---
#### Pour windows (si on a installé le serveur sur WSL2 par exemple) :

```bash
https://downloads.mongodb.com/compass/mongodb-compass-1.53.0-win32-x64.zip
```

## Partie 5 – Premiers tests de connexion avec Compass

### 5.1 Lancer Compass

Lancez Compass depuis le menu des applications (*Afficher les applications* ▸ **MongoDB Compass**) ou depuis le terminal :

```bash
nohup mongodb-compass > /dev/null 2>&1 &
```

Au premier lancement, la fenêtre **Welcome to Compass** s'affiche : cliquez sur **Start**. Le texte en bas de cette fenêtre indique que Compass envoie des données d'usage anonymes à MongoDB ; ce comportement se règle dans les paramètres de Compass (icône d'engrenage à côté du titre **Compass**, en haut du volet de gauche).

### 5.2 Créer la connexion à l'instance locale

1. Dans la section **CONNECTIONS** du volet de gauche, cliquez sur **Add new connection** (ou sur l'icône **+** à droite du titre **CONNECTIONS** si des connexions existent déjà).
2. Dans la fenêtre **New Connection**, remplacez le contenu du champ **URI** (`mongodb://localhost:27017/` par défaut) par :

   ```text
   mongodb://127.0.0.1:27017/?directConnection=true
   ```

   Utilisez l'adresse `127.0.0.1` plutôt que `localhost` : le serveur n'écoute qu'en IPv4 (`bindIp: 127.0.0.1`), et `localhost` peut être résolu en IPv6 (`::1`) par certains clients.
3. Dans le champ **Name**, saisissez `BD511 - local`. Choisissez une couleur dans la liste **Color** si vous le souhaitez et cochez **Favorite this connection**. La rubrique **Advanced Connection Options** (authentification, TLS, tunnel SSH) servira à partir du chapitre 5.
4. Cliquez sur **Save & Connect**.

Le volet de gauche affiche la connexion `BD511 - local` et, sous elle, les bases `admin`, `bd511`, `config` et `local`. Comme pour mongosh, aucun identifiant n'est demandé : l'authentification sera activée au chapitre 5.

> **Variante.** Compass accepte aussi la chaîne de connexion en argument : `mongodb-compass 'mongodb://127.0.0.1:27017/?directConnection=true'`.

### 5.3 Parcourir les données importées

1. Dépliez la base **bd511** et cliquez sur la collection **formations**.
2. L'onglet **Documents** affiche les documents par pages de 20 ; le compteur au-dessus de la liste indique 24 documents au total. Basculez entre les vues liste, JSON et tableau avec les icônes situées au-dessus des documents.
3. Dans la barre de filtre, saisissez le filtre suivant puis cliquez sur **Find** :

   ```javascript
   { domaine: "Bases de données" }
   ```

   Le compteur indique 7 documents, comme `countDocuments` dans mongosh.
4. Ouvrez l'onglet **Schema** et lancez l'analyse : Compass échantillonne les documents et affiche, pour chaque champ, ses types et sa fréquence. Repérez les champs présents dans une partie des documents seulement (`eligible_cpf`, `note_moyenne`, `prerequis`) et le type `Decimal128` de `prix_ht`.
5. Ouvrez l'onglet **Indexes** : seul l'index obligatoire `_id_` existe. Les index seront traités au chapitre 4.

### 5.4 Utiliser le shell mongosh intégré

Cliquez sur l'icône **>_** à droite du nom de la connexion dans la section **CONNECTIONS** (ou sur **Open MongoDB shell** en haut à droite d'un onglet). Le shell intégré s'ouvre en bas de la fenêtre ; saisissez :

```javascript
use bd511
db.formations.countDocuments()
db.version()
```

Résultats attendus : `24`, puis `8.3.13`. Ce shell est la même application mongosh que dans le terminal, embarquée dans Compass.

### 5.5 Vérifier que les deux clients voient les mêmes données

1. Dans Compass, onglet **Documents** de `bd511.formations`, cliquez sur **ADD DATA** ▸ **Insert document**, remplacez le contenu proposé par le document ci-dessous, puis cliquez sur **Insert** :

   ```json
   { "_id": "TEST-COMPASS", "titre": "Document créé depuis Compass", "domaine": "Test" }
   ```

2. Dans le terminal Linux , relisez ce document avec mongosh, puis supprimez-le :

   ```bash
   mongosh --quiet --eval 'db.getSiblingDB("bd511").formations.findOne({ _id: "TEST-COMPASS" })'
   mongosh --quiet --eval 'db.getSiblingDB("bd511").formations.deleteOne({ _id: "TEST-COMPASS" })'
   ```

   Résultat attendu :

   ```text
   {
     _id: 'TEST-COMPASS',
     titre: 'Document créé depuis Compass',
     domaine: 'Test'
   }
   { acknowledged: true, deletedCount: 1 }
   ```

Remarque : dans le terminal de Compass, on est dans le shell mongosh : les commandes dans ce cas auraient été : 

   ```bash
db.getSiblingDB("bd511").formations.findOne({ _id: "TEST-COMPASS" })
db.getSiblingDB("bd511").formations.deleteOne({ _id: "TEST-COMPASS" })
   ```

3. Dans Compass, cliquez sur **Find** (ou sur l'icône d'actualisation) : la collection compte de nouveau 24 documents.

---

## Partie 6 – Bilan et contrôle final

### 6.1 Contrôle global

```bash
sudo bash ~/bd511/ch02/check-mongodb.sh
```

Résultat attendu (exemple sur une VM VirtualBox avec un disque SATA) :

```text
== Noyau et processeur
  [OK] Noyau hors plage 6.19 - 7.0.13                 6.8.0-147-generic
  [OK] Jeu d'instructions AVX                         présent
== Mémoire (THP et sysctl)
  [OK] THP enabled = always                           [always] madvise never
  [OK] THP defrag = defer+madvise                     always defer [defer+madvise] madvise never
  [OK] THP khugepaged/max_ptes_none = 0               0
  [OK] vm.overcommit_memory = 1                       1
  [OK] vm.swappiness <= 1                             1
  [OK] vm.zone_reclaim_mode = 0                       0
  [OK] vm.max_map_count >= 51200                      1048576
  [OK] net.ipv4.tcp_keepalive_time = 120              120
== Stockage
  [OK] Système de fichiers de /var/lib/mongodb = xfs  xfs
  [OK] Montage avec noatime                           rw,noatime
  [OK] Readahead de /dev/loop8 entre 8 et 32          32
  [OK] Ordonnanceur d'E/S de sda = none               [none] mq-deadline
  [OK] Propriétaire de /var/lib/mongodb               mongodb:mongodb 750
== Système
  [OK] Nœuds NUMA (1 attendu sur une VM)              1
  [OK] Horloge synchronisée (NTP)                     yes
== Service mongod
  [OK] mongod activé au démarrage                     enabled
  [OK] mongod en cours d'exécution                    active
  [OK] ulimit fichiers ouverts >= 64000               64000
  [OK] ulimit processus >= 64000                      64000
  [OK] glibc rseq désactivé                           GLIBC_TUNABLES=glibc.pthread.rseq=0
  [OK] Écoute réseau limitée à 127.0.0.1              127.0.0.1:27017
== Connexion avec mongosh
  [OK] Connexion à mongodb://127.0.0.1:27017          MongoDB 8.3.13
  [OK] Caches TCMalloc par CPU actifs                 true
  [OK] Aucun autre avertissement que l'accès libre    1 avertissement(s)

Bilan : 26 OK, 0 KO
```

### 6.2 Vérifier la persistance après redémarrage

Un réglage de production n'est acquis que s'il survit à un redémarrage. Redémarrez la VM, puis relancez le contrôle **sans rien faire d'autre** :

```bash
sudo reboot
```

```bash
sudo bash ~/bd511/ch02/check-mongodb.sh
```

Le bilan doit être identique : montage du volume XFS par `/etc/fstab`, THP par `enable-transparent-huge-pages.service`, paramètres noyau par `/etc/sysctl.d`, ordonnanceur par la règle udev, démarrage automatique de `mongod` et *readahead* par son fichier complémentaire.

### 6.3 Ce qu'il faut retenir

- Les paquets officiels `mongodb-org` s'installent depuis le dépôt de la **branche** choisie (`mongodb-org/8.3`), signé par une clé GPG à vérifier ; on fige ensuite les versions (`apt-mark hold`).
- Le paquet fournit l'utilisateur `mongodb`, l'unité systemd `mongod.service` (déjà réglée pour les `ulimit` et la glibc) et `/etc/mongod.conf` (YAML : `storage.dbPath`, `systemLog`, `net.port`, `net.bindIp`).
- Le système se prépare **avant** le premier démarrage : noyau compatible, volume XFS en `noatime`, THP **activées** depuis la 8.0, `swappiness`, `zone_reclaim_mode`, `tcp_keepalive_time`, ordonnanceur et *readahead*.
- Les **avertissements de démarrage** (`getLog: "startupWarnings"`, ou la bannière de mongosh) sont le premier indicateur de la conformité d'une installation.
- mongosh et Compass sont des clients distincts du serveur ; ils utilisent la même chaîne de connexion `mongodb://hôte:port/`.

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `apt-get` : « Could not get lock /var/lib/dpkg/lock-frontend » | Mises à jour automatiques en cours | Le fichier de la partie 0.1 fait patienter `apt-get` ; sinon attendez la fin des mises à jour et relancez. |
| `mongod` s'arrête aussitôt ; journal : « MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility… » | Noyau HWE 7.0 d'Ubuntu 24.04.5 | Partie 0.4 (noyau GA 6.8), puis `sudo systemctl start mongod`. |
| `mongod` s'arrête aussitôt ; `journalctl -u mongod` affiche `Illegal instruction` ou `status=4/ILL` | Processeur virtuel sans AVX. Cas fréquent : VirtualBox sur un hôte Windows où Hyper-V (ou la sécurité basée sur la virtualisation) est actif | Désactivez Hyper-V, *Virtual Machine Platform* et l'intégrité de la mémoire sur l'hôte, ou utilisez un autre hyperviseur. Contrôle : `grep -c avx /proc/cpuinfo` doit être supérieur à 0. |
| `systemctl status mongod` : « Dependency failed » | Volume `/var/lib/mongodb` non monté (`RequiresMountsFor`) | `sudo mount /var/lib/mongodb`, vérifiez la ligne de `/etc/fstab`, relancez `02-volume-xfs.sh`. |
| `mongod` s'arrête aussitôt ; journal : `Error parsing YAML config file` | Tabulation ou indentation incorrecte dans `/etc/mongod.conf` | `grep -nP '\t' /etc/mongod.conf` ; corrigez l'indentation avec des espaces. |
| `mongod` s'arrête aussitôt ; journal : `Permission denied` sur `/var/lib/mongodb` ou `/var/log/mongodb` | Propriétaire incorrect | `sudo chown -R mongodb:mongodb /var/lib/mongodb /var/log/mongodb` |
| mongosh : `MongoNetworkError: connect ECONNREFUSED 127.0.0.1:27017` | Service arrêté ou en cours de démarrage | `systemctl status mongod`, puis `sudo tail -n 20 /var/log/mongodb/mongod.log \| jq -c '{msg, attr}'`. |
| Avertissement de démarrage sur `/sys/kernel/mm/transparent_hugepage/…` | Service THP inactif | `sudo systemctl enable --now enable-transparent-huge-pages && sudo systemctl restart mongod` |
| Avertissement « We suggest setting swappiness to 0 or 1 » | Fichier sysctl non appliqué | `sudo sysctl -p /etc/sysctl.d/90-mongodb.conf && sudo systemctl restart mongod` |
| Avertissement « Using the XFS filesystem is strongly recommended… » | `mongod` démarré avant la création du volume XFS | Relancez `sudo bash ~/bd511/ch02/02-volume-xfs.sh` (les données ext4 sont mises de côté), puis `sudo systemctl start mongod`. |
| Compass ne s'ouvre pas ; dans le terminal : « The SUID sandbox helper binary was found, but is not configured correctly » | Droits de `chrome-sandbox` modifiés | `sudo chown root:root /usr/lib/mongodb-compass/chrome-sandbox && sudo chmod 4755 /usr/lib/mongodb-compass/chrome-sandbox` |
| Fenêtre Compass noire ou vide | Accélération graphique de la VM | Lancez `mongodb-compass --disable-gpu`. |
| Compass : « connect ECONNREFUSED ::1:27017 » | Chaîne de connexion avec `localhost` résolu en IPv6 | Utilisez `mongodb://127.0.0.1:27017/?directConnection=true`. |
| VM ARM64 (Mac Apple Silicon) : Compass absent | Pas de Compass pour Linux ARM64 | Installez Compass sur le Mac et connectez-vous avec un tunnel SSH (onglet *Proxy/SSH* des options avancées de connexion). |

## Annexe B – Remettre la VM à zéro (formateur)

Ces commandes suppriment MongoDB, Compass, **toutes les données** et les réglages du TP. Le noyau GA est conservé.

```bash
sudo systemctl disable --now mongod
sudo umount /var/lib/mongodb
sudo sed -i '\#^/var/lib/mongodb-xfs.img[[:space:]]#d' /etc/fstab
sudo rm -f /var/lib/mongodb-xfs.img
sudo apt-mark unhold $(dpkg -l 'mongodb-*' | awk '/^[hi]i/ {print $2}')
sudo apt-get purge -y 'mongodb-org*' mongodb-mongosh mongodb-database-tools mongodb-compass
sudo rm -rf /var/lib/mongodb /var/lib/mongodb.ext4-* /var/log/mongodb /etc/mongod.conf /etc/mongod.conf.orig \
  /etc/systemd/system/mongod.service.d
sudo systemctl disable --now enable-transparent-huge-pages
sudo rm -f /etc/systemd/system/enable-transparent-huge-pages.service /etc/sysctl.d/90-mongodb.conf \
  /etc/udev/rules.d/60-mongodb-io-scheduler.rules /etc/apt/sources.list.d/mongodb-org-8.3.list \
  /usr/share/keyrings/mongodb-server-8.0.gpg
sudo systemctl daemon-reload
rm -rf ~/bd511/ch02
```

Redémarrez ensuite la VM pour revenir aux réglages noyau par défaut d'Ubuntu.

## Annexe C – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `/etc/apt/apt.conf.d/90-bd511-lock-timeout` | Attente du verrou APT au lieu d'un échec | 0.1 |
| `~/bd511/ch02/00-verif-plateforme.sh` | Contrôle des prérequis (OS, AVX, mémoire, disque, noyau) | 0.3 |
| `~/bd511/ch02/01-noyau-ga.sh` | Passage du noyau HWE au noyau GA 6.8 | 0.4 |
| `/usr/share/keyrings/mongodb-server-8.0.gpg` | Clé de signature du dépôt MongoDB | 1.1 |
| `/etc/apt/sources.list.d/mongodb-org-8.3.list` | Déclaration du dépôt MongoDB 8.3 | 1.2 |
| `~/bd511/ch02/02-volume-xfs.sh` | Création et montage du volume XFS de données | 2.1 |
| `/var/lib/mongodb-xfs.img` + ligne dans `/etc/fstab` | Volume XFS simulé, monté sur `/var/lib/mongodb` | 2.1 |
| `/etc/systemd/system/enable-transparent-huge-pages.service` | Activation des THP au démarrage | 2.2 |
| `/etc/sysctl.d/90-mongodb.conf` | Paramètres noyau recommandés | 2.3 |
| `/etc/udev/rules.d/60-mongodb-io-scheduler.rules` | Ordonnanceur d'E/S `none` | 2.4 |
| `/etc/systemd/system/mongod.service.d/10-bd511.conf` | Complément de l'unité `mongod` (montage, THP, *readahead*) | 2.5 |
| `/etc/mongod.conf` (original : `/etc/mongod.conf.orig`) | Configuration du serveur | 2.6 |
| `~/bd511/ch02/check-mongodb.sh` | Contrôle global de l'installation | 2.8, 6 |
| `~/bd511/ch02/formations.json` | Jeu de données (24 formations fictives) | 3.2 |
| `~/bd511/ch02/test-connexion.js` | Script mongosh de test de connexion | 3.4 |
| `~/bd511/ch02/mongodb-compass_1.53.0_amd64.deb` | Paquet d'installation de Compass | 4.1 |

## Annexe D – Références

- Installation de MongoDB Community sur Ubuntu : https://www.mongodb.com/docs/manual/tutorial/install-mongodb-on-ubuntu/
- Production Notes (Linux) : https://www.mongodb.com/docs/manual/administration/production-notes/
- TCMalloc et Transparent Huge Pages (8.0 et suivantes) : https://www.mongodb.com/docs/manual/administration/tcmalloc-performance/
- Réglages `ulimit` : https://www.mongodb.com/docs/manual/reference/ulimit/
- Options du fichier de configuration : https://www.mongodb.com/docs/manual/reference/configuration-options/
- Incompatibilité des noyaux 6.19 à 7.0.13 : https://jira.mongodb.org/browse/SERVER-121912 et https://jira.mongodb.org/browse/SERVER-131779
- Installation de Compass : https://www.mongodb.com/docs/compass/install/
- Connexion avec Compass : https://www.mongodb.com/docs/compass/connect/
- Noyaux GA et HWE d'Ubuntu : https://ubuntu.com/kernel/lifecycle
