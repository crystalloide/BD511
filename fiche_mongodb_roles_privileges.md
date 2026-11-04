# Fiche — MongoDB : rôles, privilèges et héritage

> **Objectif** : comprendre comment MongoDB contrôle les accès, savoir distinguer privilèges directs et hérités, et créer des rôles personnalisés simples.

---

## 1. Le principe

MongoDB applique le **contrôle d'accès basé sur les rôles** (RBAC) :

- **Par défaut, un utilisateur n'a aucun droit.**
- On lui accorde des droits en lui attribuant un ou plusieurs **rôles**.
- Un rôle regroupe des **privilèges**, et peut **hériter** d'autres rôles.

### L'analogie du trousseau

| Notion | Analogie | En MongoDB |
|---|---|---|
| **Privilège** | Une clé qui ouvre une porte précise | Une action autorisée sur une ressource |
| **Rôle** | Un trousseau de clés | Un ensemble de privilèges |
| **Héritage** | Un trousseau qui contient un autre trousseau | Un rôle qui inclut les privilèges d'un autre rôle |
| **Utilisateur** | La personne qui porte les trousseaux | Un compte auquel on attribue des rôles |

---

## 2. Le privilège = ressource + actions

Un privilège répond à deux questions : **OÙ ?** et **QUOI ?**

```js
{
  resource: { db: "boutique", collection: "commandes" },  // OÙ
  actions: [ "find", "insert" ]                            // QUOI
}
```

### Portée des ressources

| Ressource | Signification |
|---|---|
| `{ db: "boutique", collection: "commandes" }` | Une collection précise |
| `{ db: "boutique", collection: "" }` | Toutes les collections de la base `boutique` |
| `{ db: "", collection: "" }` | Toutes les collections de toutes les bases |
| `{ cluster: true }` | Opérations sur le serveur (ex. `shutdown`, `replSetGetStatus`) |

### Quelques actions courantes

| Action | Permet de… |
|---|---|
| `find` | Lire des documents |
| `insert` | Insérer des documents |
| `update` | Modifier des documents |
| `remove` | Supprimer des documents |
| `createCollection` | Créer une collection |
| `createIndex` | Créer un index |

---

## 3. Les rôles prédéfinis (built-in)

| Rôle | Ce qu'il permet |
|---|---|
| `read` | Lire les données d'une base |
| `readWrite` | Lire et écrire dans une base |
| `dbAdmin` | Administrer une base (index, statistiques) — **ne donne pas accès aux données** |
| `userAdmin` | Gérer les utilisateurs et rôles d'une base |
| `dbOwner` | Réunit `readWrite` + `dbAdmin` + `userAdmin` |
| `readAnyDatabase` | `read` sur toutes les bases |
| `readWriteAnyDatabase` | `readWrite` sur toutes les bases |
| `clusterAdmin` | Administration du cluster |
| `root` | Tous les droits sur tout |

> 💡 `dbOwner` est lui-même un exemple d'héritage : il combine trois autres rôles.

### Exemple 1 — Utilisateur en lecture seule

```js
use boutique
db.createUser({
  user: "lecteur",
  pwd: "secret",
  roles: [ { role: "read", db: "boutique" } ]
})
```

➡️ `lecteur` peut faire des `find` sur toutes les collections de `boutique`. Rien d'autre.

---

## 4. Privilèges directs vs privilèges hérités

Un rôle personnalisé se définit avec **deux tableaux** :

```js
db.createRole({
  role: "nomDuRole",
  privileges: [ ... ],   // privilèges DIRECTS (définis dans ce rôle)
  roles: [ ... ]         // rôles dont il HÉRITE
})
```

| Type | D'où il vient |
|---|---|
| **Privilège direct** | Déclaré dans le tableau `privileges` du rôle |
| **Privilège hérité** | Apporté par un rôle listé dans le tableau `roles` |
| **Privilège effectif** | Direct + hérité : ce que le rôle permet réellement |

### Exemple 2 — Rôle sans héritage

```js
use boutique
db.createRole({
  role: "lectureCommandes",
  privileges: [
    { resource: { db: "boutique", collection: "commandes" }, actions: ["find"] }
  ],
  roles: []    // aucun héritage
})
```

➡️ Un seul privilège, **direct** : lire `commandes`.

### Exemple 3 — Rôle qui hérite et ajoute ses propres privilèges

```js
db.createRole({
  role: "gestionCommandes",
  privileges: [
    { resource: { db: "boutique", collection: "commandes" }, actions: ["insert", "update"] }
  ],
  roles: [ "lectureCommandes" ]
})
```

| | Privilèges sur `commandes` |
|---|---|
| Directs | `insert`, `update` |
| Hérités | `find` (de `lectureCommandes`) |
| **Effectifs** | **`find`, `insert`, `update`** |

### Exemple 4 — Chaîne d'héritage

```js
db.createRole({
  role: "responsable",
  privileges: [],
  roles: [ "gestionCommandes", { role: "read", db: "boutique" } ]
})
```

```
responsable
 ├── gestionCommandes
 │     ├── (direct) insert, update sur commandes
 │     └── lectureCommandes
 │           └── (direct) find sur commandes
 └── read (sur boutique)
```

➡️ L'héritage est **transitif** : `responsable` obtient aussi le `find` de `lectureCommandes`, même s'il n'en hérite qu'indirectement.

### Attribuer le rôle à un utilisateur

```js
db.createUser({
  user: "alice",
  pwd: "secret",
  roles: [ "responsable" ]
})
```

---

## 5. Les pièges à connaître

### ⚠️ L'héritage est dynamique

Modifier un rôle parent modifie **immédiatement** tous les rôles qui en héritent.

```js
db.grantPrivilegesToRole("lectureCommandes", [
  { resource: { db: "boutique", collection: "produits" }, actions: ["find"] }
])
// gestionCommandes et responsable peuvent maintenant lire "produits"
```

### ⚠️ Les privilèges s'additionnent — il n'existe pas d'interdiction

- On ne peut pas écrire « hérite de `read` **sauf** la collection `salaires` ».
- Pour restreindre, il faut construire un rôle plus fin, **sans** hériter du rôle trop large.

### ⚠️ Les droits d'un utilisateur = l'union de tous ses rôles

Un utilisateur qui a `lectureCommandes` **et** `readWrite` sur `boutique` peut écrire partout dans `boutique` : c'est le rôle le plus permissif qui l'emporte.

### ⚠️ La portée d'un rôle dépend de sa base de création

| Rôle créé dans… | Privilèges possibles | Peut hériter de… |
|---|---|---|
| Une base quelconque (ex. `boutique`) | Uniquement sur cette base | Uniquement des rôles de cette base |
| La base `admin` | Sur n'importe quelle base et sur le cluster | Des rôles de n'importe quelle base |

### ⚠️ `inheritedPrivileges` ne contient pas que les hérités

```js
db.getRole("gestionCommandes", { showPrivileges: true })
```

| Champ du résultat | Contenu |
|---|---|
| `privileges` | Privilèges **directs** uniquement (`insert`, `update`) |
| `inheritedRoles` | Rôles hérités (`lectureCommandes`) |
| `inheritedPrivileges` | **Tous** les privilèges effectifs, directs **et** hérités (`find`, `insert`, `update`) |

---

## 6. Mémo des commandes

| Commande | Usage |
|---|---|
| `db.createUser({...})` | Créer un utilisateur avec ses rôles |
| `db.createRole({...})` | Créer un rôle personnalisé |
| `db.grantRolesToUser("user", [...])` | Ajouter des rôles à un utilisateur |
| `db.revokeRolesFromUser("user", [...])` | Retirer des rôles à un utilisateur |
| `db.grantPrivilegesToRole("role", [...])` | Ajouter des privilèges directs à un rôle |
| `db.revokePrivilegesFromRole("role", [...])` | Retirer des privilèges directs d'un rôle |
| `db.grantRolesToRole("role", [...])` | Ajouter un héritage à un rôle |
| `db.revokeRolesFromRole("role", [...])` | Retirer un héritage d'un rôle |
| `db.getRole("role", { showPrivileges: true })` | Afficher un rôle et ses privilèges |
| `db.getUser("user", { showPrivileges: true })` | Afficher un utilisateur et ses privilèges |
| `db.runCommand({ connectionStatus: 1, showPrivileges: true })` | Voir les droits de l'utilisateur connecté |

---

## ✅ À retenir

1. **Privilège** = une action sur une ressource.
2. **Rôle** = un ensemble de privilèges, éventuellement complété par héritage.
3. **Direct** = déclaré dans `privileges` ; **hérité** = apporté par `roles`.
4. L'héritage est **transitif** et **dynamique**.
5. Les droits **s'additionnent** : pas de privilège négatif.
6. Un rôle multi-bases ou cluster se crée dans **`admin`**.
