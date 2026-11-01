# `01-noyau-ga.sh` — explications

**Module BD511 · Chapitre 2 · Remplacement de la pile noyau HWE par le noyau GA 6.8 d'Ubuntu 24.04**

## En bref

MongoDB 8.3 refuse de démarrer sur les noyaux Linux 6.19.0 à 7.0.13 (voir `00-verif-plateforme.md`). Or la pile noyau **HWE** d'Ubuntu 24.04 installe des noyaux récents qui peuvent tomber dans cette plage. Ce script remet la VM sur le noyau **GA** (*General Availability*) d'Ubuntu 24.04, la série **6.8**, en trois temps :

1. il installe le noyau GA 6.8 ;
2. il vérifie que ce noyau est bien présent, puis supprime tous les paquets de la pile HWE ;
3. il met à jour le chargeur de démarrage GRUB.

Contrairement au script `00`, celui-ci **modifie le système** : il doit être lancé avec `sudo` et suivi d'un redémarrage.

```bash
sudo bash ~/bd511/ch02/01-noyau-ga.sh
sudo reboot
```

> **L'ordre des opérations est essentiel.** On installe le nouveau noyau **avant** de supprimer l'ancien. Une machine sans aucun noyau installé ne pourrait plus démarrer.

---

## Explication instruction par instruction

### 1. En-tête et options de sécurité

```bash
#!/usr/bin/env bash
# 01-noyau-ga.sh - BD511 ch.2 : remplace la pile noyau HWE par le noyau GA 6.8 d'Ubuntu 24.04
# Usage : sudo bash ~/bd511/ch02/01-noyau-ga.sh   puis   sudo reboot
```

Le **shebang** (`#!/usr/bin/env bash`) indique que le fichier est un script bash. Les lignes commençant par `#` sont des commentaires : rôle du script et mode d'emploi.

```bash
set -euo pipefail
```

Trois options qui rendent le script prudent :

| Option | Effet |
|---|---|
| `-e` | le script s'arrête dès qu'une commande échoue |
| `-u` | le script s'arrête si une variable non définie est utilisée |
| `-o pipefail` | dans une chaîne `cmd1 \| cmd2`, l'échec de **n'importe quelle** commande fait échouer l'ensemble (par défaut, seule la dernière compte) |

Pour un script qui supprime des noyaux, il vaut mieux s'arrêter net au moindre problème plutôt que de continuer dans un état incertain.

```bash
[[ $EUID -eq 0 ]] || { echo "Lancez ce script avec sudo." >&2; exit 1; }
```

- `$EUID` est l'identifiant de l'utilisateur effectif ; il vaut `0` pour `root` (donc avec `sudo`) ;
- `-eq` compare deux nombres ;
- `||` : si le test échoue, on exécute le bloc entre accolades ;
- `>&2` envoie le message sur la **sortie d'erreur** plutôt que sur la sortie normale ;
- `exit 1` arrête le script avec un code d'erreur.

Installer et supprimer des paquets nécessite les droits administrateur.

```bash
. /etc/os-release
[[ ${VERSION_CODENAME:-} == noble ]] || { echo "Script prévu pour Ubuntu 24.04 (noble)." >&2; exit 1; }
```

- `. /etc/os-release` charge les informations sur la distribution sous forme de variables ;
- `VERSION_CODENAME` vaut `noble`, le nom de code d'Ubuntu 24.04 ;
- `${VERSION_CODENAME:-}` renvoie une chaîne vide si la variable n'existe pas (nécessaire avec `set -u`).

Le script refuse de tourner sur une autre version d'Ubuntu, où les noms de paquets et la version du noyau GA seraient différents.

### 2. Mode non interactif

```bash
# Mode non interactif : autorise la suppression du noyau en cours d'exécution
# (le noyau GA est installé avant, et la VM redémarre juste après).
export DEBIAN_FRONTEND=noninteractive
```

- Les paquets Debian/Ubuntu peuvent poser des questions pendant leur installation ou leur suppression, via un système appelé **debconf**. La variable `DEBIAN_FRONTEND=noninteractive` lui demande de ne rien demander et d'utiliser les réponses par défaut ;
- `export` transmet la variable aux programmes lancés par le script (`apt-get`, `dpkg` et les scripts des paquets) ;
- supprimer le noyau **en cours d'exécution** déclenche normalement un avertissement interactif. Comme l'expliquent les commentaires du script, ce n'est pas un problème ici : le noyau GA est déjà installé et la VM redémarre juste après.

### 3. Étape 1/4 — installer le noyau GA

```bash
echo "1/4 Installation du noyau GA (paquet linux-generic)..."
apt-get update -qq
apt-get install -y linux-generic
```

- `apt-get update` met à jour la liste des paquets disponibles depuis les dépôts Ubuntu ; `-qq` le rend très silencieux ;
- `apt-get install -y linux-generic` installe le **méta-paquet** `linux-generic`. Un méta-paquet ne contient rien en lui-même : il dépend des paquets à installer. Sur Ubuntu 24.04, `linux-generic` tire le noyau GA 6.8 le plus récent (image, modules et en-têtes) et le maintiendra à jour à chaque `apt upgrade` ;
- `-y` répond automatiquement « oui » à la confirmation.

```bash
noyau_ga=$(find /boot -maxdepth 1 -name 'vmlinuz-6.8.0-*-generic' -printf '%f\n' | sort -V | tail -n 1)
```

Retrouve le nom du noyau GA qui vient d'être installé :

- `find /boot` cherche dans `/boot`, où sont stockés les noyaux ;
- `-maxdepth 1` : sans descendre dans les sous-dossiers ;
- `-name 'vmlinuz-6.8.0-*-generic'` : fichiers dont le nom correspond à ce motif (les apostrophes empêchent bash d'interpréter le `*` lui-même) ;
- `-printf '%f\n'` n'affiche que le nom du fichier, sans le chemin ;
- `sort -V` trie par numéro de version (`6.8.0-100` après `6.8.0-99`, ce que ne ferait pas un tri alphabétique) ;
- `tail -n 1` garde la dernière ligne, donc la version la plus récente ;
- `$( ... )` range le résultat dans la variable `noyau_ga`.

```bash
[[ -n $noyau_ga ]] || { echo "Noyau GA 6.8 introuvable dans /boot : arrêt sans rien supprimer." >&2; exit 1; }
```

**Garde-fou** : `-n` teste si la chaîne n'est pas vide. Si aucun noyau 6.8 n'a été trouvé, le script s'arrête **avant** de supprimer quoi que ce soit, sinon la VM risquerait de ne plus démarrer.

```bash
echo "    Noyau GA installé : ${noyau_ga#vmlinuz-}"
```

`${noyau_ga#vmlinuz-}` retire le préfixe `vmlinuz-` : `vmlinuz-6.8.0-87-generic` s'affiche `6.8.0-87-generic`.

### 4. Étape 2/4 — repérer les paquets HWE

```bash
echo "2/4 Recherche des paquets de la pile HWE..."
mapfile -t paquets < <(
  dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*' 2>/dev/null |
    awk '$1 ~ /^ii/ {print $2}' |
    grep -E -- '-hwe-24\.04$|^linux-hwe-|-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(-[a-z0-9]+)?$' |
    grep -v -E -- '-6\.8\.0-[0-9]+(-[a-z0-9]+)?$' || true
)
```

C'est le cœur du script. Il construit la liste des paquets à supprimer dans le tableau `paquets`.

**Le remplissage du tableau**

- `mapfile -t paquets` lit des lignes et range chacune dans un élément du tableau `paquets` ; `-t` retire le retour à la ligne final de chaque élément ;
- `< <( ... )` est une **substitution de processus** : la sortie des commandes entre parenthèses est lue comme s'il s'agissait d'un fichier.

**La chaîne de filtres**, étape par étape :

1. `dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'linux-*'` liste tous les paquets dont le nom commence par `linux-`, avec leur état et leur nom, par exemple `ii  linux-image-6.8.0-87-generic`. `2>/dev/null` masque les messages d'erreur ;
2. `awk '$1 ~ /^ii/ {print $2}'` ne garde que les paquets **installés** (1ᵉʳ champ commençant par `ii`) et n'affiche que leur nom (2ᵉ champ) ;
3. `grep -E -- '...'` garde les noms qui correspondent à l'un des trois motifs (le `|` signifie « ou » dans une expression régulière étendue `-E`) :
   - `-hwe-24\.04$` : nom se terminant par `-hwe-24.04`, ce sont les méta-paquets HWE ;
   - `^linux-hwe-` : nom commençant par `linux-hwe-`, ce sont des paquets propres à la pile HWE (outils, en-têtes…) ;
   - `-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+(-[a-z0-9]+)?$` : nom se terminant par un numéro de noyau complet, comme `-6.17.0-19-generic` ou `-6.17.0-19`, ce sont des paquets liés à **une** version précise du noyau ;
4. `grep -v -E -- '-6\.8\.0-[0-9]+(-[a-z0-9]+)?$'` : `-v` **inverse** le filtre, donc retire de la liste tout ce qui concerne un noyau 6.8.0, c'est-à-dire le noyau GA qu'on veut garder.

Deux détails importants :

- `--` signale à `grep` la fin des options. Sans lui, le motif `-hwe-24\.04$`, qui commence par un tiret, serait pris pour une option ;
- `|| true` : si aucun paquet ne correspond, `grep` renvoie un code d'erreur. `|| true` garantit que l'ensemble réussit quand même (la liste est alors simplement vide).

**Exemples de tri** (numéros de version donnés à titre d'illustration) :

| Paquet installé | Sort | Raison |
|---|---|---|
| `linux-generic-hwe-24.04` | supprimé | se termine par `-hwe-24.04` |
| `linux-image-generic-hwe-24.04` | supprimé | se termine par `-hwe-24.04` |
| `linux-hwe-6.17-tools-6.17.0-19` | supprimé | commence par `linux-hwe-` |
| `linux-image-6.17.0-19-generic` | supprimé | numéro de noyau autre que 6.8.0 |
| `linux-modules-6.17.0-19-generic` | supprimé | numéro de noyau autre que 6.8.0 |
| `linux-image-6.8.0-87-generic` | **conservé** | noyau 6.8.0, exclu par `grep -v` |
| `linux-generic` | **conservé** | ne correspond à aucun motif |
| `linux-firmware` | **conservé** | ne correspond à aucun motif |

### 5. Étape 3/4 — supprimer la pile HWE

```bash
if (( ${#paquets[@]} == 0 )); then
  echo "    Aucun paquet HWE installé."
else
  printf '    %s\n' "${paquets[@]}"
  echo "3/4 Suppression de la pile HWE..."
  apt-get purge -y "${paquets[@]}"
fi
```

- `${#paquets[@]}` donne le **nombre d'éléments** du tableau. S'il vaut 0, il n'y a rien à supprimer ;
- `"${paquets[@]}"` donne tous les éléments du tableau, chacun comme un argument séparé ;
- `printf '    %s\n' ...` : `printf` réutilise son format pour chaque argument, ce qui affiche un paquet par ligne, en retrait ;
- `apt-get purge -y` supprime les paquets **et** leurs fichiers de configuration (`remove` laisserait la configuration en place).

Sans les méta-paquets HWE, plus aucune mise à jour ne réinstallera de noyau HWE : les mises à jour suivront désormais la série 6.8 via `linux-generic`.

### 6. Étape 4/4 — mettre à jour GRUB

```bash
echo "4/4 Mise à jour de la configuration GRUB..."
update-grub
```

GRUB est le **chargeur de démarrage** : il choisit le noyau lancé au démarrage de la machine. `update-grub` régénère son fichier de configuration (`/boot/grub/grub.cfg`) à partir des noyaux présents dans `/boot`. La suppression d'un noyau déclenche normalement déjà cette mise à jour ; l'appel explicite est une sécurité. Le noyau 6.8 étant désormais le seul installé, c'est lui qui démarrera.

```bash
echo
echo "Terminé. Redémarrez la VM maintenant : sudo reboot"
```

Affiche une ligne vide puis la consigne finale. Le redémarrage est indispensable : le noyau en mémoire ne change qu'au démarrage de la machine.

---

## Après le redémarrage

Vérifiez le noyau actif puis relancez le diagnostic :

```bash
uname -r                                  # doit afficher 6.8.0-…-generic
bash ~/bd511/ch02/00-verif-plateforme.sh  # toutes les lignes doivent être en [OK]
```
