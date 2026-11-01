# `00-verif-plateforme.sh` — explications

**Module BD511 · Chapitre 2 · Vérification des prérequis avant l'installation de MongoDB 8.3**

## En bref

Ce script fait un **diagnostic** de votre machine virtuelle avant d'installer MongoDB. Il vérifie :

- le système d'exploitation (Ubuntu 24.04) ;
- le processeur (architecture et jeu d'instructions AVX) ;
- la mémoire et l'espace disque disponibles ;
- le noyau Linux en cours d'exécution, les noyaux installés et la présence de la pile noyau HWE.

Il **ne modifie rien** : il affiche une ligne `[OK]` ou `[KO]` par contrôle, puis un résultat global. Comme il se contente de lire des informations, il n'a pas besoin de `sudo` :

```bash
bash ~/bd511/ch02/00-verif-plateforme.sh
```

Si un point est en `[KO]`, corrigez-le avant de passer à la suite. Pour le noyau, c'est l'objet de la partie 0.4 du guide et du script `01-noyau-ga.sh`.

---

## Explication instruction par instruction

### 1. En-tête du script

```bash
#!/usr/bin/env bash
```

C'est le **shebang** : il indique au système quel interpréteur doit exécuter le fichier. `/usr/bin/env bash` va chercher le programme `bash` dans le `PATH`. Quand on lance le script avec `bash fichier.sh`, cette ligne n'est pas utilisée ; elle sert si l'on rend le fichier exécutable (`chmod +x`) et qu'on le lance directement avec `./00-verif-plateforme.sh`.

```bash
# 00-verif-plateforme.sh - BD511 ch.2 : prérequis plate-forme pour MongoDB 8.3
# Usage : bash ~/bd511/ch02/00-verif-plateforme.sh
```

Des **commentaires** : tout ce qui suit un `#` est ignoré par bash. Ils rappellent le rôle du script et la commande pour le lancer.

```bash
set -u
```

Active une option de sécurité : si le script utilise une variable **non définie**, bash affiche une erreur et s'arrête, au lieu de la remplacer silencieusement par une chaîne vide. Cela protège contre les fautes de frappe dans les noms de variables.

> Le script n'utilise volontairement **pas** `set -e` (arrêt à la première commande en échec). Ici, un test qui échoue est un résultat normal : le script doit continuer pour afficher **tous** les contrôles.

### 2. Le compteur et les fonctions d'affichage

```bash
ko=0
```

Crée la variable `ko`, qui comptera le nombre de points en échec. En bash, on écrit `nom=valeur`, **sans espace** autour du `=`.

```bash
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }
```

Déclare deux **fonctions** (syntaxe `nom() { commandes; }`) :

- `ok` affiche `[OK]` suivi du message reçu ;
- `nok` affiche `[KO]` suivi du message, puis ajoute 1 au compteur `ko`.

Dans le détail :

- `"$*"` regroupe tous les arguments passés à la fonction en une seule chaîne de caractères ;
- `printf` affiche un texte formaté : `%s` est remplacé par la chaîne, `\n` est un retour à la ligne ;
- `$(( ... ))` effectue un calcul sur des entiers : `ko=$((ko + 1))` incrémente le compteur.

### 3. La fonction `noyau_compatible`

```bash
# Règle appliquée par mongod 8.3.x au démarrage : noyaux 6.19.0 à 7.0.13 refusés.
noyau_compatible() {
  [[ $1 =~ ^([0-9]+)\.([0-9]+)\.([0-9]+) ]] || return 0
  local v=$(( 10#${BASH_REMATCH[1]} * 1000000 + 10#${BASH_REMATCH[2]} * 1000 + 10#${BASH_REMATCH[3]} ))
  (( v < 6019000 || v > 7000013 ))
}
```

Cette fonction reçoit une version de noyau (par exemple `6.8.0-87-generic`) et répond « compatible » (code retour 0) ou « incompatible » (code retour 1).

**Pourquoi cette règle ?** Le noyau Linux 6.19 a modifié le fonctionnement des *restartable sequences* (rseq), un mécanisme du noyau dont se sert TCMalloc, l'allocateur mémoire intégré à `mongod`. Sur ces noyaux, l'allocateur peut corrompre la mémoire et faire planter le serveur. Les versions récentes de MongoDB refusent donc de démarrer sur ces noyaux. La plage retenue par le script (6.19.0 à 7.0.13) est celle que `mongod` 8.3.x vérifie au démarrage : le script la reproduit pour détecter le problème **avant** l'installation.

**Ligne 1**

- `$1` désigne le premier argument reçu par la fonction ;
- `[[ texte =~ regex ]]` teste si le texte correspond à une expression régulière ;
- `^([0-9]+)\.([0-9]+)\.([0-9]+)` signifie : au début de la chaîne (`^`), un nombre, un point, un nombre, un point, un nombre. Le `\.` désigne un point littéral. Chaque partie entre parenthèses est **capturée** dans le tableau `BASH_REMATCH` : pour `6.8.0-87-generic`, on obtient `BASH_REMATCH[1]=6`, `BASH_REMATCH[2]=8`, `BASH_REMATCH[3]=0` ;
- `|| return 0` : `||` signifie « sinon ». Si la version n'a pas ce format, la fonction répond « compatible » pour ne pas bloquer sur une version illisible.

**Ligne 2**

- `local v` crée une variable visible uniquement à l'intérieur de la fonction ;
- `10#` force la lecture du nombre en base 10. Sans cela, un nombre commençant par `0` (comme `08`) serait lu en octal et provoquerait une erreur ;
- le calcul transforme la version en un seul entier facile à comparer : majeur × 1 000 000 + mineur × 1 000 + correctif.

| Version | Entier calculé | Résultat |
|---|---|---|
| 6.8.0 | 6 008 000 | compatible |
| 6.17.0 | 6 017 000 | compatible |
| 6.19.0 | 6 019 000 | **refusé** |
| 7.0.13 | 7 000 013 | **refusé** |
| 7.0.14 | 7 000 014 | compatible |

**Ligne 3**

`(( condition ))` renvoie « vrai » (code 0) si la condition arithmétique est remplie ; `||` veut dire « ou ». Une fonction renvoie le code de sa dernière commande : la fonction répond donc « compatible » si la version est **antérieure à 6.19.0 ou postérieure à 7.0.13**.

### 4. Contrôles du système

```bash
echo "== Système"
```

Affiche un titre de section.

```bash
. /etc/os-release
```

Le `.` (équivalent de la commande `source`) exécute un fichier **dans le shell courant**. Le fichier `/etc/os-release` contient des affectations comme `ID=ubuntu`, `VERSION_ID="24.04"` ou `PRETTY_NAME="Ubuntu 24.04.3 LTS"`. Après cette ligne, ces informations sont disponibles comme variables dans le script.

```bash
if [[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 24.04 ]]; then
  ok "$PRETTY_NAME"
else
  nok "Ubuntu 24.04 attendu (trouvé : ${PRETTY_NAME:-inconnu})"
fi
```

- `if ... then ... else ... fi` : structure conditionnelle ;
- `[[ A == B && C == D ]]` : vrai si les **deux** comparaisons sont vraies (`&&` = « et ») ;
- `${ID:-}` donne la valeur de `ID`, ou une chaîne vide si la variable n'existe pas. C'est indispensable avec `set -u`, qui sinon arrêterait le script ;
- `${PRETTY_NAME:-inconnu}` donne la valeur de `PRETTY_NAME`, ou le texte `inconnu` à défaut.

```bash
case $(uname -m) in
  x86_64)
    if grep -qw avx /proc/cpuinfo; then ok "Processeur x86_64 avec AVX"
    else nok "Processeur x86_64 SANS AVX : mongod ne pourra pas démarrer (voir annexe A)"; fi ;;
  aarch64)
    ok "Processeur aarch64 (ARMv8.2-A minimum ; Compass n'existe pas pour Linux ARM64)" ;;
  *)
    nok "Architecture non supportée : $(uname -m)" ;;
esac
```

- `$(commande)` est une **substitution de commande** : elle est remplacée par ce que la commande affiche ;
- `uname -m` affiche l'architecture du processeur : `x86_64` (Intel/AMD 64 bits) ou `aarch64` (ARM 64 bits) ;
- `case valeur in motif) commandes ;; esac` exécute le bloc dont le motif correspond à la valeur. `;;` termine chaque bloc et `*)` attrape tous les autres cas.

Cas par cas :

- **x86_64** : le fichier `/proc/cpuinfo` liste les capacités (*flags*) du processeur. `grep -qw avx` y cherche le mot `avx` : `-q` (*quiet*) n'affiche rien et renvoie seulement vrai/faux, `-w` exige le mot entier (pour ne pas confondre avec `avx2` ou `avx512f`). Depuis la version 5.0, les binaires MongoDB pour x86_64 exigent AVX. Dans une VM, AVX peut être masqué si l'hyperviseur présente au système invité un modèle de processeur générique : c'est le sujet de l'annexe A ;
- **aarch64** : accepté, avec deux rappels : il faut un processeur ARMv8.2-A au minimum, et le client graphique Compass n'existe pas en version Linux ARM64 ;
- **autre architecture** : non supportée.

```bash
mem_mo=$(awk '/^MemTotal/ {printf "%d", $2 / 1024}' /proc/meminfo)
```

- `/proc/meminfo` décrit la mémoire de la machine. Sa ligne `MemTotal:  4013204 kB` donne la mémoire totale en kilo-octets ;
- `awk '/^MemTotal/ {...}'` traite uniquement la ligne qui commence par `MemTotal` ;
- `$2` est le 2ᵉ champ de la ligne (la valeur) ; divisé par 1024, on obtient des mégaoctets ;
- `printf "%d"` affiche un entier ;
- le résultat est rangé dans `mem_mo`.

```bash
if (( mem_mo >= 3500 )); then ok "Mémoire : ${mem_mo} Mo"; else nok "Mémoire : ${mem_mo} Mo (4 Go recommandés)"; fi
```

Le seuil est de 3 500 Mo et non de 4 096 : une VM dotée de 4 Go affiche un peu moins, car le noyau se réserve une partie de la mémoire au démarrage.

```bash
libre_go=$(df --output=avail -BG /var/lib | tail -n 1 | tr -dc '0-9')
```

Une chaîne de commandes reliées par des **tubes** (`|`) : la sortie de chacune devient l'entrée de la suivante.

- `df` affiche l'espace disque du système de fichiers qui contient `/var/lib` ; `--output=avail` ne garde que la colonne « espace disponible » et `-BG` l'exprime en gigaoctets (par exemple `25G`) ;
- `tail -n 1` ne garde que la dernière ligne (la première est un en-tête) ;
- `tr -dc '0-9'` supprime (`-d`) tous les caractères qui ne sont **pas** (`-c`, complément) des chiffres : `25G` devient `25`.

`/var/lib` est contrôlé parce que c'est là que seront stockés les fichiers de données (`/var/lib/mongodb`) et le volume XFS créé par `02-volume-xfs.sh`.

```bash
if (( libre_go >= 12 )); then ok "Espace libre sous /var/lib : ${libre_go} Go"
else nok "Espace libre sous /var/lib : ${libre_go} Go (12 Go recommandés)"; fi
```

Compare l'espace libre au minimum recommandé de 12 Go.

### 5. Contrôles du noyau

```bash
echo "== Noyau"
courant=$(uname -r)
```

`uname -r` affiche la version du noyau **en cours d'exécution** (par exemple `6.8.0-87-generic`).

```bash
if noyau_compatible "$courant"; then ok "Noyau en cours d'exécution : $courant"
else nok "Noyau en cours d'exécution : $courant (incompatible avec MongoDB 8.3.13)"; fi
```

Une fonction peut servir directement de condition dans un `if` : c'est son code retour qui décide de la branche exécutée.

```bash
for image in /boot/vmlinuz-*; do
  [[ -e $image ]] || continue
  version=${image#/boot/vmlinuz-}
  noyau_compatible "$version" || nok "Noyau installé incompatible : $version"
done
```

Vérifie **tous les noyaux installés**, pas seulement celui qui tourne. Chaque noyau installé possède un fichier `/boot/vmlinuz-<version>`. C'est important, car GRUB démarre par défaut le noyau le plus récent : un noyau incompatible installé serait utilisé au prochain redémarrage.

- `for image in /boot/vmlinuz-*; do ... done` : boucle sur chaque fichier correspondant au motif ;
- `[[ -e $image ]] || continue` : si aucun fichier ne correspond, bash laisse le motif tel quel ; `-e` teste l'existence du fichier et `continue` passe à l'itération suivante ;
- `${image#/boot/vmlinuz-}` retire le préfixe `/boot/vmlinuz-` pour ne garder que la version ;
- `noyau_compatible ... || nok ...` : on n'appelle `nok` que si le noyau est incompatible.

```bash
if dpkg-query -W -f='${db:Status-Abbrev}\n' 'linux-*-hwe-24.04' 2>/dev/null | grep -q '^ii'; then
  nok "Pile noyau HWE installée : elle installera des noyaux 6.19 ou plus récents"
fi
```

- `dpkg-query -W` liste les paquets dont le nom correspond au motif `linux-*-hwe-24.04` (par exemple `linux-generic-hwe-24.04`) ;
- `-f='${db:Status-Abbrev}\n'` n'affiche que l'état abrégé de chaque paquet. `ii` signifie « paquet demandé et installé ». Les apostrophes empêchent bash d'interpréter `${...}` : c'est `dpkg-query` qui le lit ;
- `2>/dev/null` jette les messages d'erreur (cas où aucun paquet ne correspond). `2>` redirige la sortie d'erreur et `/dev/null` est un « trou noir » ;
- `grep -q '^ii'` réussit si au moins une ligne commence par `ii`.

> **Noyau GA ou pile HWE ?** Ubuntu 24.04 propose deux familles de noyaux. Le noyau **GA** (*General Availability*) est celui de la version : la série 6.8, maintenue pendant toute la vie d'Ubuntu 24.04. La pile **HWE** (*Hardware Enablement*) fait suivre à la 24.04 les noyaux des versions d'Ubuntu plus récentes, pour prendre en charge du matériel récent. Avec la pile HWE, une simple mise à jour (`apt upgrade`) peut installer un noyau de la plage refusée par MongoDB. Le TP repasse donc sur le noyau GA avec `01-noyau-ga.sh`.

### 6. Résultat global

```bash
echo
if (( ko == 0 )); then
  echo "Résultat : plate-forme conforme, passez à la partie 1."
else
  echo "Résultat : ${ko} point(s) à corriger (voir la partie 0.4 pour le noyau)."
fi
```

`echo` seul affiche une ligne vide. Le script affiche ensuite un message selon la valeur du compteur `ko`.

```bash
exit $(( ko > 0 ))
```

Termine le script avec un **code retour** : `$(( ko > 0 ))` vaut `1` s'il y a au moins un échec, `0` sinon. Par convention, 0 signifie « succès ». Ce code permet d'enchaîner des commandes, par exemple `bash 00-verif-plateforme.sh && echo "On peut continuer"`. Vous pouvez aussi l'afficher juste après l'exécution avec `echo $?`.

---

## Exemple de sortie

Sur une VM qui utilise encore la pile HWE (les valeurs dépendent de votre machine) :

```text
== Système
  [OK] Ubuntu 24.04.3 LTS
  [OK] Processeur x86_64 avec AVX
  [OK] Mémoire : 3915 Mo
  [OK] Espace libre sous /var/lib : 24 Go
== Noyau
  [KO] Noyau en cours d'exécution : 7.0.0-15-generic (incompatible avec MongoDB 8.3.13)
  [KO] Noyau installé incompatible : 7.0.0-15-generic
  [KO] Pile noyau HWE installée : elle installera des noyaux 6.19 ou plus récents

Résultat : 3 point(s) à corriger (voir la partie 0.4 pour le noyau).
```

Après le passage au noyau GA et le redémarrage, relancez le script : toutes les lignes doivent être en `[OK]`.
