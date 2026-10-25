# BD511 – Chapitre 8 – Handlab : diagnostic de charge, requêtes lentes et supervision avec Prometheus et Grafana

| | |
| --- | --- |
| **Formation** | BD511 – NoSQL MongoDB : mise en œuvre et administration |
| **Chapitre** | 8 – Supervision et performances |
| **Durée indicative** | 2 h 45 |
| **Environnement** | VM Ubuntu 24.04 LTS Desktop des chapitres précédents : instance `mongod` du chapitre 2 (service systemd, `/etc/mongod.conf`), mongosh et Database Tools, Docker Engine du chapitre 6, navigateur Firefox ; 1,5 Go de mémoire disponible, 3 Go libres sur `/` |
| **Versions vérifiées le 25/10/2026** | MongoDB Community Server **8.3.13** · mongosh **2.13.0** · Database Tools **100.19.1** · exporteur `percona/mongodb_exporter:0.54.0` · Prometheus **3.15.1** · Grafana OSS **13.2.4** · Docker Engine **29.9.2** · Docker Compose **5.6.1** |

## Objectifs du TP

À l'issue de ce TP, vous saurez :

1. **diagnostiquer une base fortement sollicitée** avec les outils du système et de MongoDB : `top`, `mongostat`, `mongotop`, `serverStatus`, `$currentOp`, et interrompre une opération avec `killOp` ;
2. **repérer une requête lente** avec `mongostat`, le **profiler** et le **journal JSON** de `mongod`, puis la **corriger** par un index et mesurer le gain ;
3. appliquer les **réglages de production** correspondants : seuil des opérations lentes, profiler désactivé, rotation du journal par `logrotate` ;
4. déployer avec Docker Compose la chaîne **exporteur → Prometheus → Grafana** (compte dédié `clusterMonitor`, règles d'alerte, tableau de bord provisionné) et **suivre la charge** d'une application sur le tableau de bord, jusqu'au déclenchement d'une alerte.

## Le scénario

Une boutique en ligne enregistre ses ventes dans la collection `bd511.ventes` de l'instance du chapitre 2 : un million de ventes, passées par 50 000 clients. L'application sollicite cette collection en continu :

- 60 % de ses opérations affichent la **fiche d'un client** : ses 10 dernières ventes ;
- 25 % enregistrent une **nouvelle vente** ;
- 15 % **mettent à jour** le statut d'une vente.

Depuis la mise en production, le serveur sature et les pages des fiches clients mettent près d'une seconde à s'afficher. Pour ne rien arranger, un analyste lance un rapport qui ne se termine jamais. Votre mission : poser le diagnostic, trouver la requête fautive, la corriger, puis installer une supervision qui aurait détecté le problème, et le détectera s'il revient.

## Organisation des fichiers

Les fichiers du chapitre sont rangés dans le répertoire du projet, `~/BD511` :

| Répertoire | Contenu |
| --- | --- |
| `~/BD511/ch08` | scripts du TP, jeu de données (`donnees/`), mots de passe des comptes (`secrets/`, mode 700), journaux de la charge simulée (`charge/`) |
| `~/BD511/supervision` | projet Docker Compose de la supervision : exporteur, Prometheus, Grafana |

```text
                                        VM Ubuntu (réseau de la VM, 127.0.0.1 uniquement)
  ┌──────────────────────────────┐   ┌──────────────────────────┐   ┌──────────────────────┐   ┌──────────────────────┐
  │ application simulée          │   │ mongod (chapitre 2)      │   │ mongodb-exporter     │   │ Prometheus           │
  │ 3 clients mongosh            ├──►│ 127.0.0.1:27017, systemd ├◄──┤ :9216, compte         │◄──┤ :9090, collecte      │
  │ (compte charge)              │   │ base bd511, journal JSON │   │ exporteur            │   │ toutes les 15 s,     │
  └──────────────────────────────┘   └────────────▲─────────────┘   └──────────────────────┘   │ règles d'alerte      │
                                                  │                                            └──────────▲───────────┘
            mongostat, mongotop, mongosh ─────────┘ (compte diag)        Firefox ──► Grafana :3000 ───────┘
```

## Déroulé

| Partie | Contenu | Durée |
| --- | --- | --- |
| 0 | Prérequis, comptes du TP, jeu de données | 25 min |
| 1 | Diagnostic d'une base fortement sollicitée | 35 min |
| 2 | Requête lente : `mongostat`, profiler, journal, correction, réglages de production | 40 min |
| 3 | Chaîne exporteur → Prometheus → Grafana et suivi de la charge | 50 min |
| 4 | Bilan | 15 min |

## Conventions

- Les commandes s'exécutent dans un terminal (`Ctrl` + `Alt` + `T`) ; la partie 3 utilise aussi Firefox.
- Les blocs qui créent un fichier (`cat > fichier <<'EOF'`) se copient **en entier**, de la première ligne jusqu'à la ligne `EOF` incluse.
- Les blocs « Résultat attendu » montrent la sortie à obtenir. Les heures, durées, débits, pourcentages, tailles mémoire et identifiants varient d'une VM à l'autre et d'un instant à l'autre ; les ordres de grandeur, eux, doivent se retrouver.
- Le compte `diag` sert à l'exploitation, le compte `charge` à l'application, le compte `exporteur` à la supervision. Leurs mots de passe ne s'écrivent jamais en ligne de commande.

---

## Partie 0 – Préparer la VM

### 0.1 Créer l'espace de travail et contrôler les prérequis

Le cluster Docker du chapitre 7, s'il tourne encore, occupe plus de 2 Go de mémoire : arrêtez-le. La commande ne fait rien s'il n'existe pas.

```bash
[ -f ~/bd511/ch07/cluster.sh ] && bash ~/bd511/ch07/cluster.sh arreter
mkdir -p ~/BD511/ch08/donnees ~/BD511/supervision
```

Le script suivant contrôle l'instance du chapitre 2, les outils, Docker, la mémoire, l'espace disque et les ports dont la supervision aura besoin :

```bash
cat > ~/BD511/ch08/00-prerequis.sh <<'EOF'
#!/usr/bin/env bash
# 00-prerequis.sh - BD511 ch.8 : vérifie la VM avant le TP de supervision
# (instance mongod du chapitre 2, outils clients, Docker du chapitre 6, mémoire, disque et ports libres)
# Usage : bash ~/BD511/ch08/00-prerequis.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
ko=0
ok()  { printf '  [OK] %s\n' "$*"; }
nok() { printf '  [KO] %s\n' "$*"; ko=$((ko + 1)); }

echo "== Instance mongod du chapitre 2"
if systemctl is-active --quiet mongod; then ok "Service mongod actif"; else nok "Service mongod arrêté : sudo systemctl start mongod"; fi
v=$(mongod --version 2>/dev/null | awk 'NR == 1 {print $3}')
if [[ $v == v8.3.* ]]; then ok "mongod $v"; else nok "mongod 8.3 attendu (trouvé : ${v:-aucun})"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=bd511-ch08-prerequis" --eval 'db.adminCommand({ ping: 1 }).ok' 2>/dev/null | grep -qx 1
then ok "mongod répond sur 127.0.0.1:27017"; else nok "mongod ne répond pas sur 127.0.0.1:27017"; fi
if mongosh --quiet "mongodb://127.0.0.1:27017/?appName=bd511-ch08-prerequis" --eval 'db.adminCommand({ listDatabases: 1 }).ok' >/dev/null 2>&1
then ok "Contrôle d'accès désactivé (chapitre 2) : comptes du TP créés sans authentification"
else ok "Contrôle d'accès activé (chapitre 5) : un compte administrateur sera demandé en partie 0.2"; fi
libre=$(df -BM --output=avail /var/lib/mongodb | tail -n 1 | tr -dc '0-9')
if (( libre >= 1024 )); then ok "Espace libre pour les données (/var/lib/mongodb) : ${libre} Mo (1 024 Mo requis)"
else nok "Espace libre pour les données (/var/lib/mongodb) : ${libre} Mo (1 024 Mo requis)"; fi

echo "== Outils"
for outil in mongosh mongoimport mongostat mongotop jq python3 logrotate; do
  if command -v "$outil" >/dev/null; then ok "$outil présent"; else nok "$outil absent"; fi
done
if sudo docker info >/dev/null 2>&1; then
  ok "Docker Engine $(sudo docker version --format '{{.Server.Version}}'), Compose $(sudo docker compose version --short)"
else nok "Docker inactif ou absent (chapitre 6, partie 1)"; fi

echo "== Ressources de la VM"
dispo=$(awk '/^MemAvailable/ {print int($2 / 1024)}' /proc/meminfo)
if (( dispo >= 1536 )); then ok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis)"
else nok "Mémoire disponible : ${dispo} Mo (1 536 Mo requis) ; arrêtez le cluster du chapitre 7 (annexe A)"; fi
libre=$(df -BG --output=avail / | tail -n 1 | tr -dc '0-9')
if (( libre >= 3 )); then ok "Espace libre sur / : ${libre} Go (3 Go requis pour les images Docker)"
else nok "Espace libre sur / : ${libre} Go (3 Go requis pour les images Docker)"; fi
for port in 9216 9090 3000; do
  if ss -Hltn "sport = :$port" | grep -q .; then nok "Port $port déjà utilisé"; else ok "Port $port libre"; fi
done

echo
if (( ko == 0 )); then echo "Résultat : VM prête pour le TP."; else echo "Résultat : ${ko} point(s) à corriger."; fi
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch08/00-prerequis.sh
```

Résultat attendu (valeurs variables ; la ligne sur le contrôle d'accès dépend du chapitre 5) :

```text
== Instance mongod du chapitre 2
  [OK] Service mongod actif
  [OK] mongod v8.3.13
  [OK] mongod répond sur 127.0.0.1:27017
  [OK] Contrôle d'accès désactivé (chapitre 2) : comptes du TP créés sans authentification
  [OK] Espace libre pour les données (/var/lib/mongodb) : 7420 Mo (1 024 Mo requis)
== Outils
  [OK] mongosh présent
  [OK] mongoimport présent
  [OK] mongostat présent
  [OK] mongotop présent
  [OK] jq présent
  [OK] python3 présent
  [OK] logrotate présent
  [OK] Docker Engine 29.9.2, Compose 5.6.1
== Ressources de la VM
  [OK] Mémoire disponible : 3912 Mo (1 536 Mo requis)
  [OK] Espace libre sur / : 9 Go (3 Go requis pour les images Docker)
  [OK] Port 9216 libre
  [OK] Port 9090 libre
  [OK] Port 3000 libre

Résultat : VM prête pour le TP.
```

### 0.2 Créer les comptes du TP

Trois comptes sont créés dans la base `admin`, chacun avec le minimum de droits pour son usage :

| Compte | Rôles | Usage |
| --- | --- | --- |
| `diag` | `clusterMonitor`, `hostManager`, `dbAdminAnyDatabase`, `readAnyDatabase` | exploitation : métriques, opérations en cours et `killOp`, profiler, index |
| `charge` | `readWrite` sur `bd511` | application simulée, import du jeu de données |
| `exporteur` | `clusterMonitor`, `read` sur `local` | collecte des métriques par l'exporteur (rôles recommandés par Percona) |

Le script génère les mots de passe dans `~/BD511/ch08/secrets` et s'adapte à l'état de l'instance : si le contrôle d'accès a été activé au chapitre 5, il vous demande un compte administrateur existant (rôle `root` ou `userAdminAnyDatabase`) et son mot de passe, qui transitent par l'entrée standard de mongosh, jamais par sa ligne de commande.

```bash
cat > ~/BD511/ch08/comptes.sh <<'EOF'
#!/usr/bin/env bash
# comptes.sh - BD511 ch.8 : crée ou met à jour les trois comptes du TP sur l'instance mongod du chapitre 2
#   diag      : exploitation (diagnostic, opérations en cours, profiler, index)
#   charge    : application simulée (lecture et écriture dans la base bd511)
#   exporteur : collecte des métriques pour Prometheus (clusterMonitor et lecture de la base local)
# Les mots de passe sont générés dans ~/BD511/ch08/secrets (mode 600) et ne passent jamais en ligne de commande.
# Le script s'adapte au contrôle d'accès de l'instance : désactivé (configuration du chapitre 2) ou activé
# (chapitre 5) ; dans ce cas, il demande un compte administrateur existant (rôle root ou userAdminAnyDatabase).
# Usage : bash ~/BD511/ch08/comptes.sh
set -euo pipefail
SECRETS="$HOME/BD511/ch08/secrets"
URI="mongodb://127.0.0.1:27017/admin?appName=bd511-ch08-comptes"

mkdir -p "$SECRETS" && chmod 700 "$SECRETS"
for compte in diag charge exporteur; do
  if [[ ! -s $SECRETS/$compte.pwd ]]; then
    ( umask 077; openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 24 > "$SECRETS/$compte.pwd" )
  fi
done
# Fichiers de configuration des Database Tools (option --config de mongostat, mongotop, mongoimport)
for compte in diag charge; do
  ( umask 077; printf 'password: "%s"\n' "$(< "$SECRETS/$compte.pwd")" > "$SECRETS/$compte.yaml" )
done

if ! mongosh --quiet "$URI" --eval 'db.adminCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
  echo "mongod ne répond pas sur 127.0.0.1:27017 : sudo systemctl start mongod" >&2; exit 1
fi
if mongosh --quiet "$URI" --eval 'db.adminCommand({ listDatabases: 1 }).ok' >/dev/null 2>&1; then
  echo "Contrôle d'accès : désactivé (configuration du chapitre 2)"
  connexion=""
else
  echo "Contrôle d'accès : activé (chapitre 5)"
  read -r -p "Compte administrateur existant [admin] : " adm
  read -r -s -p "Mot de passe de ${adm:=admin} : " mdp; echo
  # Nom et mot de passe convertis en chaînes JSON, transmis à mongosh par l'entrée standard
  connexion="db.getSiblingDB('admin').auth($(printf '%s' "$adm" | jq -Rs .), $(printf '%s' "$mdp" | jq -Rs .));"
fi

mongosh --quiet "$URI" --file /dev/stdin <<FIN
$connexion
const admin = db.getSiblingDB("admin");
const comptes = {
  diag:      { roles: ["clusterMonitor", "hostManager", "dbAdminAnyDatabase", "readAnyDatabase"], mdp: "$(< "$SECRETS/diag.pwd")" },
  charge:    { roles: [{ role: "readWrite", db: "bd511" }], mdp: "$(< "$SECRETS/charge.pwd")" },
  exporteur: { roles: ["clusterMonitor", { role: "read", db: "local" }], mdp: "$(< "$SECRETS/exporteur.pwd")" },
};
for (const [nom, c] of Object.entries(comptes)) {
  if (admin.getUser(nom)) admin.updateUser(nom, { pwd: c.mdp, roles: c.roles });
  else admin.createUser({ user: nom, pwd: c.mdp, roles: c.roles });
}
for (const u of admin.getUsers({ filter: { user: { \$in: Object.keys(comptes) } } }).users.sort((a, b) => a.user.localeCompare(b.user)))
  print(u.user.padEnd(10), u.roles.map(r => r.role + "@" + r.db).sort().join(", "));
FIN
EOF
bash ~/BD511/ch08/comptes.sh
```

Résultat attendu, si le contrôle d'accès est désactivé (configuration du chapitre 2) :

```text
Contrôle d'accès : désactivé (configuration du chapitre 2)
charge     readWrite@bd511
diag       clusterMonitor@admin, dbAdminAnyDatabase@admin, hostManager@admin, readAnyDatabase@admin
exporteur  clusterMonitor@admin, read@local
```

Si le contrôle d'accès est activé, le script pose deux questions (le mot de passe ne s'affiche pas) :

```text
Contrôle d'accès : activé (chapitre 5)
Compte administrateur existant [admin] : admin
Mot de passe de admin :
charge     readWrite@bd511
diag       clusterMonitor@admin, dbAdminAnyDatabase@admin, hostManager@admin, readAnyDatabase@admin
exporteur  clusterMonitor@admin, read@local
```

> **Sans contrôle d'accès**, ces comptes fonctionnent (MongoDB vérifie toujours le mot de passe des clients qui s'authentifient), mais n'importe quel client local pourrait se passer d'eux. En production, l'authentification est toujours activée (chapitre 5).

### 0.3 Se connecter avec un compte du TP

Le script suivant ouvre mongosh sur la base `bd511` avec le compte `diag` (par défaut) ou un autre compte du TP. Le nom d'application transmis au serveur (`bd511-ch08-<compte>`) permettra de reconnaître chaque client dans les opérations en cours et dans le journal.

```bash
cat > ~/BD511/ch08/mongosh-bd511 <<'EOF'
#!/usr/bin/env bash
# mongosh-bd511 - BD511 ch.8 : ouvre mongosh sur l'instance mongod du chapitre 2 (127.0.0.1:27017), base bd511
# Le mot de passe est lu dans ~/BD511/ch08/secrets/<compte>.pwd ; mongosh le masque ensuite dans la
# liste des processus (« mongodb://<credentials>@... »). Compte par défaut : diag.
# Nom d'application (visible dans les opérations en cours et les journaux) : bd511-ch08-<compte>, ou $APPNAME.
# Usage : ~/BD511/ch08/mongosh-bd511 [--compte charge] [options et scripts mongosh...]
set -euo pipefail
compte=diag
if [[ ${1:-} == --compte ]]; then compte=$2; shift 2; fi
mdp=$(< "$HOME/BD511/ch08/secrets/$compte.pwd")
exec mongosh "mongodb://$compte:$mdp@127.0.0.1:27017/bd511?authSource=admin&appName=${APPNAME:-bd511-ch08-$compte}" "$@"
EOF
chmod +x ~/BD511/ch08/mongosh-bd511
~/BD511/ch08/mongosh-bd511 --quiet --eval 'print(db.getName(), "-", db.runCommand({ connectionStatus: 1 }).authInfo.authenticatedUsers[0].user)'
```

Résultat attendu :

```text
bd511 - diag
```

### 0.4 Générer et importer le jeu de données

Le générateur est **déterministe** : il produit toujours exactement le même fichier, dont l'empreinte SHA-256 est connue. Le même fichier, compressé, est fourni dans l'archive du TP (`donnees/ventes.json.gz`).

```bash
cat > ~/BD511/ch08/generer_ventes.py <<'EOF'
#!/usr/bin/env python3
"""generer_ventes.py - BD511 ch.8 : génère le jeu de données des ventes, au format JSON (un document par ligne).

Le générateur est déterministe (graine fixe) : il produit toujours exactement le même fichier,
dont la somme de contrôle figure dans donnees/SHA256SUMS.
Usage : python3 ~/BD511/ch08/generer_ventes.py > ~/BD511/ch08/donnees/ventes.json
"""
import json
import random
import sys
from datetime import datetime, timedelta, timezone

NB_VENTES = 1_000_000
NB_CLIENTS = 50_000
PAYS = {"EU": ["FR", "DE", "ES", "IT", "BE", "NL"], "AM": ["US", "CA", "BR", "MX"]}
CANAUX = [("web", 0.55), ("magasin", 0.35), ("telephone", 0.10)]
STATUTS = [("livree", 0.86), ("expediee", 0.06), ("payee", 0.05), ("annulee", 0.03)]
DEBUT = datetime(2024, 1, 1, tzinfo=timezone.utc)
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

# Les ventes sont numérotées dans l'ordre chronologique, du 01/01/2024 au 30/09/2026.
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
        "statut": tirer(STATUTS),
        "articles": articles,
        "montant": round(articles * (5 + alea.random() * 95), 2),
    }
    sortie.write(json.dumps(vente, separators=(",", ":")) + "\n")
EOF
cat > ~/BD511/ch08/donnees/SHA256SUMS <<'EOF'
0a852390ef02dfbd76f48033f3a6af065f5778806a162ebf98d397574a70e455  ventes.json
EOF
python3 ~/BD511/ch08/generer_ventes.py > ~/BD511/ch08/donnees/ventes.json
cd ~/BD511/ch08/donnees && sha256sum -c SHA256SUMS && wc -l ventes.json
```

Résultat attendu (en une quinzaine de secondes) :

```text
ventes.json: Réussi
1000000 ventes.json
```

Importez les ventes avec le compte `charge`. Le mot de passe passe par un fichier de configuration (`--config`), comme pour tous les outils de la suite Database Tools :

```bash
cat > ~/BD511/ch08/importer-ventes.sh <<'EOF'
#!/usr/bin/env bash
# importer-ventes.sh - BD511 ch.8 : (ré)importe le million de ventes dans bd511.ventes, avec le compte « charge »
# La collection est recréée à chaque import (--drop) : elle ne porte alors que l'index obligatoire sur _id.
# Le mot de passe passe par le fichier de configuration ~/BD511/ch08/secrets/charge.yaml (option --config).
# Usage : bash ~/BD511/ch08/importer-ventes.sh
set -euo pipefail
CH08="$HOME/BD511/ch08"
cd "$CH08/donnees"
sha256sum --quiet --check SHA256SUMS || { echo "ventes.json différent de la référence (partie 0.4)." >&2; exit 1; }
debut=$SECONDS
mongoimport --uri "mongodb://charge@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-import" \
  --config "$CH08/secrets/charge.yaml" --db bd511 --collection ventes --drop --file ventes.json \
  --numInsertionWorkers 2 --quiet
"$CH08/mongosh-bd511" --compte charge --quiet --eval '
  print(`bd511.ventes : ${db.ventes.countDocuments()} documents, index : ${db.ventes.getIndexes().map(i => i.name).join(", ")}`)'
echo "Import terminé en $((SECONDS - debut)) s"
EOF
bash ~/BD511/ch08/importer-ventes.sh
```

Résultat attendu (durée variable, une demi-minute environ) :

```text
bd511.ventes : 1000000 documents, index : _id_
Import terminé en 26 s
```

La collection ne porte que l'index obligatoire sur `_id`. C'est l'état dans lequel l'application a été mise en production.

---

## Partie 1 – Diagnostiquer une base fortement sollicitée

### 1.1 Démarrer l'application

L'application est simulée par trois clients mongosh, qui tournent en arrière-plan avec le compte `charge`. Chaque client vise 10 opérations par seconde et écrit un bilan toutes les 10 secondes dans `~/BD511/ch08/charge/client<N>.log`.

```bash
cat > ~/BD511/ch08/client-charge.js <<'EOF'
// client-charge.js - BD511 ch.8 : un client de l'application de vente en ligne, qui sollicite la collection bd511.ventes
// À chaque opération, tirage au hasard :
//   60 % « fiche client »  : les 10 dernières ventes d'un client (find sur client, tri par date décroissante)
//   25 % « nouvelle vente » : insertion d'une vente
//   15 % « mise à jour »    : changement du statut d'une vente, retrouvée par son numéro (_id)
// Le client vise RYTHME opérations par seconde (10 par défaut) et s'arrête au bout de DUREE secondes (3600 par défaut).
// Toutes les 10 s, il écrit une ligne de bilan : nombre d'opérations et durée moyenne par type.
// Usage : lancé par charge.sh (RYTHME=10 DUREE=3600 ~/BD511/ch08/mongosh-bd511 --compte charge --quiet client-charge.js)
const ventes = db.getSiblingDB("bd511").ventes;
const rythme = Number(process.env.RYTHME || 10), duree = Number(process.env.DUREE || 3600);
const intervalle = 1000 / rythme, fin = Date.now() + duree * 1000;
const heure = () => new Date().toTimeString().slice(0, 8);
const hasard = n => Math.floor(Math.random() * n);
const client = () => "C" + String(1 + hasard(50000)).padStart(5, "0");
const operations = {
  "fiches client": () => ventes.find({ client: client() }).sort({ date: -1 }).limit(10).toArray(),
  "nouvelles ventes": () => ventes.insertOne({ date: new Date(), client: client(), region: "EU", pays: "FR", canal: "web",
                                              statut: "payee", articles: 1 + hasard(8), montant: 5 + hasard(9500) / 10 }),
  "mises à jour": () => ventes.updateOne({ _id: 1 + hasard(1000000) }, { $set: { statut: "livree" }, $currentDate: { maj: true } }),
};
const choisir = () => { const x = Math.random(); return x < 0.60 ? "fiches client" : x < 0.85 ? "nouvelles ventes" : "mises à jour"; };

let bilan = {}, prochainBilan = Date.now() + 10000;
print(`${heure()}  début : ${rythme} opérations/s visées pendant ${duree} s`);
while (Date.now() < fin) {
  const nom = choisir(), t0 = Date.now();
  try { operations[nom](); } catch (e) { print(`${heure()}  erreur (${nom}) : ${e.message}`); sleep(1000); }
  const ms = Date.now() - t0;
  bilan[nom] ??= { n: 0, ms: 0 };
  bilan[nom].n++; bilan[nom].ms += ms;
  if (Date.now() >= prochainBilan) {
    print(`${heure()}  ` + Object.entries(bilan).sort().map(([k, v]) => `${k} ${v.n} (moy. ${Math.round(v.ms / v.n)} ms)`).join(" ; "));
    bilan = {}; prochainBilan += 10000;
  }
  sleep(Math.max(0, intervalle - ms));
}
print(`${heure()}  fin`);
EOF
cat > ~/BD511/ch08/charge.sh <<'EOF'
#!/usr/bin/env bash
# charge.sh - BD511 ch.8 : démarre, arrête ou affiche la charge applicative simulée sur bd511.ventes
#   demarrer [N] : lance N clients (3 par défaut) en arrière-plan, compte « charge », journaux dans ~/BD511/ch08/charge
#   etat         : dernière ligne de bilan de chaque client
#   arreter      : arrête tous les clients
# Usage : bash ~/BD511/ch08/charge.sh demarrer|etat|arreter [N]
set -euo pipefail
CH08="$HOME/BD511/ch08"
DOSSIER="$CH08/charge"
mkdir -p "$DOSSIER"

case ${1:-} in
  demarrer)
    if [[ -s $DOSSIER/pids ]]; then echo "Charge déjà démarrée : bash $0 arreter" >&2; exit 1; fi
    for i in $(seq 1 "${2:-3}"); do
      RYTHME=${RYTHME:-10} DUREE=${DUREE:-3600} nohup "$CH08/mongosh-bd511" --compte charge --quiet "$CH08/client-charge.js" \
        > "$DOSSIER/client$i.log" 2>&1 &
      echo $! >> "$DOSSIER/pids"
    done
    sleep 2
    echo "$(wc -l < "$DOSSIER/pids") clients démarrés (journaux : ~/BD511/ch08/charge/client*.log)" ;;
  etat)
    for f in "$DOSSIER"/client*.log; do [[ -e $f ]] && echo "$(basename "$f" .log) : $(tail -n 1 "$f")"; done ;;
  arreter)
    if [[ -s $DOSSIER/pids ]]; then
      xargs kill < "$DOSSIER/pids" 2>/dev/null || true
      rm -f "$DOSSIER/pids"
      echo "Clients arrêtés"
    else echo "Aucun client en cours"; fi ;;
  *) echo "Usage : $0 demarrer|etat|arreter [N]" >&2; exit 1 ;;
esac
EOF
bash ~/BD511/ch08/charge.sh demarrer
sleep 30
bash ~/BD511/ch08/charge.sh etat
```

Résultat attendu (valeurs variables) :

```text
3 clients démarrés (journaux : /home/stagiaire/BD511/ch08/charge/client*.log)
client1 : 14:20:41  fiches client 17 (moy. 534 ms) ; mises à jour 4 (moy. 9 ms) ; nouvelles ventes 6 (moy. 8 ms)
client2 : 14:20:41  fiches client 18 (moy. 521 ms) ; mises à jour 3 (moy. 11 ms) ; nouvelles ventes 7 (moy. 9 ms)
client3 : 14:20:42  fiches client 16 (moy. 548 ms) ; mises à jour 5 (moy. 10 ms) ; nouvelles ventes 8 (moy. 8 ms)
```

Chaque client visait 100 opérations en 10 secondes : il n'en réalise qu'une trentaine. Une fiche client prend plus d'une demi-seconde, alors qu'une insertion ou une mise à jour prend quelques millisecondes.

### 1.2 Vue du système

Commencez toujours par le système : quel processus consomme les ressources ? `top` fait ici deux relevés à 5 secondes d'intervalle ; on n'affiche que le second, mesuré sur ces 5 secondes (le premier relevé de `top` n'est pas significatif).

```bash
nproc
top -b -n 2 -d 5 -o %CPU | awk '/^top -/ { n++ } n == 2' | head -n 9
```

Résultat attendu (valeurs variables) :

```text
2
top - 14:21:03 up  1:12,  1 user,  load average: 2,61, 1,74, 0,98
Tâches: 251 total,   2 en cours, 249 en veille,   0 arrêté,   0 zombie
%Cpu(s): 93,8 ut,  4,7 sy,  0,0 ni,  1,6 id,  0,0 wa,  0,0 hi,  0,0 si,  0,0 st
MiB Mem :   5923,4 total,   1201,7 libr,   2287,0 util,   2753,8 tamp/cache
MiB Éch:   4096,0 total,   4096,0 libr,      0,0 util.   3636,4 dispo Mem

    PID UTIL.     PR  NI    VIRT    RES    SHR S  %CPU  %MEM    TEMPS+ COM.
   1153 mongodb   20   0 3854232 502144  60416 S 187,5   8,3  14:22.37 mongod
   9841 stagiai+  20   0   11,3g 108544  50176 S   6,2   1,8   0:03.51 mongosh m+
```

`mongod` occupe la quasi-totalité des processeurs de la VM (100 % de CPU par processeur occupé : près de 200 % sur une VM à 2 processeurs), et la charge moyenne (*load average*) dépasse le nombre de processeurs. La mémoire, elle, n'est pas en cause.

### 1.3 `mongostat` : l'activité du serveur, seconde par seconde

`mongostat` interroge `serverStatus` à intervalles réguliers et affiche une ligne par mesure. Lancez 5 mesures espacées de 2 secondes :

```bash
mongostat --uri "mongodb://diag@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-mongostat" \
  --config ~/BD511/ch08/secrets/diag.yaml -n 5 2
```

Résultat attendu (valeurs variables) :

```text
insert query update delete getmore command dirty used flushes vsize  res qrw arw net_in net_out conn                time
     2     5      1     *0       0     1|0  0.4% 6.0%       0 3.68G 491M 3|0 0|0  1.31k   82.9k   12 Oct 25 14:21:12.461
     3     5     *0     *0       0     0|0  0.4% 6.0%       0 3.68G 491M 3|0 0|0  1.30k   82.3k   12 Oct 25 14:21:14.454
     1     5      1     *0       0     2|0  0.4% 6.0%       0 3.68G 491M 2|0 0|0  1.33k   82.6k   12 Oct 25 14:21:16.452
     2     6      1     *0       0     0|0  0.4% 6.0%       0 3.68G 491M 3|0 0|0  1.44k   86.9k   12 Oct 25 14:21:18.459
     2     5     *0     *0       0     1|0  0.4% 6.0%       0 3.68G 491M 3|0 0|0  1.29k   81.7k   12 Oct 25 14:21:20.454
```

| Colonne | Signification | Lecture ici |
| --- | --- | --- |
| `insert`, `query`, `update`, `delete`, `getmore`, `command` | opérations par seconde (`*0` : aucune) | à peine 5 lectures par seconde : très peu pour un serveur saturé |
| `dirty`, `used` | part du cache WiredTiger modifiée, et occupée | cache presque vide : la mémoire n'est pas le problème |
| `vsize`, `res` | mémoire virtuelle et résidente de `mongod` | stable |
| `qrw`, `arw` | opérations en attente (*queued*) et actives, en lecture \| écriture | voir ci-dessous |
| `conn` | connexions ouvertes | stable |

> **`qrw` et `arw` avec MongoDB 8.3.** `mongostat` lit les « tickets » de concurrence de WiredTiger à un emplacement de `serverStatus` que les versions récentes de MongoDB ont abandonné (ils sont désormais dans `queues.execution`). Résultat : `arw` reste à `0|0`, et `qrw` additionne les opérations actives et en attente. Lisez donc `qrw` comme le nombre d'opérations en cours : ici, 3 lectures en permanence, une par client de l'application.

Peu d'opérations, mais un processeur saturé : chaque opération coûte très cher.

### 1.4 `mongotop` : où le serveur passe-t-il son temps ?

`mongotop` mesure le temps passé par le serveur sur chaque collection, en lecture et en écriture. Lancez un seul relevé sur 5 secondes :

```bash
mongotop --uri "mongodb://diag@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-mongotop" \
  --config ~/BD511/ch08/secrets/diag.yaml -n 1 5
```

Résultat attendu (valeurs variables ; la liste des espaces de noms à 0 ms varie) :

```text
2026-10-25T14:21:31.611+0100	connected to: mongodb://[**REDACTED**]@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-mongotop

                    ns      total       read    write    2026-10-25T14:21:36+01:00
          bd511.ventes    14829ms    14710ms    119ms
        admin.atlascli        0ms        0ms      0ms
    admin.system.users        0ms        0ms      0ms
config.system.sessions        0ms        0ms      0ms
   config.transactions        0ms        0ms      0ms
```

En 5 secondes, le serveur a passé près de 15 secondes de travail sur `bd511.ventes`, presque uniquement en lecture : les 3 clients y sont occupés en permanence. Le problème est donc une lecture sur cette collection.

### 1.5 `serverStatus` : les indicateurs qui expliquent

`mongostat` et `mongotop` décrivent les symptômes. Les compteurs de `serverStatus` donnent l'explication. Le script suivant les relève deux fois, à 10 secondes d'intervalle, et calcule les débits :

```bash
cat > ~/BD511/ch08/diagnostic.js <<'EOF'
// diagnostic.js - BD511 ch.8 : photographie de la charge de mongod, d'après deux appels à serverStatus
// espacés de INTERVALLE secondes (10 par défaut) : débits, efficacité des requêtes, concurrence, mémoire.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/diagnostic.js
const intervalle = Number(process.env.INTERVALLE || 10);
const n = v => Number(v ?? 0);
const fmt = (v, d = 0) => v.toLocaleString("fr-FR", { maximumFractionDigits: d, minimumFractionDigits: d });
const avant = db.serverStatus();
sleep(intervalle * 1000);
const apres = db.serverStatus();
const debit = chemin => (n(chemin(apres)) - n(chemin(avant))) / intervalle;

const lectures = debit(s => s.opcounters.query), commandes = debit(s => s.opcounters.command);
const insertions = debit(s => s.opcounters.insert), majs = debit(s => s.opcounters.update);
const examines = debit(s => s.metrics.queryExecutor.scannedObjects), cles = debit(s => s.metrics.queryExecutor.scanned);
const renvoyes = debit(s => s.metrics.document.returned), tris = debit(s => s.metrics.operation.scanAndOrder);
const latence = (type) => {
  const ops = n(apres.opLatencies[type].ops) - n(avant.opLatencies[type].ops);
  return ops ? (n(apres.opLatencies[type].latency) - n(avant.opLatencies[type].latency)) / ops / 1000 : 0;
};
const ga = apres.globalLock.activeClients, gq = apres.globalLock.currentQueue;
const tickets = apres.queues.execution.read.normalPriority ?? apres.queues.execution.read;
const cache = apres.wiredTiger.cache, Mo = v => n(v) / 1048576;
const utilise = Mo(cache["bytes currently in the cache"]), maxi = Mo(cache["maximum bytes configured"]);

print(`Diagnostic de ${apres.host} (MongoDB ${apres.version}) sur ${intervalle} s, à ${new Date().toTimeString().slice(0, 8)}`);
print(`  Opérations/s        : lectures ${fmt(lectures, 1)}, insertions ${fmt(insertions, 1)}, mises à jour ${fmt(majs, 1)}, commandes ${fmt(commandes, 1)}`);
print(`  Documents/s         : examinés ${fmt(examines)}, renvoyés ${fmt(renvoyes)}` +
      (renvoyes ? ` (${fmt(examines / renvoyes)} examinés par document renvoyé)` : ""));
print(`  Clés d'index/s      : ${fmt(cles)} ; tris en mémoire/s : ${fmt(tris, 1)}`);
print(`  Latence moyenne     : lectures ${fmt(latence("reads"), 1)} ms, écritures ${fmt(latence("writes"), 1)} ms`);
print(`  Opérations actives  : ${ga.readers} en lecture, ${ga.writers} en écriture ; en attente : ${gq.readers} en lecture, ${gq.writers} en écriture`);
print(`  Tickets de lecture  : ${tickets.out} utilisés sur ${tickets.totalTickets}`);
print(`  Connexions          : ${apres.connections.current} ouvertes, ${apres.connections.available} disponibles`);
print(`  Cache WiredTiger    : ${fmt(utilise)} Mo sur ${fmt(maxi)} Mo (${fmt(100 * utilise / maxi)} %), mémoire résidente ${apres.mem.resident} Mo`);
EOF
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/diagnostic.js
```

Résultat attendu (valeurs variables) :

```text
Diagnostic de vm-bd511 (MongoDB 8.3.13) sur 10 s, à 14:21:58
  Opérations/s        : lectures 5,4, insertions 2,6, mises à jour 1,1, commandes 1,1
  Documents/s         : examinés 5 401 177, renvoyés 54 (100 022 examinés par document renvoyé)
  Clés d'index/s      : 1 ; tris en mémoire/s : 5,4
  Latence moyenne     : lectures 492,2 ms, écritures 5,4 ms
  Opérations actives  : 3 en lecture, 0 en écriture ; en attente : 0 en lecture, 0 en écriture
  Tickets de lecture  : 3 utilisés sur 4
  Connexions          : 21 ouvertes, 51179 disponibles
  Cache WiredTiger    : 216 Mo sur 2 539 Mo (9 %), mémoire résidente 491 Mo
```

Le diagnostic tient en une ligne : **5 millions de documents examinés par seconde pour 54 renvoyés**, soit 100 000 documents lus pour chaque document utile. Chaque lecture parcourt toute la collection (*collection scan*), aucune clé d'index n'est utilisée, et chaque lecture trie ses résultats en mémoire. Les lectures attendent en moyenne une demi-seconde.

Les **tickets** limitent le nombre d'opérations qui s'exécutent en même temps dans le moteur de stockage ; leur nombre s'ajuste automatiquement à la charge depuis MongoDB 7.0. Quand ils sont tous pris, les nouvelles opérations font la queue : le serveur n'en est pas loin.

Le **cache WiredTiger**, lui, n'est pas en cause : la collection (30 Mo compressés sur disque, 135 Mo une fois en mémoire) y tient largement. Sa taille par défaut est la plus grande de ces deux valeurs : 50 % de (mémoire de la VM − 1 Go), ou 256 Mo. On ne la réduit (`storage.wiredTiger.engineConfig.cacheSizeGB`) que si d'autres services partagent la machine ou si `mongod` tourne dans un conteneur limité en mémoire ; un cache plein en permanence, avec une part modifiée (*dirty*) élevée, signale des données actives plus grandes que la mémoire.

### 1.6 Une opération qui ne se termine pas

Pendant ce temps, un analyste lance son rapport de fidélité des clients :

```bash
cat > ~/BD511/ch08/rapport-lent.js <<'EOF'
// rapport-lent.js - BD511 ch.8 : rapport « fidélité des clients », écrit sans précaution par un analyste
// Pour chaque client, compte les ventes réalisées plus d'un an après sa première commande. Sans index sur
// le champ client, chaque recherche ($lookup) parcourt toute la collection : le rapport ne se termine jamais.
// Usage : APPNAME=rapport-fidelite ~/BD511/ch08/mongosh-bd511 --compte charge --quiet ~/BD511/ch08/rapport-lent.js
const debut = Date.now();
print(`${new Date().toTimeString().slice(0, 8)}  rapport de fidélité : début`);
try {
  const resultat = db.getSiblingDB("bd511").ventes.aggregate([
    { $group: { _id: "$client", premiere: { $min: "$date" } } },
    { $lookup: {
        from: "ventes", let: { client: "$_id", premiere: "$premiere" },
        pipeline: [
          { $match: { $expr: { $and: [
            { $eq: ["$client", "$$client"] },
            { $gt: ["$date", { $dateAdd: { startDate: "$$premiere", unit: "year", amount: 1 } }] },
          ] } } },
          { $count: "n" },
        ],
        as: "fidelite" } },
    { $match: { "fidelite.n": { $gte: 5 } } },
    { $count: "clientsFideles" },
  ], { allowDiskUse: true }).toArray();
  print(`${new Date().toTimeString().slice(0, 8)}  clients fidèles : ${resultat[0]?.clientsFideles ?? 0} (${Math.round((Date.now() - debut) / 1000)} s)`);
} catch (e) {
  print(`${new Date().toTimeString().slice(0, 8)}  rapport interrompu au bout de ${Math.round((Date.now() - debut) / 1000)} s : ${e.codeName ?? ""} ${e.message}`);
}
EOF
APPNAME=rapport-fidelite nohup ~/BD511/ch08/mongosh-bd511 --compte charge --quiet ~/BD511/ch08/rapport-lent.js \
  > ~/BD511/ch08/charge/rapport.log 2>&1 &
```

Vingt secondes plus tard, listez les opérations actives depuis plus d'une demi-seconde, avec l'agrégation `$currentOp` :

```bash
cat > ~/BD511/ch08/operations-longues.js <<'EOF'
// operations-longues.js - BD511 ch.8 : opérations actives depuis plus de SEUIL_MS millisecondes (500 par défaut),
// les plus longues d'abord, avec leur identifiant (opid), leur durée, leur plan et l'application qui les a lancées.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/operations-longues.js
const seuil = Number(process.env.SEUIL_MS || 500);
const operations = db.getSiblingDB("admin").aggregate([
  { $currentOp: { allUsers: true, idleConnections: false } },
  { $match: { active: true, op: { $ne: "none" }, microsecs_running: { $gte: seuil * 1000 },
              "command.hello": { $exists: false } } },          // attentes de surveillance des clients, sans intérêt ici
  { $sort: { microsecs_running: -1 } },
]).toArray();
print(`${operations.length} opération(s) active(s) depuis plus de ${seuil} ms`);
for (const o of operations) {
  print(`  opid ${String(o.opid).padEnd(7)} ${(o.microsecs_running / 1e6).toFixed(1).padStart(6)} s  ${o.op.padEnd(8)} ` +
        `${(o.ns ?? "").padEnd(13)} ${(o.planSummary ?? "-").padEnd(9)} ${o.appName ?? ""}`);
}
EOF
sleep 20
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/operations-longues.js
```

Résultat attendu (identifiants, durées et nombre de fiches client en cours variables) :

```text
3 opération(s) active(s) depuis plus de 500 ms
  opid 95237    20.3 s  command  bd511.ventes  COLLSCAN  rapport-fidelite
  opid 60891     0.7 s  query    bd511.ventes  COLLSCAN  bd511-ch08-charge
  opid 67072     0.5 s  query    bd511.ventes  COLLSCAN  bd511-ch08-charge
```

Le rapport tourne depuis 20 secondes. Pour chacun des 50 000 clients, son étape `$lookup` relit toute la collection : il lui faudrait des jours. Il occupe un processeur à lui seul et ralentit l'application : on l'interrompt avec `killOp`, après avoir vérifié de qui il vient.

```bash
~/BD511/ch08/mongosh-bd511 --quiet --eval '
  const op = db.getSiblingDB("admin").aggregate([{ $currentOp: { allUsers: true } },
    { $match: { appName: "rapport-fidelite", ns: "bd511.ventes" } }]).next();
  print("opid", op.opid, "-", Number(op.secs_running), "s -", op.planSummary, "- compte", op.effectiveUsers[0].user, "- client", op.client);
  printjson(db.killOp(op.opid));'
sleep 2
cat ~/BD511/ch08/charge/rapport.log
```

Résultat attendu :

```text
opid 95237 - 24 s - COLLSCAN - compte charge - client 127.0.0.1:36082
{
  info: 'attempting to kill op',
  ok: 1
}
14:22:01  rapport de fidélité : début
14:22:26  rapport interrompu au bout de 25 s : Interrupted Executor error during aggregate command on namespace: bd511.ventes :: caused by :: operation was interrupted
```

`killOp` demande à l'opération de s'arrêter : elle le fait au prochain point d'interruption, en annulant proprement son travail. On ne tue jamais le processus `mongod`. Une opération d'écriture interrompue ne laisse pas de modification partielle d'un document ; une écriture sur plusieurs documents peut en revanche avoir modifié une partie d'entre eux, d'où la prudence avant d'interrompre une écriture.

> **En production**, plutôt que d'interrompre les opérations à la main, on borne leur durée : option `maxTimeMS` côté application, ou paramètre serveur `defaultMaxTimeMS` (MongoDB 8.0 et plus), qui interrompt automatiquement les lectures trop longues.

### 1.7 Bilan du diagnostic

| Observation | Outil | Interprétation |
| --- | --- | --- |
| `mongod` à près de 200 % de CPU | `top` | le serveur calcule sans arrêt |
| 5 lectures/s, 3 opérations en cours en permanence | `mongostat` | peu d'opérations, mais longues |
| 15 s de travail en 5 s sur `bd511.ventes`, en lecture | `mongotop` | une lecture sur cette collection est en cause |
| 100 000 documents examinés par document renvoyé, aucun index utilisé, tri en mémoire | `serverStatus` | des parcours complets de la collection |
| rapport en cours depuis 20 s, en `COLLSCAN` | `$currentOp` | opération incontrôlée, interrompue avec `killOp` |

Il reste à identifier précisément la requête de l'application qui parcourt la collection.

---

## Partie 2 – Repérer la requête lente et la corriger

L'application tourne toujours : laissez les trois clients actifs jusqu'à la partie 2.6.

### 2.1 `mongostat` : documents examinés et documents renvoyés

L'option `-o` de `mongostat` affiche n'importe quel compteur de `serverStatus`. Le suffixe `.rate()` le convertit en débit par seconde, et `=` donne un titre à la colonne. Affichez les indicateurs repérés en partie 1.5 :

```bash
mongostat --uri "mongodb://diag@127.0.0.1:27017/?authSource=admin&appName=bd511-ch08-mongostat" \
  --config ~/BD511/ch08/secrets/diag.yaml \
  -o 'opcounters.query.rate()=lectures/s,metrics.queryExecutor.scannedObjects.rate()=examinés/s,metrics.document.returned.rate()=renvoyés/s,metrics.queryExecutor.scanned.rate()=clés/s,metrics.operation.scanAndOrder.rate()=tris/s,time' \
  -n 5 2
```

Résultat attendu (valeurs variables) :

```text
lectures/s  examinés/s  renvoyés/s  clés/s  tris/s                time
         5     5007311          50       0       5 Oct 25 14:23:02.452
         5     5009152          50       0       5 Oct 25 14:23:04.453
         6     5512640          55       0       6 Oct 25 14:23:06.452
         5     5006887          50       0       5 Oct 25 14:23:08.454
         5     5011073          50       0       5 Oct 25 14:23:10.452
```

Chaque lecture examine un million de documents (toute la collection), n'utilise aucune clé d'index, renvoie 10 documents et trie en mémoire. Un `mongostat` ainsi configuré, laissé ouvert dans un terminal, suffit à repérer ce type de dérive. Reste à savoir **quelle** requête en est responsable : c'est le rôle du profiler et du journal.

### 2.2 Le profiler : enregistrer les opérations lentes d'une base

Le **profiler** enregistre les opérations d'une base dans sa collection `system.profile`, avec leur durée, leur plan et le nombre de documents examinés. Le niveau 1 enregistre les opérations qui dépassent le seuil `slowms` (100 ms par défaut), le niveau 2 toutes les opérations. Activez le niveau 1 sur la base `bd511` pendant 30 secondes :

```bash
~/BD511/ch08/mongosh-bd511 --quiet --eval 'print(EJSON.stringify(db.setProfilingLevel(1, { slowms: 100 })))'
sleep 30
~/BD511/ch08/mongosh-bd511 --quiet --eval 'print(EJSON.stringify(db.setProfilingLevel(0)))
  print(db.system.profile.countDocuments(), "entrées dans bd511.system.profile")'
```

Résultat attendu (chaque appel renvoie les réglages **précédents** ; nombre d'entrées variable) :

```text
{"was":0,"slowms":100,"slowinprogms":5000,"sampleRate":1,"ok":1}
{"was":1,"slowms":100,"slowinprogms":5000,"sampleRate":1,"ok":1}
138 entrées dans bd511.system.profile
```

Le script suivant regroupe les entrées par **forme de requête** (*query shape* : la requête sans ses valeurs, identifiée par `queryShapeHash`) et les trie par durée cumulée :

```bash
cat > ~/BD511/ch08/analyse-profil.js <<'EOF'
// analyse-profil.js - BD511 ch.8 : synthèse des opérations lentes enregistrées par le profiler de la base bd511
// Regroupe les entrées de system.profile par forme de requête (queryShapeHash) : nombre, durée moyenne,
// documents examinés et renvoyés, plan d'exécution, puis affiche un exemple de la forme la plus coûteuse.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/analyse-profil.js
const formes = db.system.profile.aggregate([
  { $match: { ns: { $ne: "bd511.system.profile" } } },
  { $group: {
      _id: { $ifNull: ["$queryShapeHash", "$op"] },
      op: { $first: "$op" }, ns: { $first: "$ns" }, plan: { $first: "$planSummary" },
      nombre: { $sum: 1 }, dureeMoy: { $avg: "$millis" }, dureeTotale: { $sum: "$millis" },
      examines: { $avg: "$docsExamined" }, renvoyes: { $avg: "$nreturned" }, exemple: { $first: "$command" } } },
  { $sort: { dureeTotale: -1 } },
]).toArray();
const total = db.system.profile.countDocuments({ ns: { $ne: "bd511.system.profile" } });
print(`${total} opérations lentes profilées (seuil ${db.getProfilingStatus().slowms} ms), ${formes.length} forme(s) de requête`);
for (const f of formes) {
  print(`  ${String(f.nombre).padStart(4)} × ${f.op.padEnd(8)} ${f.ns.padEnd(13)} ${(f.plan ?? "-").padEnd(9)} ` +
        `durée moy. ${Math.round(f.dureeMoy)} ms, documents examinés ${Math.round(f.examines).toLocaleString("fr-FR")}, renvoyés ${Math.round(f.renvoyes)}`);
}
if (formes.length) {
  const { lsid, $db, ...commande } = formes[0].exemple;
  print("Forme la plus coûteuse, exemple :");
  print("  " + EJSON.stringify(commande));
}
EOF
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/analyse-profil.js
```

Résultat attendu (valeurs variables) :

```text
138 opérations lentes profilées (seuil 100 ms), 1 forme(s) de requête
   138 × query    bd511.ventes  COLLSCAN  durée moy. 619 ms, documents examinés 1 000 285, renvoyés 10
Forme la plus coûteuse, exemple :
  {"find":"ventes","filter":{"client":"C31977"},"sort":{"date":-1},"limit":10}
```

La coupable est identifiée : la **fiche client**, `find({ client }).sort({ date: -1 }).limit(10)`, parcourt toute la collection (`COLLSCAN`) pour renvoyer 10 documents. Les insertions et les mises à jour, rapides, n'apparaissent pas.

> **Le profiler en production.** Il écrit dans la base à chaque opération enregistrée : on ne l'active que pour un diagnostic, le temps nécessaire, sur la base concernée, et on peut en limiter le volume (option `sampleRate`, filtre `filter`). La collection `system.profile` est une collection plafonnée (*capped*) de 1 Mo : les entrées les plus anciennes sont écrasées.

### 2.3 Le journal de `mongod` : les requêtes lentes, sans profiler

Même profiler désactivé, `mongod` écrit dans son journal toute opération qui dépasse `slowms` (message `Slow query`). Le journal est au format JSON : une ligne par événement, que `jq` filtre et met en forme. Le fichier appartient à l'utilisateur `mongodb` (mode 600), d'où `sudo`.

Les trois dernières requêtes lentes sur `bd511.ventes` :

```bash
sudo jq -c 'select(.msg == "Slow query" and .attr.ns == "bd511.ventes")
  | {heure: .t["$date"][11:19], app: .attr.appName, ms: .attr.durationMillis, plan: .attr.planSummary,
     examines: .attr.docsExamined, renvoyes: .attr.nreturned, filtre: .attr.command.filter}' \
  /var/log/mongodb/mongod.log | tail -n 3
```

Résultat attendu (valeurs variables) :

```text
{"heure":"14:24:05","app":"bd511-ch08-charge","ms":541,"plan":"COLLSCAN","examines":1004530,"renvoyes":10,"filtre":{"client":"C20617"}}
{"heure":"14:24:05","app":"bd511-ch08-charge","ms":527,"plan":"COLLSCAN","examines":1004531,"renvoyes":10,"filtre":{"client":"C47360"}}
{"heure":"14:24:06","app":"bd511-ch08-charge","ms":536,"plan":"COLLSCAN","examines":1004533,"renvoyes":10,"filtre":{"client":"C08245"}}
```

Le même regroupement par forme de requête que pour le profiler, sur tout le journal :

```bash
sudo jq -n -r '[inputs | select(.msg == "Slow query" and .attr.ns == "bd511.ventes")]
  | group_by(.attr.queryShapeHash) | sort_by(-length)[]
  | "\(length) × \(.[0].attr.planSummary), \(map(.attr.durationMillis) | add / length | round) ms en moyenne, \(.[0].attr.appName) : \(.[0].attr.command | del(.lsid, ."$db") | tojson | .[0:100])"' \
  /var/log/mongodb/mongod.log
```

Résultat attendu (valeurs variables) :

```text
622 × COLLSCAN, 591 ms en moyenne, bd511-ch08-charge : {"find":"ventes","filter":{"client":"C08069"},"sort":{"date":-1},"limit":10}
1 × null, 121 ms en moyenne, mongoimport : {"insert":"ventes","ordered":false,"rawData":false,"bypassEmptyTsReplacement":true,"writeConcern":{"
1 × COLLSCAN, 282 ms en moyenne, bd511-ch08-charge : {"aggregate":"ventes","pipeline":[{"$match":{}},{"$group":{"_id":1,"n":{"$sum":1}}}],"cursor":{}}
1 × COLLSCAN, 21362 ms en moyenne, rapport-fidelite : {"aggregate":"ventes","pipeline":[{"$group":{"_id":"$client","premiere":{"$min":"$date"}}},{"$lookup
```

La fiche client domine de loin. Le journal a aussi gardé un lot d'insertions de l'import (partie 0.4, s'il a dépassé 100 ms), le comptage de fin d'import, et le rapport de la partie 1.6.

Le journal garde aussi la trace du rapport de la partie 1.6 : MongoDB 8.3 signale dès 5 secondes une opération **encore en cours** (`Slow in-progress query`, seuil `slowinprogms` vu en partie 2.2), puis l'opération terminée, ici interrompue :

```bash
sudo jq -c 'select(.attr.appName == "rapport-fidelite" and (.msg | startswith("Slow")))
  | {heure: .t["$date"][11:19], msg, ms: .attr.durationMillis, plan: .attr.planSummary, erreur: .attr.errName}' \
  /var/log/mongodb/mongod.log
```

Résultat attendu :

```text
{"heure":"14:22:06","msg":"Slow in-progress query","ms":5045,"plan":"COLLSCAN","erreur":null}
{"heure":"14:22:26","msg":"Slow query","ms":24362,"plan":"COLLSCAN","erreur":"Interrupted"}
```

| | Profiler | Journal |
| --- | --- | --- |
| Activation | par base, à la demande (`setProfilingLevel`) | toujours actif (seuil `slowms`) |
| Stockage | collection plafonnée `system.profile` de la base | fichier `/var/log/mongodb/mongod.log` |
| Coût | une écriture par opération enregistrée | une ligne de journal |
| Exploitation | requêtes d'agrégation, depuis mongosh | `jq`, outils de collecte de journaux |
| Usage | diagnostic ponctuel et détaillé | surveillance permanente, historique |

### 2.4 Le plan d'exécution de la requête

`explain("executionStats")` exécute la requête et décrit son plan, étape par étape. Le script suivant résume celui de la fiche d'un client :

```bash
cat > ~/BD511/ch08/plan-fiche-client.js <<'EOF'
// plan-fiche-client.js - BD511 ch.8 : plan d'exécution résumé de la « fiche client » de l'application
// (les 10 dernières ventes du client C01234) : étapes du plan gagnant, documents et clés examinés, durée.
// Usage : ~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/plan-fiche-client.js
const e = db.ventes.find({ client: "C01234" }).sort({ date: -1 }).limit(10).explain("executionStats");
const etapes = [];
for (let s = e.queryPlanner.winningPlan.queryPlan ?? e.queryPlanner.winningPlan; s; s = s.inputStage) etapes.push(s.stage + (s.indexName ? ` (${s.indexName})` : ""));
const x = e.executionStats;
print(`plan : ${etapes.join(" <- ")}`);
print(`renvoyés : ${x.nReturned}, documents examinés : ${x.totalDocsExamined}, clés examinées : ${x.totalKeysExamined}, durée : ${x.executionTimeMillis} ms`);
EOF
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/plan-fiche-client.js
```

Résultat attendu (durée variable) :

```text
plan : SORT <- COLLSCAN
renvoyés : 10, documents examinés : 1004541, clés examinées : 0, durée : 512 ms
```

Le plan se lit de droite à gauche : `COLLSCAN` lit toute la collection, `SORT` trie en mémoire les ventes du client pour ne garder que les 10 plus récentes.

### 2.5 Corriger : créer l'index adapté

La requête filtre sur une **égalité** (`client`), puis **trie** sur `date` en ordre décroissant. L'index composé `{ client: 1, date: -1 }` respecte la règle **ESR** (*Equality, Sort, Range* : d'abord les champs testés par égalité, puis ceux du tri, puis ceux des intervalles) : il mène directement aux ventes du client, déjà rangées de la plus récente à la plus ancienne. MongoDB s'arrête donc après 10 entrées d'index, sans tri en mémoire.

Créez l'index sans arrêter l'application : la construction ne bloque la collection qu'un court instant, au début et à la fin.

```bash
~/BD511/ch08/mongosh-bd511 --quiet --eval '
  const debut = Date.now();
  const nom = db.ventes.createIndex({ client: 1, date: -1 });
  print(`index ${nom} créé en ${((Date.now() - debut) / 1000).toFixed(1)} s`)'
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/plan-fiche-client.js
```

Résultat attendu (durées variables) :

```text
index client_1_date_-1 créé en 6.2 s
plan : LIMIT <- FETCH <- IXSCAN (client_1_date_-1)
renvoyés : 10, documents examinés : 10, clés examinées : 10, durée : 0 ms
```

Le nouveau plan parcourt 10 entrées de l'index (`IXSCAN`), lit les 10 documents correspondants (`FETCH`) et s'arrête (`LIMIT`) : 10 documents examinés au lieu d'un million.

### 2.6 Mesurer le gain

Laissez l'application tourner 30 secondes avec l'index, puis refaites les mesures de la partie 1 :

```bash
sleep 30
bash ~/BD511/ch08/charge.sh etat
~/BD511/ch08/mongosh-bd511 --quiet ~/BD511/ch08/diagnostic.js
```

Résultat attendu (valeurs variables) :

```text
client1 : 14:25:41  fiches client 62 (moy. 2 ms) ; mises à jour 13 (moy. 2 ms) ; nouvelles ventes 25 (moy. 2 ms)
client2 : 14:25:41  fiches client 57 (moy. 3 ms) ; mises à jour 14 (moy. 2 ms) ; nouvelles ventes 29 (moy. 2 ms)
client3 : 14:25:42  fiches client 61 (moy. 2 ms) ; mises à jour 15 (moy. 2 ms) ; nouvelles ventes 24 (moy. 2 ms)
Diagnostic de vm-bd511 (MongoDB 8.3.13) sur 10 s, à 14:25:52
  Opérations/s        : lectures 18,1, insertions 7,6, mises à jour 4,5, commandes 1,1
  Documents/s         : examinés 187, renvoyés 181 (1 examinés par document renvoyé)
  Clés d'index/s      : 187 ; tris en mémoire/s : 0,0
  Latence moyenne     : lectures 0,7 ms, écritures 0,5 ms
  Opérations actives  : 0 en lecture, 0 en écriture ; en attente : 0 en lecture, 0 en écriture
  Tickets de lecture  : 0 utilisés sur 4
  Connexions          : 19 ouvertes, 51181 disponibles
  Cache WiredTiger    : 268 Mo sur 2 539 Mo (11 %), mémoire résidente 548 Mo
```

| Indicateur | Sans index | Avec l'index `client_1_date_-1` |
| --- | --- | --- |
| Opérations réalisées par client, en 10 s | ≈ 30 | ≈ 100 (le rythme visé) |
| Durée d'une fiche client, vue par l'application | ≈ 500 ms | quelques ms |
| Documents examinés par document renvoyé | ≈ 100 000 | 1 |
| Opérations en cours en permanence | 3 | 0 |

Le serveur traite désormais tout ce que l'application lui demande, et ses processeurs sont redevenus disponibles. Arrêtez l'application :

```bash
bash ~/BD511/ch08/charge.sh arreter
```

Résultat attendu :

```text
Clients arrêtés
```

### 2.7 Réglages de production : seuil des opérations lentes et profiler

Les réglages faits avec `setProfilingLevel` sont perdus au redémarrage de `mongod`. En production, on les fixe dans `/etc/mongod.conf`, dans la section `operationProfiling` que le chapitre 2 avait réservée :

- `mode: "off"` : profiler désactivé, sauf diagnostic ponctuel ;
- `slowOpThresholdMs: 100` : seuil des opérations lentes, écrites dans le journal (valeur par défaut, rendue explicite pour être visible et ajustable).

Le même script prépare la rotation du journal (partie 2.8) : `systemLog.logRotate: reopen` demande à `mongod` de rouvrir son fichier journal, une fois renommé par `logrotate`, au lieu de le renommer lui-même. Le script sauvegarde le fichier d'origine, vérifie que `mongod` accepte le nouveau fichier (`--outputConfig`) et affiche les différences :

```bash
cat > ~/BD511/ch08/config-mongod.sh <<'EOF'
#!/usr/bin/env bash
# config-mongod.sh - BD511 ch.8 : réglages de production du chapitre 8 dans /etc/mongod.conf
#   systemLog.logRotate: reopen   -> la rotation du journal est confiée à logrotate (mongod rouvre son fichier)
#   operationProfiling            -> profiler désactivé, seuil des opérations lentes explicite (100 ms)
# Le fichier d'origine est sauvegardé une fois sous /etc/mongod.conf.avant-ch08. Le script peut être relancé.
# Usage : sudo bash ~/BD511/ch08/config-mongod.sh   (puis sudo systemctl restart mongod)
set -euo pipefail
CONF=/etc/mongod.conf
[[ -f $CONF.avant-ch08 ]] || cp -p "$CONF" "$CONF.avant-ch08"
nouveau=$(mktemp)
trap 'rm -f "$nouveau"' EXIT
cp "$CONF" "$nouveau" && chmod 644 "$nouveau"

# 1) logRotate: reopen, ajouté juste après logAppend dans la section systemLog
if ! grep -qE '^\s+logRotate:' "$nouveau"; then
  grep -qE '^\s+logAppend:\s*true' "$nouveau" || { echo "logAppend: true introuvable dans $CONF" >&2; exit 1; }
  sed -i -E 's/^(\s+)logAppend:\s*true.*$/&\n\1# Rotation par logrotate (\/etc\/logrotate.d\/mongod) : mongod rouvre le fichier sur SIGUSR1.\n\1logRotate: reopen/' "$nouveau"
fi

# 2) section operationProfiling, à la place de la ligne réservée par le chapitre 2 (ou en fin de fichier)
if ! grep -qE '^operationProfiling:' "$nouveau"; then
  bloc='operationProfiling:   # chapitre 8 - profiler et requêtes lentes\n  # Profiler désactivé en production : les opérations lentes sont tout de même écrites dans le journal.\n  mode: "off"\n  # Seuil des opérations lentes (journal, et profiler quand on l'"'"'active) : 100 ms, valeur par défaut rendue explicite.\n  slowOpThresholdMs: 100'
  if grep -qE '^#operationProfiling:' "$nouveau"; then
    sed -i -E "s/^#operationProfiling:.*$/$bloc/" "$nouveau"
  else
    printf '\n%b\n' "$bloc" >> "$nouveau"
  fi
fi

# Contrôle : mongod doit lire le nouveau fichier sans erreur
sudo -u mongodb /usr/bin/mongod --config "$nouveau" --outputConfig > /dev/null
if cmp -s "$CONF" "$nouveau"; then echo "$CONF : déjà à jour"; else
  diff -u "$CONF.avant-ch08" "$nouveau" | tail -n +3 || true
  install -m 644 -o root -g root "$nouveau" "$CONF"
  echo "$CONF mis à jour : redémarrez mongod"
fi
EOF
sudo bash ~/BD511/ch08/config-mongod.sh
```

Résultat attendu (les numéros de ligne dépendent de votre fichier ; si le contrôle d'accès est activé, la ligne `authorization: enabled` n'est pas commentée) :

```text
@@ -19,6 +19,8 @@
   path: /var/log/mongodb/mongod.log
   # Ajoute au fichier existant au redémarrage au lieu de le renommer.
   logAppend: true
+  # Rotation par logrotate (/etc/logrotate.d/mongod) : mongod rouvre le fichier sur SIGUSR1.
+  logRotate: reopen
 
 # --- Réseau ----------------------------------------------------------------------
 net:
@@ -38,4 +40,8 @@
 #  authorization: enabled
 #replication:         # chapitre 6 - replica set
 #sharding:            # chapitre 7 - cluster shardé
-#operationProfiling:  # chapitre 8 - profiler et requêtes lentes
+operationProfiling:   # chapitre 8 - profiler et requêtes lentes
+  # Profiler désactivé en production : les opérations lentes sont tout de même écrites dans le journal.
+  mode: "off"
+  # Seuil des opérations lentes (journal, et profiler quand on l'active) : 100 ms, valeur par défaut rendue explicite.
+  slowOpThresholdMs: 100
/etc/mongod.conf mis à jour : redémarrez mongod
```

Redémarrez `mongod` et vérifiez les réglages pris en compte :

```bash
sudo systemctl restart mongod
~/BD511/ch08/mongosh-bd511 --quiet --eval '
  const p = db.adminCommand({ getCmdLineOpts: 1 }).parsed;
  print(EJSON.stringify({ logRotate: p.systemLog.logRotate, operationProfiling: p.operationProfiling,
                         profiler: db.getProfilingStatus() }, null, 2))'
```

Résultat attendu :

```text
{
  "logRotate": "reopen",
  "operationProfiling": {
    "mode": "off",
    "slowOpThresholdMs": 100
  },
  "profiler": {
    "was": 0,
    "slowms": 100,
    "slowinprogms": 5000,
    "sampleRate": 1,
    "ok": 1
  }
}
```

### 2.8 Rotation du journal avec `logrotate`

Le journal de `mongod` grossit sans limite. La rotation recommandée sous Linux est confiée à `logrotate`, comme pour les autres services du système : chaque jour, il renomme le fichier, puis envoie le signal `SIGUSR1` à `mongod`, qui rouvre un nouveau `mongod.log` (mode `reopen`). Les 14 derniers jours sont conservés et compressés.

```bash
sudo tee /etc/logrotate.d/mongod > /dev/null <<'EOF'
# /etc/logrotate.d/mongod - BD511 ch.8 : rotation du journal de l'instance mongod du chapitre 2
# logrotate (lancé chaque jour par logrotate.timer) renomme mongod.log en mongod.log.1, puis demande à mongod
# de rouvrir son journal par le signal SIGUSR1 (systemLog.logRotate: reopen dans /etc/mongod.conf).
/var/log/mongodb/mongod.log {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    create 0600 mongodb mongodb
    postrotate
        /usr/bin/systemctl kill --signal=SIGUSR1 --kill-whom=main mongod.service
    endscript
}
EOF
sudo logrotate --debug /etc/logrotate.d/mongod 2>&1 | grep -E '^(rotating pattern|empty log|considering log|  log (does not )?needs?)'
```

Résultat attendu (`--debug` simule la rotation sans rien modifier) :

```text
rotating pattern: /var/log/mongodb/mongod.log  after 1 days (14 rotations)
empty log files are not rotated, old logs are removed
considering log /var/log/mongodb/mongod.log
  log does not need rotating (log has already been rotated)
```

Forcez une rotation pour la tester, puis vérifiez que `mongod` écrit bien dans le nouveau fichier :

```bash
sudo logrotate --force /etc/logrotate.d/mongod
sudo ls -l /var/log/mongodb
sudo tail -n 1 /var/log/mongodb/mongod.log.1 | jq -c '{t: .t["$date"], msg}'
~/BD511/ch08/mongosh-bd511 --quiet --eval 'db.adminCommand({ ping: 1 })'
sudo jq -c '{t: .t["$date"], msg}' /var/log/mongodb/mongod.log | head -n 3
```

Résultat attendu (dates et tailles variables ; d'éventuels fichiers `mongod.log.<date>` des chapitres précédents peuvent aussi apparaître) :

```text
total 1244
-rw------- 1 mongodb mongodb    1485 oct.  25 14:27 mongod.log
-rw------- 1 mongodb mongodb 1267259 oct.  25 14:27 mongod.log.1
{"t":"2026-10-25T14:27:12.618+01:00","msg":"Log rotation initiated"}
{ ok: 1 }
{"t":"2026-10-25T14:27:12.618+01:00","msg":"Process Details"}
{"t":"2026-10-25T14:27:12.618+01:00","msg":"current featureCompatibilityVersion value"}
{"t":"2026-10-25T14:27:12.618+01:00","msg":"Build Info"}
```

Le dernier message de l'ancien fichier annonce la rotation ; le nouveau commence par les informations d'identification du processus, ce qui le rend lisible seul. Lors de la prochaine rotation, `mongod.log.1` sera compressé en `mongod.log.2.gz` (option `delaycompress`).

---

## Partie 3 – Superviser avec l'exporteur, Prometheus et Grafana

Les outils des parties 1 et 2 répondent à la question « que se passe-t-il **maintenant** ? », à condition d'être devant l'écran. Une chaîne de supervision collecte les mêmes indicateurs en permanence, les conserve, les affiche et alerte quand ils dérivent.

### 3.1 L'architecture

| Service | Image | Adresse | Rôle |
| --- | --- | --- | --- |
| `mongodb-exporter` | `percona/mongodb_exporter:0.54.0` | `127.0.0.1:9216/metrics` | interroge `mongod` (compte `exporteur`) et publie ses métriques au format Prometheus |
| `prometheus` | `prom/prometheus:v3.15.1-busybox` | `127.0.0.1:9090` | collecte les métriques toutes les 15 s (*scrape*), les stocke 15 jours, évalue les règles d'alerte |
| `grafana` | `grafana/grafana:13.2.4` | `127.0.0.1:3000` | tableaux de bord ; interroge Prometheus |

Choix de déploiement :

- **Réseau de la VM** (`network_mode: host`) : `mongod` n'écoute que sur `127.0.0.1` (chapitre 2). Un conteneur sur un réseau Docker ne pourrait pas le joindre sans ouvrir `mongod` au réseau. Sur le réseau de la VM, l'exporteur le joint directement, et chaque service n'écoute lui-même que sur `127.0.0.1` : rien n'est exposé à l'extérieur.
- **Compte dédié** `exporteur`, aux rôles `clusterMonitor` et `read` sur `local`, ceux que recommande Percona : il lit les métriques, jamais les données des applications.
- **Secrets dans des fichiers** en mode 600 ou 440, jamais dans `docker-compose.yml` ni sur une ligne de commande : identifiants de l'exporteur (`env_file`) et mot de passe de l'administrateur de Grafana (*secret* Compose, lu par Grafana grâce au suffixe `__FILE`).
- **Configuration en fichiers** (*provisioning*) : la source de données et le tableau de bord sont créés par Grafana à son démarrage. Rien n'est saisi à la main, tout se versionne et se redéploie à l'identique.
- **Images à version fixe**, redémarrage automatique (`restart: unless-stopped`), mémoire limitée, rétention bornée (15 jours, 2 Go), contrôles de santé (`healthcheck`).

> **En production**, Prometheus et Grafana tournent sur un serveur de supervision distinct, qui collecte toutes les instances ; un exporteur tourne à côté de chaque `mongod`. Les alertes partent vers **Alertmanager**, qui les envoie par courriel ou messagerie : ce dernier maillon dépasse le cadre du TP.

### 3.2 Créer les secrets de la supervision

```bash
cd ~/BD511/supervision
mkdir -p secrets && chmod 700 secrets
( umask 077
  printf 'MONGODB_URI=mongodb://127.0.0.1:27017/admin?appName=mongodb-exporter\nMONGODB_USER=exporteur\nMONGODB_PASSWORD=%s\n' \
    "$(< ~/BD511/ch08/secrets/exporteur.pwd)" > secrets/exporteur.env
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 20 > secrets/grafana_admin.pwd )
sudo chown 472:"$(id -g)" secrets/grafana_admin.pwd && sudo chmod 440 secrets/grafana_admin.pwd
ls -l secrets
```

Résultat attendu (dates variables ; `stagiaire` est votre compte) :

```text
total 8
-rw------- 1 stagiaire stagiaire 134 oct.  25 14:29 exporteur.env
-r--r----- 1       472 stagiaire  20 oct.  25 14:29 grafana_admin.pwd
```

Le mot de passe de Grafana appartient à l'utilisateur du conteneur Grafana (uid 472), qui doit pouvoir le lire ; votre groupe peut aussi le lire, pour vous connecter. Docker Compose transmet les *secrets* sous forme de fichiers montés, avec les droits du fichier d'origine.

### 3.3 Configurer Prometheus

Le fichier `prometheus.yml` déclare les cibles à collecter et les règles d'alerte à évaluer :

```bash
mkdir -p ~/BD511/supervision/prometheus
cat > ~/BD511/supervision/prometheus/prometheus.yml <<'EOF'
# prometheus.yml - BD511 ch.8 : collecte des métriques de l'instance mongod du chapitre 2
global:
  scrape_interval: 15s        # fréquence de collecte des métriques
  scrape_timeout: 10s
  evaluation_interval: 15s    # fréquence d'évaluation des règles d'alerte
  external_labels:
    projet: BD511

rule_files:
  - /etc/prometheus/alertes.yml

scrape_configs:
  # Exporteur MongoDB de Percona : une cible par instance mongod
  - job_name: mongodb
    static_configs:
      - targets: ["127.0.0.1:9216"]
        labels:
          instance: mongod-bd511      # nom lisible, à la place de l'adresse de l'exporteur
  # Prometheus se surveille lui-même
  - job_name: prometheus
    static_configs:
      - targets: ["127.0.0.1:9090"]
EOF
```

Les règles d'alerte portent sur les symptômes observés en parties 1 et 2. Chaque règle a une expression PromQL, une durée minimale (`for`) pendant laquelle l'expression doit rester vraie avant le déclenchement, une sévérité et un message :

```bash
cat > ~/BD511/supervision/prometheus/alertes.yml <<'EOF'
# alertes.yml - BD511 ch.8 : règles d'alerte sur l'instance mongod
# Seuils adaptés au TP ; en production, on les ajuste après quelques semaines d'observation.
groups:
  - name: mongodb
    rules:
      - alert: MongoDBInjoignable
        expr: up{job="mongodb"} == 0 or mongodb_up == 0
        for: 1m
        labels:
          severite: critique
        annotations:
          summary: "Instance {{ $labels.instance }} : mongod ou son exporteur ne répond plus"

      - alert: MongoDBBalayagesExcessifs
        expr: |
          sum by (instance) (rate(mongodb_ss_metrics_queryExecutor_scannedObjects[1m]))
            / clamp_min(sum by (instance) (rate(mongodb_ss_metrics_document{doc_op_type="returned"}[1m])), 1)
            > 1000
        for: 1m
        labels:
          severite: avertissement
        annotations:
          summary: "Instance {{ $labels.instance }} : {{ $value | humanize }} documents examinés par document renvoyé"
          description: "Des requêtes parcourent des collections entières : index manquant, masqué ou inadapté."

      - alert: MongoDBLecturesLentes
        expr: |
          sum by (instance) (rate(mongodb_ss_opLatencies_latency{op_type="reads"}[1m]))
            / clamp_min(sum by (instance) (rate(mongodb_ss_opLatencies_ops{op_type="reads"}[1m])), 1)
            / 1000 > 100
        for: 1m
        labels:
          severite: avertissement
        annotations:
          summary: "Instance {{ $labels.instance }} : lectures à {{ $value | humanize }} ms en moyenne"

      - alert: MongoDBConnexionsSaturees
        expr: |
          mongodb_ss_connections{conn_type="current"}
            / (mongodb_ss_connections{conn_type="current"} + ignoring(conn_type) mongodb_ss_connections{conn_type="available"})
            > 0.8
        for: 5m
        labels:
          severite: avertissement
        annotations:
          summary: "Instance {{ $labels.instance }} : plus de 80 % des connexions possibles sont ouvertes"

      - alert: MongoDBCacheSature
        expr: mongodb_ss_wt_cache_bytes_currently_in_the_cache / mongodb_ss_wt_cache_maximum_bytes_configured > 0.95
        for: 10m
        labels:
          severite: avertissement
        annotations:
          summary: "Instance {{ $labels.instance }} : cache WiredTiger rempli à plus de 95 %"
EOF
```

| Règle | Condition | Correspond à |
| --- | --- | --- |
| `MongoDBInjoignable` | exporteur muet, ou `mongod` injoignable, pendant 1 min | arrêt du service |
| `MongoDBBalayagesExcessifs` | plus de 1 000 documents examinés par document renvoyé, pendant 1 min | partie 2.1 : index manquant |
| `MongoDBLecturesLentes` | lectures à plus de 100 ms en moyenne, pendant 1 min | partie 1.5 : latence |
| `MongoDBConnexionsSaturees` | plus de 80 % des connexions possibles ouvertes, pendant 5 min | fuite de connexions d'une application |
| `MongoDBCacheSature` | cache WiredTiger rempli à plus de 95 %, pendant 10 min | données actives plus grandes que le cache |

> **`rate()`** calcule le débit par seconde d'un compteur sur une fenêtre de temps, ici la dernière minute : c'est l'équivalent, dans Prometheus, des débits calculés par `diagnostic.js` et `mongostat`. Les métriques de l'exporteur reprennent le chemin des champs de `serverStatus` : `mongodb_ss_metrics_queryExecutor_scannedObjects` correspond à `serverStatus().metrics.queryExecutor.scannedObjects`.

### 3.4 Configurer Grafana et générer le tableau de bord

La source de données Prometheus, avec un identifiant fixe (`uid: prometheus`) auquel le tableau de bord fait référence :

```bash
mkdir -p ~/BD511/supervision/grafana/provisioning/datasources ~/BD511/supervision/grafana/provisioning/dashboards \
  ~/BD511/supervision/grafana/dashboards
cat > ~/BD511/supervision/grafana/provisioning/datasources/prometheus.yml <<'EOF'
# Source de données Prometheus, créée au démarrage de Grafana (provisioning)
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    uid: prometheus              # identifiant fixe, référencé par le tableau de bord
    access: proxy                # requêtes envoyées par le serveur Grafana, pas par le navigateur
    url: http://127.0.0.1:9090
    isDefault: true
    editable: false
    jsonData:
      timeInterval: 15s          # intervalle de collecte de Prometheus (calcul de $__rate_interval)
      httpMethod: POST
EOF
```

Le fournisseur de tableaux de bord : Grafana charge les fichiers JSON du répertoire `/etc/grafana/dashboards` dans le dossier `BD511`, et les protège contre les modifications faites dans l'interface :

```bash
cat > ~/BD511/supervision/grafana/provisioning/dashboards/bd511.yml <<'EOF'
# Tableaux de bord chargés depuis des fichiers JSON au démarrage de Grafana (provisioning)
apiVersion: 1
providers:
  - name: BD511
    folder: BD511                # dossier Grafana qui reçoit les tableaux de bord
    type: file
    disableDeletion: true
    allowUiUpdates: false        # le fichier JSON reste la référence
    updateIntervalSeconds: 30
    options:
      path: /etc/grafana/dashboards
EOF
```

Le tableau de bord lui-même est un fichier JSON de plusieurs centaines de lignes. Plutôt que de le recopier, on le **génère** avec un script qui décrit chaque panneau : titre, requêtes PromQL, unité, seuils de couleur.

```bash
cat > ~/BD511/supervision/generer-tableau-de-bord.py <<'EOF'
#!/usr/bin/env python3
"""generer-tableau-de-bord.py - BD511 ch.8 : génère le tableau de bord Grafana « BD511 – Charge MongoDB ».

Le tableau de bord est décrit panneau par panneau (titre, requêtes PromQL, unité), puis écrit au format JSON
de Grafana (modèle classique, schemaVersion 42) dans grafana/dashboards/bd511-mongodb.json.
Grafana le charge au démarrage (provisioning) et le relit toutes les 30 secondes.
Usage : python3 ~/BD511/supervision/generer-tableau-de-bord.py
"""
import json
import pathlib

SOURCE = {"type": "prometheus", "uid": "prometheus"}   # source de données provisionnée (uid fixe)
INTERVALLE = "$__rate_interval"                         # fenêtre des rate() calculée par Grafana
VERT, ORANGE, ROUGE = "green", "orange", "red"
panneaux = []


def requete(expr, legende, ref):
    return {"refId": ref, "datasource": SOURCE, "editorMode": "code", "expr": expr, "legendFormat": legende, "range": True}


def indicateur(titre, description, expr, x, unite, seuils, correspondances=None, decimales=None):
    """Panneau « stat » de la première ligne : une valeur, colorée selon des seuils."""
    defauts = {"unit": unite, "color": {"mode": "thresholds"}, "mappings": correspondances or [],
               "thresholds": {"mode": "absolute", "steps": [{"color": c, "value": v} for c, v in seuils]}}
    if decimales is not None:
        defauts["decimals"] = decimales
    panneaux.append({
        "id": len(panneaux) + 1, "type": "stat", "title": titre, "description": description, "datasource": SOURCE,
        "gridPos": {"h": 4, "w": 4, "x": x, "y": 0}, "targets": [requete(expr, "", "A")],
        "fieldConfig": {"defaults": defauts, "overrides": []},
        "options": {"reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
                    "colorMode": "background", "graphMode": "area", "justifyMode": "auto", "orientation": "auto",
                    "textMode": "value", "wideLayout": True, "showPercentChange": False,
                    "percentChangeColorMode": "standard"}})


def courbes(titre, description, requetes, h, w, x, y, unite, logarithmique=False):
    """Panneau « timeseries » : une courbe par série renvoyée par les requêtes."""
    perso = {"drawStyle": "line", "lineWidth": 1, "fillOpacity": 10, "showPoints": "never", "spanNulls": False,
             "axisPlacement": "auto", "gradientMode": "none", "lineInterpolation": "linear",
             "stacking": {"mode": "none", "group": "A"}}
    defauts = {"unit": unite, "color": {"mode": "palette-classic"}, "custom": perso}
    if logarithmique:
        perso["scaleDistribution"] = {"type": "log", "log": 10}
    else:
        defauts["min"] = 0
    panneaux.append({
        "id": len(panneaux) + 1, "type": "timeseries", "title": titre, "description": description, "datasource": SOURCE,
        "gridPos": {"h": h, "w": w, "x": x, "y": y},
        "targets": [requete(e, l, chr(65 + i)) for i, (e, l) in enumerate(requetes)],
        "fieldConfig": {"defaults": defauts, "overrides": []},
        "options": {"legend": {"displayMode": "list", "placement": "bottom", "showLegend": True, "calcs": []},
                    "tooltip": {"mode": "multi", "sort": "desc"}}})


CPU_VM = f"100 * (1 - sum(rate(mongodb_sys_cpu_idle_ms[{INTERVALLE}])) / (1000 * max(mongodb_sys_cpu_num_logical_cores)))"
OPERATIONS = 'legacy_op_type=~"query|insert|update|delete|getmore"'

# --- Ligne 1 : indicateurs -----------------------------------------------------------------------------
indicateur("MongoDB", "mongodb_up : 1 si l'exporteur joint mongod", 'mongodb_up{job="mongodb"}', 0, "none",
           [(ROUGE, None), (VERT, 1)],
           correspondances=[{"type": "value", "options": {"0": {"text": "Arrêté", "color": ROUGE, "index": 0},
                                                          "1": {"text": "En service", "color": VERT, "index": 1}}}])
indicateur("Opérations/s", "Lectures, insertions, mises à jour, suppressions et getMore par seconde (hors commandes)",
           f"sum(rate(mongodb_ss_opcounters{{{OPERATIONS}}}[{INTERVALLE}]))", 4, "ops", [(VERT, None)], decimales=1)
indicateur("Examinés par renvoyé", "Documents examinés pour un document renvoyé : proche de 1 quand les index sont adaptés",
           f"sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[{INTERVALLE}]))"
           f' / clamp_min(sum(rate(mongodb_ss_metrics_document{{doc_op_type="returned"}}[{INTERVALLE}])), 1)',
           8, "short", [(VERT, None), (ORANGE, 10), (ROUGE, 1000)], decimales=0)
indicateur("Latence des lectures", "Durée moyenne d'une lecture (opLatencies)",
           f'sum(rate(mongodb_ss_opLatencies_latency{{op_type="reads"}}[{INTERVALLE}]))'
           f' / clamp_min(sum(rate(mongodb_ss_opLatencies_ops{{op_type="reads"}}[{INTERVALLE}])), 1) / 1000',
           12, "ms", [(VERT, None), (ORANGE, 20), (ROUGE, 100)], decimales=1)
indicateur("Connexions", "Connexions clientes ouvertes", 'mongodb_ss_connections{conn_type="current"}', 16, "short",
           [(VERT, None), (ORANGE, 400), (ROUGE, 800)])
indicateur("CPU de la VM", "Temps processeur de la VM hors inactivité (métriques système collectées par mongod)",
           CPU_VM, 20, "percent", [(VERT, None), (ORANGE, 70), (ROUGE, 90)], decimales=0)

# --- Ligne 2 : débit et efficacité des requêtes ------------------------------------------------------
courbes("Opérations par seconde", "Compteurs opcounters, par type d'opération",
        [(f"rate(mongodb_ss_opcounters{{{OPERATIONS}}}[{INTERVALLE}])", "{{legacy_op_type}}")], 8, 12, 0, 4, "ops")
courbes("Documents examinés et renvoyés par seconde",
        "Un écart important signale des requêtes qui parcourent des collections entières (échelle logarithmique)",
        [(f"sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[{INTERVALLE}]))", "documents examinés"),
         (f'sum(rate(mongodb_ss_metrics_document{{doc_op_type="returned"}}[{INTERVALLE}]))', "documents renvoyés"),
         (f"sum(rate(mongodb_ss_metrics_queryExecutor_scanned[{INTERVALLE}]))", "clés d'index examinées")],
        8, 12, 12, 4, "short", logarithmique=True)

# --- Ligne 3 : latence et concurrence -------------------------------------------------------------------
courbes("Latence moyenne par type d'opération", "opLatencies : durée moyenne des lectures, écritures et commandes",
        [(f'rate(mongodb_ss_opLatencies_latency{{op_type=~"reads|writes|commands"}}[{INTERVALLE}])'
          f' / clamp_min(rate(mongodb_ss_opLatencies_ops{{op_type=~"reads|writes|commands"}}[{INTERVALLE}]), 1) / 1000',
          "{{op_type}}")], 8, 12, 0, 12, "ms")
courbes("Opérations en cours", "Opérations actives et en attente (globalLock), tickets de lecture occupés",
        [("mongodb_ss_globalLock_activeClients_readers", "lectures actives"),
         ("mongodb_ss_globalLock_activeClients_writers", "écritures actives"),
         ('sum(mongodb_ss_globalLock_currentQueue{count_type=~"readers|writers"})', "en attente"),
         ("mongodb_ss_wt_concurrentTransactions_read_normalPriority_out", "tickets de lecture occupés")],
        8, 12, 12, 12, "short")

# --- Ligne 4 : collections, index et processeur ---------------------------------------------------------
courbes("Temps serveur par collection",
        "Commande top : secondes passées par seconde sur chaque collection de bd511 (comme mongotop)",
        [(f'rate(mongodb_top_total_time{{database="bd511"}}[{INTERVALLE}]) / 1e6', "{{collection}}")], 8, 8, 0, 20, "s")
courbes("Utilisation des index de bd511.ventes", "$indexStats : accès par seconde à chaque index",
        [(f'rate(mongodb_indexstats_accesses_ops{{database="bd511", collection="ventes"}}[{INTERVALLE}])', "{{key_name}}")],
        8, 8, 8, 20, "ops")
courbes("Processeur", "Temps processeur de la VM hors inactivité, et part consommée par mongod",
        [(CPU_VM, "VM"),
         (f"100 * sum(rate(mongodb_ss_extra_info_user_time_us[{INTERVALLE}]) + rate(mongodb_ss_extra_info_system_time_us[{INTERVALLE}]))"
          " / 1e6 / max(mongodb_sys_cpu_num_logical_cores)", "mongod")], 8, 8, 16, 20, "percent")

# --- Ligne 5 : mémoire -------------------------------------------------------------------------------------
courbes("Cache WiredTiger", "Données présentes dans le cache, dont modifiées (dirty), et taille maximale du cache",
        [("mongodb_ss_wt_cache_bytes_currently_in_the_cache", "utilisé"),
         ("mongodb_ss_wt_cache_tracked_dirty_bytes_in_the_cache", "modifié (dirty)"),
         ("mongodb_ss_wt_cache_maximum_bytes_configured", "maximum")], 8, 12, 0, 28, "bytes")
courbes("Mémoire", "Mémoire résidente de mongod, mémoire utilisée et mémoire totale de la VM",
        [("mongodb_ss_mem_resident * 1024 * 1024", "mongod (résidente)"),
         ("(mongodb_sys_memory_MemTotal_kb - mongodb_sys_memory_MemAvailable_kb) * 1024", "VM (utilisée)"),
         ("mongodb_sys_memory_MemTotal_kb * 1024", "VM (totale)")], 8, 12, 12, 28, "bytes")

tableau = {
    "uid": "bd511-mongodb", "title": "BD511 – Charge MongoDB", "tags": ["BD511", "MongoDB"],
    "description": "Instance mongod du chapitre 2 : métriques de percona/mongodb_exporter collectées par Prometheus",
    "timezone": "browser", "editable": False, "graphTooltip": 1, "refresh": "10s", "schemaVersion": 42,
    "time": {"from": "now-15m", "to": "now"}, "timepicker": {}, "templating": {"list": []},
    "annotations": {"list": [{"builtIn": 1, "datasource": {"type": "grafana", "uid": "-- Grafana --"}, "enable": True,
                              "hide": True, "iconColor": "rgba(0, 211, 255, 1)", "name": "Annotations & Alerts",
                              "type": "dashboard"}]},
    "links": [], "panels": panneaux, "version": 1, "fiscalYearStartMonth": 0, "liveNow": False, "weekStart": "",
}
fichier = pathlib.Path(__file__).resolve().parent / "grafana" / "dashboards" / "bd511-mongodb.json"
fichier.write_text(json.dumps(tableau, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print(f"{fichier.relative_to(fichier.parents[2])} : {len(panneaux)} panneaux")
EOF
python3 ~/BD511/supervision/generer-tableau-de-bord.py
```

Résultat attendu :

```text
grafana/dashboards/bd511-mongodb.json : 15 panneaux
```

| Ligne du tableau de bord | Panneaux | Outil équivalent des parties 1 et 2 |
| --- | --- | --- |
| 1 – Indicateurs | MongoDB en service, opérations/s, examinés par renvoyé, latence des lectures, connexions, CPU de la VM | `diagnostic.js` |
| 2 – Débit et efficacité | opérations par seconde et par type ; documents examinés, renvoyés, clés d'index (échelle logarithmique) | `mongostat` |
| 3 – Latence et concurrence | latence moyenne par type ; opérations actives, en attente, tickets de lecture | `diagnostic.js`, `$currentOp` |
| 4 – Collections, index, processeur | temps serveur par collection ; accès à chaque index de `bd511.ventes` ; CPU de la VM et de `mongod` | `mongotop`, `$indexStats`, `top` |
| 5 – Mémoire | cache WiredTiger (utilisé, modifié, maximum) ; mémoire de `mongod` et de la VM | `diagnostic.js` |

### 3.5 Le projet Docker Compose

```bash
cat > ~/BD511/supervision/docker-compose.yml <<'EOF'
# docker-compose.yml - BD511 ch.8 : chaîne de supervision exporteur -> Prometheus -> Grafana
# Les trois services utilisent le réseau de la VM (network_mode: host) : l'exporteur joint mongod sur
# 127.0.0.1:27017 sans que mongod soit ouvert au réseau, et chaque service n'écoute que sur 127.0.0.1.
# Usage : cd ~/BD511/supervision && sudo docker compose up -d --wait
name: supervision                   # nom du projet Compose (minuscules imposées par Docker)

services:
  mongodb-exporter:
    image: percona/mongodb_exporter:0.54.0
    container_name: mongodb-exporter
    restart: unless-stopped
    network_mode: host
    env_file: ./secrets/exporteur.env   # MONGODB_URI, MONGODB_USER, MONGODB_PASSWORD (fichier en mode 600)
    command:
      - --web.listen-address=127.0.0.1:9216
      - --collector.diagnosticdata      # serverStatus et métriques système (getDiagnosticData)
      - --collector.topmetrics          # temps passé par collection (commande top)
      - --collector.indexstats          # utilisation des index ($indexStats)...
      - --mongodb.indexstats-colls=bd511.ventes   # ... de cette collection
      - --log.level=warn
    mem_limit: 128m

  prometheus:
    image: prom/prometheus:v3.15.1-busybox
    container_name: prometheus
    restart: unless-stopped
    network_mode: host
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.path=/prometheus
      - --storage.tsdb.retention.time=15d   # conservation des métriques : 15 jours...
      - --storage.tsdb.retention.size=2GB   # ... dans la limite de 2 Go
      - --web.listen-address=127.0.0.1:9090
    volumes:
      - ./prometheus:/etc/prometheus:ro
      - prometheus-donnees:/prometheus
    depends_on:
      - mongodb-exporter
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9090/-/ready"]
      interval: 15s
      start_period: 1m
      start_interval: 2s
    mem_limit: 512m

  grafana:
    image: grafana/grafana:13.2.4
    container_name: grafana
    restart: unless-stopped
    network_mode: host
    environment:
      GF_SERVER_HTTP_ADDR: 127.0.0.1
      GF_SERVER_HTTP_PORT: "3000"
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD__FILE: /run/secrets/grafana_admin   # mot de passe lu dans un fichier secret
      GF_USERS_ALLOW_SIGN_UP: "false"
      GF_USERS_DEFAULT_LANGUAGE: fr-FR
      GF_ANALYTICS_REPORTING_ENABLED: "false"
      GF_ANALYTICS_CHECK_FOR_UPDATES: "false"
      GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES: "false"
      GF_NEWS_NEWS_FEED_ENABLED: "false"
      GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH: /etc/grafana/dashboards/bd511-mongodb.json
    secrets:
      - grafana_admin
    volumes:
      - ./grafana/provisioning/datasources:/etc/grafana/provisioning/datasources:ro
      - ./grafana/provisioning/dashboards:/etc/grafana/provisioning/dashboards:ro
      - ./grafana/dashboards:/etc/grafana/dashboards:ro
      - grafana-donnees:/var/lib/grafana
    depends_on:
      prometheus:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:3000/api/health"]
      interval: 15s
      start_period: 2m
      start_interval: 2s
    mem_limit: 512m

secrets:
  grafana_admin:
    file: ./secrets/grafana_admin.pwd   # appartient à l'utilisateur grafana du conteneur (uid 472)

volumes:
  prometheus-donnees:
  grafana-donnees:
EOF
cd ~/BD511/supervision
sudo docker compose config --quiet && echo "docker-compose.yml : OK"
```

Résultat attendu :

```text
docker-compose.yml : OK
```

L'exporteur est lancé avec trois collecteurs : `diagnosticdata` (`serverStatus` et métriques système), `topmetrics` (temps par collection, comme `mongotop`) et `indexstats` (utilisation des index, limitée à `bd511.ventes`). En production, on n'active que les collecteurs utiles : chacun ajoute des requêtes sur `mongod` et des séries dans Prometheus.

Téléchargez les images, puis faites vérifier la configuration de Prometheus par son outil `promtool`, fourni dans l'image :

```bash
cd ~/BD511/supervision
sudo docker compose pull
sudo docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint /bin/promtool \
  prom/prometheus:v3.15.1-busybox check config /etc/prometheus/prometheus.yml
```

Résultat attendu (ordre et durées variables ; quelques centaines de Mo à télécharger) :

```text
[+] pull 3/3
 ✔ Image prom/prometheus:v3.15.1-busybox Pulled        21.4s
 ✔ Image percona/mongodb_exporter:0.54.0 Pulled        12.8s
 ✔ Image grafana/grafana:13.2.4          Pulled        38.2s
Checking /etc/prometheus/prometheus.yml
  SUCCESS: 1 rule files found
 SUCCESS: /etc/prometheus/prometheus.yml is valid prometheus config file syntax

Checking /etc/prometheus/alertes.yml
  SUCCESS: 5 rules found

```

### 3.6 Démarrer la chaîne et vérifier chaque maillon

`--wait` rend la main quand les services sont démarrés et que leurs contrôles de santé réussissent : Prometheus prêt, puis Grafana (qui dépend de Prometheus).

```bash
cd ~/BD511/supervision
sudo docker compose up -d --wait
sudo docker compose ps --format 'table {{.Name}}\t{{.Image}}\t{{.Status}}'
```

Résultat attendu (durées variables) :

```text
[+] up 5/5
 ✔ Container mongodb-exporter            Healthy          3.5s
 ✔ Volume supervision_grafana-donnees    Created          0.0s
 ✔ Volume supervision_prometheus-donnees Created          0.0s
 ✔ Container prometheus                  Healthy          8.4s
 ✔ Container grafana                     Healthy         21.9s
NAME               IMAGE                             STATUS
grafana            grafana/grafana:13.2.4            Up 20 seconds (healthy)
mongodb-exporter   percona/mongodb_exporter:0.54.0   Up 31 seconds
prometheus         prom/prometheus:v3.15.1-busybox   Up 31 seconds (healthy)
```

**L'exporteur.** Il publie ses métriques en texte, une par ligne. `mongodb_up` vaut 1 quand il joint `mongod` avec son compte :

```bash
curl -s http://127.0.0.1:9216/metrics \
  | grep -E '^mongodb_(up|ss_uptime|ss_connections\{conn_type="current"\}|ss_opcounters\{legacy_op_type="query"\})[ {]'
curl -s http://127.0.0.1:9216/metrics | grep -c '^mongodb_'
```

Résultat attendu (valeurs variables) :

```text
mongodb_ss_connections{conn_type="current"} 3
mongodb_ss_opcounters{legacy_op_type="query"} 12
mongodb_ss_uptime 160
mongodb_up{cluster_role="mongod"} 1
4535
```

Plusieurs milliers de métriques : tout `serverStatus`, les métriques système, le temps par collection et l'utilisation des index.

**Prometheus.** La première collecte a lieu dans les 15 secondes qui suivent le démarrage. Vérifiez l'état des cibles, les règles chargées, puis interrogez une métrique :

```bash
sleep 20
curl -s http://127.0.0.1:9090/api/v1/targets \
  | jq -r '.data.activeTargets[] | "\(.labels.job)  \(.labels.instance)  \(.health)  \(.lastError)"'
curl -s http://127.0.0.1:9090/api/v1/rules | jq -r '.data.groups[].rules[] | "\(.name)  \(.health)  \(.state)"'
curl -s --data-urlencode 'query=mongodb_ss_connections{conn_type="current"}' http://127.0.0.1:9090/api/v1/query \
  | jq -c '.data.result[] | {instance: .metric.instance, job: .metric.job, valeur: .value[1]}'
```

Résultat attendu (ordre des cibles variable ; `lastError` vide) :

```text
mongodb  mongod-bd511  up  
prometheus  127.0.0.1:9090  up  
MongoDBInjoignable  ok  inactive
MongoDBBalayagesExcessifs  ok  inactive
MongoDBLecturesLentes  ok  inactive
MongoDBConnexionsSaturees  ok  inactive
MongoDBCacheSature  ok  inactive
{"instance":"mongod-bd511","job":"mongodb","valeur":"3"}
```

Chaque série porte les labels `job` et `instance` de sa cible : `instance` vaut `mongod-bd511`, le nom donné dans `prometheus.yml`. Le label `projet` (`external_labels`) n'apparaît pas ici : Prometheus ne l'ajoute qu'aux données qui en sortent (alertes envoyées, fédération, écriture à distance).

**Grafana.** Son état, l'état de la source de données vue par Grafana, puis le tableau de bord provisionné. L'API d'administration exige le compte `admin`, dont le mot de passe est transmis à `curl` par son entrée standard (`-K -`) pour ne pas apparaître dans la liste des processus :

```bash
curl -s http://127.0.0.1:3000/api/health | jq -c '{database, version}'
curl -s -K - http://127.0.0.1:3000/api/datasources/uid/prometheus/health \
  <<< "user = \"admin:$(< ~/BD511/supervision/secrets/grafana_admin.pwd)\"" | jq -r '.status + " : " + .message'
curl -s -K - "http://127.0.0.1:3000/api/search?query=BD511" \
  <<< "user = \"admin:$(< ~/BD511/supervision/secrets/grafana_admin.pwd)\"" \
  | jq -r '.[] | select(.type == "dash-db") | "\(.folderTitle) / \(.title)  (uid \(.uid))"'
```

Résultat attendu :

```text
{"database":"ok","version":"13.2.4"}
OK : Successfully queried the Prometheus API.
BD511 / BD511 – Charge MongoDB  (uid bd511-mongodb)
```

### 3.7 Ouvrir le tableau de bord

Affichez le mot de passe de l'administrateur de Grafana :

```bash
cat ~/BD511/supervision/secrets/grafana_admin.pwd; echo
```

Dans Firefox, ouvrez **http://127.0.0.1:3000** et connectez-vous avec le compte `admin` et ce mot de passe. La page d'accueil affiche le tableau de bord **BD511 – Charge MongoDB** ; on le retrouve aussi dans le menu **Tableaux de bord**, dossier **BD511**. Il se rafraîchit toutes les 10 secondes et montre les 15 dernières minutes. Ouvrez aussi l'interface de Prometheus, **http://127.0.0.1:9090/alerts**, qui liste les règles d'alerte et leur état.

Pour l'instant, la base est au repos : peu d'opérations, aucune alerte.

### 3.8 Suivre la charge de l'application

Le script suivant affiche, depuis Prometheus, les indicateurs de la première ligne du tableau de bord et les alertes en cours ; un second script suit les alertes toutes les 15 secondes jusqu'à la situation attendue :

```bash
cat > ~/BD511/supervision/indicateurs.sh <<'EOF'
#!/usr/bin/env bash
# indicateurs.sh - BD511 ch.8 : indicateurs clés de l'instance mongod, lus dans Prometheus
# Mêmes calculs que la première ligne du tableau de bord Grafana, sur la dernière minute, puis les alertes en cours.
# Usage : bash ~/BD511/supervision/indicateurs.sh
set -euo pipefail
PROM=http://127.0.0.1:9090
valeur() {   # résultat d'une requête PromQL, arrondi à $2 décimales (0 par défaut) ; « - » si aucune donnée
  curl -s --data-urlencode "query=$1" "$PROM/api/v1/query" \
    | jq -r --argjson d "${2:-0}" '.data.result[0].value[1] // "NaN"
        | if . == "NaN" then "-" else (tonumber * pow(10; $d) | round / pow(10; $d) | tostring) end'
}
OPS='legacy_op_type=~"query|insert|update|delete|getmore"'
echo "$(date +%T)  instance mongod-bd511, moyennes sur la dernière minute"
echo "  MongoDB joignable (mongodb_up)  : $(valeur 'mongodb_up{job="mongodb"}')"
echo "  Opérations/s                    : $(valeur "sum(rate(mongodb_ss_opcounters{$OPS}[1m]))" 1)"
echo "  Documents examinés par renvoyé  : $(valeur 'sum(rate(mongodb_ss_metrics_queryExecutor_scannedObjects[1m]))
  / clamp_min(sum(rate(mongodb_ss_metrics_document{doc_op_type="returned"}[1m])), 1)')"
echo "  Latence des lectures (ms)       : $(valeur 'sum(rate(mongodb_ss_opLatencies_latency{op_type="reads"}[1m]))
  / clamp_min(sum(rate(mongodb_ss_opLatencies_ops{op_type="reads"}[1m])), 1) / 1000' 1)"
echo "  CPU de la VM (%)                : $(valeur '100 * (1 - sum(rate(mongodb_sys_cpu_idle_ms[1m]))
  / (1000 * max(mongodb_sys_cpu_num_logical_cores)))')"
alertes=$(curl -s "$PROM/api/v1/alerts" | jq -r '[.data.alerts[] | "\(.labels.alertname) (\(.state))"] | sort | join(", ")')
echo "  Alertes                         : ${alertes:-aucune}"
EOF
cat > ~/BD511/supervision/suivre-alertes.sh <<'EOF'
#!/usr/bin/env bash
# suivre-alertes.sh - BD511 ch.8 : affiche les alertes de Prometheus toutes les 15 s, jusqu'à la situation attendue
#   declenchee <alerte> : jusqu'à ce que cette alerte soit déclenchée (état firing)
#   aucune              : jusqu'à ce qu'il n'y ait plus aucune alerte
# Abandon au bout de 5 minutes.
# Usage : bash ~/BD511/supervision/suivre-alertes.sh declenchee MongoDBBalayagesExcessifs
#         bash ~/BD511/supervision/suivre-alertes.sh aucune
set -euo pipefail
attendu=${1:?"Usage : $0 declenchee <alerte> | aucune"}
for i in $(seq 1 20); do
  alertes=$(curl -s http://127.0.0.1:9090/api/v1/alerts | jq -r '[.data.alerts[] | "\(.labels.alertname) (\(.state))"] | sort | join(", ")')
  echo "$(date +%T)  ${alertes:-aucune alerte}"
  case $attendu in
    declenchee) [[ $alertes == *"$2 (firing)"* ]] && exit 0 ;;
    aucune)     [[ -z $alertes ]] && exit 0 ;;
  esac
  sleep 15
done
echo "Situation attendue non atteinte au bout de 5 minutes" >&2
exit 1
EOF
```

Redémarrez l'application. L'index étant en place, la charge est saine :

```bash
bash ~/BD511/ch08/charge.sh demarrer
sleep 90
bash ~/BD511/supervision/indicateurs.sh
```

Résultat attendu (valeurs variables) :

```text
3 clients démarrés (journaux : ~/BD511/ch08/charge/client*.log)
14:33:12  instance mongod-bd511, moyennes sur la dernière minute
  MongoDB joignable (mongodb_up)  : 1
  Opérations/s                    : 29.9
  Documents examinés par renvoyé  : 1
  Latence des lectures (ms)       : 0.7
  CPU de la VM (%)                : 8
  Alertes                         : aucune
```

Sur le tableau de bord, observez :

- **Opérations par seconde** : environ 18 lectures, 7 insertions et 4 mises à jour par seconde, les proportions de l'application ;
- **Documents examinés et renvoyés** : les deux courbes se superposent ;
- **Utilisation des index de bd511.ventes** : l'index `client_1_date_-1` sert toutes les fiches client, l'index `_id_` les mises à jour ;
- **Temps serveur par collection** : quelques millisecondes par seconde sur `ventes`.

### 3.9 Provoquer une régression et la voir arriver

Un administrateur, croyant l'index inutile, le **masque** (`hideIndex`) : l'index est toujours maintenu, mais le planificateur l'ignore. C'est d'ailleurs la bonne façon de tester la suppression d'un index en production, car `unhideIndex` le rétablit instantanément, sans reconstruction. Masquez-le, puis suivez les alertes :

```bash
~/BD511/ch08/mongosh-bd511 --quiet --eval 'printjson(db.ventes.hideIndex("client_1_date_-1"))'
bash ~/BD511/supervision/suivre-alertes.sh declenchee MongoDBBalayagesExcessifs
bash ~/BD511/supervision/indicateurs.sh
```

Résultat attendu, en 2 à 3 minutes (heures et valeurs variables ; `pending` : condition vraie, en attente de la durée `for` ; `firing` : alerte déclenchée) :

```text
{
  hidden_old: false,
  hidden_new: true,
  ok: 1
}
14:33:28  aucune alerte
14:33:43  aucune alerte
14:33:58  aucune alerte
14:34:13  MongoDBBalayagesExcessifs (pending)
14:34:28  MongoDBBalayagesExcessifs (pending), MongoDBLecturesLentes (pending)
14:34:43  MongoDBBalayagesExcessifs (pending), MongoDBLecturesLentes (pending)
14:34:58  MongoDBBalayagesExcessifs (pending), MongoDBLecturesLentes (pending)
14:35:13  MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (pending)
14:35:13  instance mongod-bd511, moyennes sur la dernière minute
  MongoDB joignable (mongodb_up)  : 1
  Opérations/s                    : 8.4
  Documents examinés par renvoyé  : 99877
  Latence des lectures (ms)       : 523.7
  CPU de la VM (%)                : 97
  Alertes                         : MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (pending)
```

`MongoDBLecturesLentes` suit de près : elle passe à son tour à l'état `firing` 15 à 30 secondes plus tard.

Sur le tableau de bord, trois indicateurs de la première ligne passent au rouge : examinés par renvoyé, latence des lectures, CPU de la VM. Les courbes racontent la même histoire que les parties 1 et 2 : effondrement du débit, écart de cinq ordres de grandeur entre documents examinés et renvoyés, latence des lectures à 500 ms, plus aucun accès à l'index masqué, processeur saturé par `mongod`. Sur **http://127.0.0.1:9090/alerts**, les deux règles sont passées de *Pending* à *Firing*.

Rétablissez l'index, puis attendez la fin des alertes :

```bash
~/BD511/ch08/mongosh-bd511 --quiet --eval 'printjson(db.ventes.unhideIndex("client_1_date_-1"))'
bash ~/BD511/supervision/suivre-alertes.sh aucune
```

Résultat attendu, en une à deux minutes (le temps que la dernière minute de mesures ne contienne plus la régression) :

```text
{
  hidden_old: true,
  hidden_new: false,
  ok: 1
}
14:35:14  MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (pending)
14:35:29  MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (firing)
14:35:44  MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (firing)
14:35:59  MongoDBBalayagesExcessifs (firing), MongoDBLecturesLentes (firing)
14:36:14  MongoDBBalayagesExcessifs (firing)
14:36:29  aucune alerte
```

Arrêtez l'application :

```bash
bash ~/BD511/ch08/charge.sh arreter
```

Résultat attendu :

```text
Clients arrêtés
```

La chaîne de supervision reste en service : elle redémarre avec la VM (`restart: unless-stopped`, service Docker activé au démarrage).

---

## Partie 4 – Bilan

### 4.1 Contrôle final

```bash
cat > ~/BD511/ch08/verifier-ch08.sh <<'EOF'
#!/usr/bin/env bash
# verifier-ch08.sh - BD511 ch.8 : contrôle final de l'instance mongod et de la chaîne de supervision
# Usage : bash ~/BD511/ch08/verifier-ch08.sh      (demande le mot de passe sudo pour interroger Docker)
set -u
MONGOSH="$HOME/BD511/ch08/mongosh-bd511"
SUP="$HOME/BD511/supervision"
ok=0; ko=0
res() { if [[ $1 == 0 ]]; then printf '  [OK] %s\n' "$2"; ok=$((ok + 1)); else printf '  [KO] %s\n' "$2"; ko=$((ko + 1)); fi; }

echo "== Instance mongod du chapitre 2"
systemctl is-active --quiet mongod; res $? "Service mongod actif"
reglages=$("$MONGOSH" --quiet --eval '
  const p = db.adminCommand({ getCmdLineOpts: 1 }).parsed, s = db.getProfilingStatus();
  print(p.systemLog.logRotate, p.operationProfiling?.mode, s.was, s.slowms)' 2>/dev/null)
[[ $reglages == "reopen off 0 100" ]]; res $? "Réglages (logRotate, profiler, niveau, seuil) : $reglages"
grep -q "kill --signal=SIGUSR1" /etc/logrotate.d/mongod 2>/dev/null; res $? "Rotation du journal par logrotate : /etc/logrotate.d/mongod"
# chaque compte se connecte avec son mot de passe et affiche ses propres rôles
comptes=$(for c in charge diag exporteur; do
  "$MONGOSH" --compte "$c" --quiet --eval '
    const a = db.runCommand({ connectionStatus: 1 }).authInfo;
    print(a.authenticatedUsers[0].user + ":" + a.authenticatedUserRoles.map(r => r.role).sort().join("+"))' 2>/dev/null
done | paste -sd ' ')
[[ $comptes == "charge:readWrite diag:clusterMonitor+dbAdminAnyDatabase+hostManager+readAnyDatabase exporteur:clusterMonitor+read" ]]
res $? "Comptes du TP : $comptes"
index=$("$MONGOSH" --quiet --eval '
  const i = db.ventes.getIndexes().find(x => x.name === "client_1_date_-1");
  print(db.ventes.estimatedDocumentCount() >= 1000000, i ? (i.hidden ? "masqué" : "visible") : "absent")' 2>/dev/null)
[[ $index == "true visible" ]]; res $? "bd511.ventes : au moins 1 000 000 ventes, index client_1_date_-1 $index"

echo "== Chaîne de supervision"
etats=$(cd "$SUP" && sudo docker compose ps --format '{{.Name}}:{{.State}}:{{.Health}}' | sort | tr '\n' ' ')
[[ $etats == "grafana:running:healthy mongodb-exporter:running: prometheus:running:healthy " ]]; res $? "Conteneurs : $etats"
up=$(curl -s http://127.0.0.1:9216/metrics | awk '/^mongodb_up/ {print $2 + 0}')
[[ $up == 1 ]]; res $? "Exporteur : mongodb_up = ${up:-?}"
cibles=$(curl -s http://127.0.0.1:9090/api/v1/targets | jq -r '[.data.activeTargets[] | .labels.job + ":" + .health] | sort | join(" ")')
[[ $cibles == "mongodb:up prometheus:up" ]]; res $? "Prometheus, cibles : $cibles"
regles=$(curl -s http://127.0.0.1:9090/api/v1/rules | jq '[.data.groups[].rules[]] | length')
actives=$(curl -s http://127.0.0.1:9090/api/v1/alerts | jq '[.data.alerts[] | select(.state == "firing")] | length')
[[ $regles == 5 && $actives == 0 ]]; res $? "Prometheus : $regles règles d'alerte chargées, $actives alerte(s) déclenchée(s)"
grafana=$(curl -s -K - "http://127.0.0.1:3000/api/search?query=BD511" <<< "user = \"admin:$(< "$SUP/secrets/grafana_admin.pwd")\"" \
  | jq -r '.[] | select(.type == "dash-db") | .folderTitle + " / " + .title')
[[ $grafana == "BD511 / BD511 – Charge MongoDB" ]]; res $? "Grafana, tableau de bord : $grafana"

echo
echo "Bilan : ${ok} OK, ${ko} KO"
exit $(( ko > 0 ))
EOF
bash ~/BD511/ch08/verifier-ch08.sh
```

Résultat attendu :

```text
== Instance mongod du chapitre 2
  [OK] Service mongod actif
  [OK] Réglages (logRotate, profiler, niveau, seuil) : reopen off 0 100
  [OK] Rotation du journal par logrotate : /etc/logrotate.d/mongod
  [OK] Comptes du TP : charge:readWrite diag:clusterMonitor+dbAdminAnyDatabase+hostManager+readAnyDatabase exporteur:clusterMonitor+read
  [OK] bd511.ventes : au moins 1 000 000 ventes, index client_1_date_-1 true visible
== Chaîne de supervision
  [OK] Conteneurs : grafana:running:healthy mongodb-exporter:running: prometheus:running:healthy 
  [OK] Exporteur : mongodb_up = 1
  [OK] Prometheus, cibles : mongodb:up prometheus:up
  [OK] Prometheus : 5 règles d'alerte chargées, 0 alerte(s) déclenchée(s)
  [OK] Grafana, tableau de bord : BD511 / BD511 – Charge MongoDB

Bilan : 10 OK, 0 KO
```

### 4.2 Ce qu'il faut retenir

- **Une démarche, du système vers la requête** : `top` (quel processus ?), `mongostat` (quelles opérations, à quel débit ?), `mongotop` (sur quelle collection ?), `serverStatus` (pourquoi ?), `$currentOp` (quelle opération, lancée par qui ?), puis profiler, journal et `explain` (quelle requête, avec quel plan ?).
- **L'indicateur décisif** est le rapport entre documents examinés et documents renvoyés. Proche de 1, les index font leur travail ; au-delà de quelques centaines, une requête parcourt une collection.
- **`killOp`** interrompt proprement une opération ; on borne en amont la durée des requêtes avec `maxTimeMS` ou `defaultMaxTimeMS`.
- **Le journal JSON** enregistre en permanence les opérations plus longues que `slowms` (et, depuis 8.3, celles encore en cours au-delà de `slowinprogms`) ; `jq` suffit à l'exploiter. Le **profiler** apporte le détail, le temps d'un diagnostic.
- **Un index composé** suivant la règle ESR (égalité, tri, intervalle) sert à la fois le filtre et le tri ; on le crée sans interrompre l'application. `hideIndex` permet de tester sans risque la suppression d'un index.
- **La supervision** collecte en continu ces mêmes indicateurs : l'exporteur les publie, Prometheus les stocke et évalue les alertes, Grafana les affiche. Une régression se voit sur le tableau de bord, et l'alerte se déclenche en quelques minutes, sans personne devant l'écran.

### 4.3 Bonnes pratiques de production appliquées

| Pratique | Mise en œuvre dans le TP |
| --- | --- |
| Un compte par usage, avec le minimum de droits | `diag` (exploitation), `charge` (application), `exporteur` (`clusterMonitor` et `read` sur `local`) |
| Mots de passe hors des lignes de commande et des fichiers de configuration partagés | fichiers en mode 600 ; `--config` des Database Tools, `env_file` et *secret* Compose, `curl -K -` |
| Nom d'application dans chaque chaîne de connexion | `appName` : opérations en cours et journal attribuables |
| Durée des requêtes bornée | `killOp` en dernier recours ; `maxTimeMS`, `defaultMaxTimeMS` |
| Seuil des opérations lentes explicite, profiler désactivé hors diagnostic | `operationProfiling` dans `/etc/mongod.conf` (partie 2.7) |
| Rotation du journal par l'outil du système | `logRotate: reopen` et `/etc/logrotate.d/mongod`, 14 jours compressés (partie 2.8) |
| Index conçus d'après les requêtes de l'application | règle ESR, vérification par `explain` (partie 2.5) |
| Supervision continue et alertes sur les symptômes | exporteur, Prometheus (rétention 15 jours, 2 Go), 5 règles d'alerte, Grafana provisionné |
| Services de supervision non exposés | écoute sur `127.0.0.1` uniquement, inscription désactivée dans Grafana, images à version fixe |
| À faire en production, au-delà du TP | serveur de supervision dédié ; Alertmanager pour l'envoi des alertes ; HTTPS et authentification devant Grafana et Prometheus ; seuils d'alerte ajustés après observation ; centralisation des journaux |

---

## Annexe A – Dépannage

| Symptôme | Cause probable | Solution |
| --- | --- | --- |
| `00-prerequis.sh` : mémoire disponible insuffisante | cluster du chapitre 7 en marche, ou applications ouvertes | `bash ~/bd511/ch07/cluster.sh arreter` ; fermez Compass |
| `00-prerequis.sh` : port 9216, 9090 ou 3000 déjà utilisé | autre service sur ce port, ou supervision déjà démarrée | `sudo ss -ltnp 'sport = :9090'` pour l'identifier ; `cd ~/BD511/supervision && sudo docker compose ps` |
| `comptes.sh` : `Authentication failed` | contrôle d'accès activé, compte ou mot de passe administrateur erroné | relancez le script avec le compte du chapitre 5 |
| `comptes.sh` : `not authorized on admin to execute command { createUser` | le compte administrateur n'a pas le rôle `userAdminAnyDatabase` | utilisez un compte `root` |
| `mongosh-bd511` : `No such file … secrets/diag.pwd` | partie 0.2 non faite | `bash ~/BD511/ch08/comptes.sh` |
| `sha256sum` : `ventes.json: FAILED` | fichier modifié ou incomplet | régénérez-le (partie 0.4) ou décompressez celui de l'archive : `gunzip -k ventes.json.gz` |
| Clients de charge : `erreur (…) : Authentication failed` | mot de passe de `charge` modifié depuis le démarrage | `charge.sh arreter`, puis `demarrer` |
| `charge.sh demarrer` : `Charge déjà démarrée` | clients encore actifs | `bash ~/BD511/ch08/charge.sh arreter` |
| La fiche client reste rapide en partie 1 | index `client_1_date_-1` déjà créé (TP repris) | `~/BD511/ch08/mongosh-bd511 --eval 'db.ventes.dropIndex("client_1_date_-1")'` |
| `jq: error … Cannot index string with string "msg"` | journal de `mongod` en texte, ou fichier compressé | utilisez `/var/log/mongodb/mongod.log` (JSON depuis MongoDB 4.4) |
| `config-mongod.sh` : erreur de `mongod --outputConfig` | `/etc/mongod.conf` modifié à la main depuis le chapitre 2 | corrigez la ligne signalée ; l'original est dans `/etc/mongod.conf.avant-ch08` |
| `mongod` ne redémarre pas après `config-mongod.sh` | fichier de configuration invalide | `sudo journalctl -u mongod -n 20` ; `sudo cp /etc/mongod.conf.avant-ch08 /etc/mongod.conf` |
| `docker compose pull` : `toomanyrequests` | limite de téléchargements anonymes de Docker Hub | `sudo docker login`, ou attendez quelques heures |
| `up --wait` : `prometheus is unhealthy` | erreur dans `prometheus.yml` ou `alertes.yml` | `sudo docker compose logs prometheus` ; `promtool check config` (partie 3.5) |
| `up --wait` : `grafana is unhealthy`, journal `permission denied … /run/secrets/grafana_admin` | droits du fichier secret | refaites le `chown 472` et le `chmod 440` de la partie 3.2, puis `sudo docker compose up -d --wait` |
| Exporteur : `mongodb_up 0`, journal `Authentication failed` | mot de passe de `exporteur` changé depuis la création de `exporteur.env` | refaites la partie 3.2, puis `sudo docker compose up -d --force-recreate mongodb-exporter` |
| Cible `mongodb` à l'état `down` | exporteur arrêté | `sudo docker compose logs mongodb-exporter` |
| Grafana : identifiants refusés | mot de passe changé après le premier démarrage (il n'est lu qu'à la création de la base de Grafana) | `sudo docker compose down -v` puis `up -d --wait` (repart de zéro) |
| Panneaux « No data » | moins de deux collectes depuis le démarrage, ou période affichée trop ancienne | attendez 30 s ; période « Last 15 minutes » |
| L'alerte ne se déclenche pas en partie 3.9 | application arrêtée, ou index non masqué | `charge.sh etat` ; vérifiez `db.ventes.getIndexes()` (champ `hidden`) |

## Annexe B – Fichiers du TP

| Fichier | Rôle | Partie |
| --- | --- | --- |
| `~/BD511/ch08/00-prerequis.sh` | Contrôle de la VM | 0.1 |
| `~/BD511/ch08/comptes.sh` | Création des comptes `diag`, `charge`, `exporteur` | 0.2 |
| `~/BD511/ch08/secrets/` | Mots de passe (`*.pwd`) et fichiers `--config` des Database Tools (`*.yaml`) | 0.2 |
| `~/BD511/ch08/mongosh-bd511` | Connexion à `bd511` avec un compte du TP | 0.3 |
| `~/BD511/ch08/generer_ventes.py` | Générateur déterministe du million de ventes | 0.4 |
| `~/BD511/ch08/donnees/SHA256SUMS`, `ventes.json` | Empreinte de référence et jeu de données | 0.4 |
| `~/BD511/ch08/importer-ventes.sh` | Import des ventes, compte `charge` | 0.4 |
| `~/BD511/ch08/client-charge.js`, `charge.sh` | Application simulée : un client ; démarrage, état, arrêt de N clients | 1.1 |
| `~/BD511/ch08/diagnostic.js` | Débits et indicateurs calculés à partir de `serverStatus` | 1.5 |
| `~/BD511/ch08/rapport-lent.js` | Rapport incontrôlé de l'analyste | 1.6 |
| `~/BD511/ch08/operations-longues.js` | Opérations actives au-delà d'un seuil (`$currentOp`) | 1.6 |
| `~/BD511/ch08/analyse-profil.js` | Synthèse du profiler par forme de requête | 2.2 |
| `~/BD511/ch08/plan-fiche-client.js` | Plan d'exécution résumé de la fiche client | 2.4 |
| `~/BD511/ch08/config-mongod.sh` | Réglages de production dans `/etc/mongod.conf` | 2.7 |
| `/etc/logrotate.d/mongod` | Rotation quotidienne du journal de `mongod` | 2.8 |
| `~/BD511/supervision/secrets/` | `exporteur.env`, `grafana_admin.pwd` | 3.2 |
| `~/BD511/supervision/prometheus/prometheus.yml`, `alertes.yml` | Collecte et règles d'alerte | 3.3 |
| `~/BD511/supervision/grafana/provisioning/` | Source de données et fournisseur de tableaux de bord | 3.4 |
| `~/BD511/supervision/generer-tableau-de-bord.py` | Générateur du tableau de bord `grafana/dashboards/bd511-mongodb.json` | 3.4 |
| `~/BD511/supervision/docker-compose.yml` | Projet Compose de la supervision | 3.5 |
| `~/BD511/supervision/indicateurs.sh`, `suivre-alertes.sh` | Indicateurs et alertes lus dans Prometheus | 3.8 |
| `~/BD511/ch08/verifier-ch08.sh` | Contrôle final | 4.1 |

## Annexe C – Exploiter la supervision et remettre la VM en état

| Action | Commande |
| --- | --- |
| État des conteneurs | `cd ~/BD511/supervision && sudo docker compose ps` |
| Journaux d'un service | `sudo docker compose logs --tail 20 prometheus` |
| Recharger la configuration de Prometheus après modification | `sudo docker compose kill -s SIGHUP prometheus` |
| Arrêter, redémarrer la supervision | `sudo docker compose stop`, `sudo docker compose up -d --wait` |
| Mémoire occupée par les conteneurs | `sudo docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'` |
| Espace occupé par Prometheus | `sudo docker system df -v \| grep prometheus-donnees` |
| Les 5 opérations les plus lentes du journal | `sudo jq -s -c 'map(select(.msg == "Slow query")) \| sort_by(.attr.durationMillis) \| .[-5:][] \| {ms: .attr.durationMillis, ns: .attr.ns, app: .attr.appName}' /var/log/mongodb/mongod.log` |

**Repartir de zéro (note formateur).** Les commandes suivantes suppriment la supervision et ses données, la collection `ventes`, les comptes du TP, et rétablissent la configuration de `mongod` d'avant le chapitre. Si le contrôle d'accès est activé, ajoutez `--username admin` (compte administrateur du chapitre 5) à la quatrième commande : mongosh demande alors le mot de passe.

```bash
cd ~/BD511/supervision && sudo docker compose down -v
bash ~/BD511/ch08/charge.sh arreter
~/BD511/ch08/mongosh-bd511 --quiet --eval 'db.ventes.drop(); db.system.profile.drop()'
mongosh --quiet "mongodb://127.0.0.1:27017/admin" --eval '["diag", "charge", "exporteur"].forEach(u => db.dropUser(u))'
sudo cp /etc/mongod.conf.avant-ch08 /etc/mongod.conf && sudo rm /etc/mongod.conf.avant-ch08 /etc/logrotate.d/mongod
sudo systemctl restart mongod
rm -rf ~/BD511/ch08/secrets ~/BD511/supervision/secrets
```

Reprenez ensuite à la partie 0.2.

## Annexe D – Références

- Outils de diagnostic : [mongostat](https://www.mongodb.com/docs/database-tools/mongostat/), [mongotop](https://www.mongodb.com/docs/database-tools/mongotop/), [serverStatus](https://www.mongodb.com/docs/manual/reference/command/serverStatus/), [$currentOp](https://www.mongodb.com/docs/manual/reference/operator/aggregation/currentOp/), [killOp](https://www.mongodb.com/docs/manual/reference/command/killOp/), [defaultMaxTimeMS](https://www.mongodb.com/docs/manual/reference/cluster-parameters/defaultMaxTimeMS/)
- Requêtes lentes : [Database Profiler](https://www.mongodb.com/docs/manual/tutorial/manage-the-database-profiler/), [Log Messages](https://www.mongodb.com/docs/manual/reference/log-messages/), [Query Shapes](https://www.mongodb.com/docs/manual/core/query-shapes/), [explain Results](https://www.mongodb.com/docs/manual/reference/explain-results/), [The ESR Rule](https://www.mongodb.com/docs/manual/tutorial/equality-sort-range-guideline/), [Hidden Indexes](https://www.mongodb.com/docs/manual/core/index-hidden/)
- Configuration : [Configuration File Options (`operationProfiling`, `systemLog.logRotate`)](https://www.mongodb.com/docs/manual/reference/configuration-options/), [Rotate Log Files](https://www.mongodb.com/docs/manual/tutorial/rotate-log-files/), [WiredTiger Storage Engine (cache)](https://www.mongodb.com/docs/manual/core/wiredtiger/), [Production Notes](https://www.mongodb.com/docs/manual/administration/production-notes/)
- Supervision : [percona/mongodb_exporter](https://github.com/percona/mongodb_exporter) ([droits requis](https://github.com/percona/mongodb_exporter#permissions)), [Prometheus : configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/), [règles d'alerte](https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/), [API HTTP](https://prometheus.io/docs/prometheus/latest/querying/api/), [Grafana : provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/), [configuration par variables d'environnement et `__FILE`](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/#override-configuration-with-environment-variables), [Docker Compose : secrets](https://docs.docker.com/compose/how-tos/use-secrets/)
- Version : [Release Notes for MongoDB 8.3](https://www.mongodb.com/docs/manual/release-notes/8.3/)
