# Scope — Spec v0.2

> App macOS native, open-source. Une salle de contrôle pour agents de code en ligne de commande : tu déclares un dossier comme *scope*, tu y lances des *threads* (Claude Code, Codex, Cursor, n'importe quel *driver*), chaque *task* travaille dans une *sandbox* isolée, la *base* reste intacte, et tu vois le *delta* de n'importe quel repo à tout moment.

Convention d'écriture : **Scope** (majuscule) désigne l'app, *scope* (minuscule) désigne un dossier déclaré.

---

## 1. Vision et principes

**Problème.** Travailler avec des agents de code sur plusieurs repos aujourd'hui, c'est N terminaux ouverts à la main, des `git worktree` tapés de tête, une `main` qui finit salie par une session, et aucun endroit où voir *ce qui a changé, où, par quel agent*.

**Scope** s'instancie sur n'importe quel dossier, lance des agents dans des terminaux embarqués, isole chaque task dans des worktrees, et montre en permanence la carte des repos, les diffs et l'état de la branche stable.

**Principes**

1. **Driver agnostic.** Le terminal lance un binaire, point. Claude Code, Codex, Cursor ou un shell nu sont des profils. Tout ce qui est spécifique à un driver est un adaptateur optionnel.
2. **Aucune structure imposée.** Un scope est n'importe quel dossier : une org GitHub clonée, un dossier de projets, un seul repo. Scope n'écrit rien dedans par défaut.
3. **La base est intouchable.** Aucun agent n'écrit dans le checkout principal. Les tasks vivent dans des sandboxes.
4. **Git est l'API.** Deltas, branches, worktrees : Scope orchestre `git`, ne le remplace pas.
5. **Le terminal est l'interface de l'agent.** Pas de chat UI, pas de wrapper. Scope ajoute du contexte autour, pas au milieu.
6. **Natif, rapide, lisible.** SwiftUI/AppKit, zéro Electron, zéro serveur, un code qu'un contributeur peut lire en une soirée.

---

## 2. Lexique et modèle de domaine

| Terme | Définition | Exemple |
|---|---|---|
| **Scope** | Un dossier déclaré par l'utilisateur. Contient 1..n repos git, ou est lui-même un repo | `~/contributions/acme/`, `~/dev/mon-projet/` |
| **Repo** | Un dépôt git découvert dans un scope (profondeur 1 par défaut, réglable) | `acme/api`, `acme/web` |
| **Base** | Le checkout principal d'un repo, sur sa branche par défaut. Lecture, vérification, shell perso. Jamais touché par un agent | `~/contributions/acme/api/` sur `main` |
| **Graph** | Cache structuré décrivant chaque repo du scope : rôle, stack, points d'entrée, relations, commandes de setup et de test | `~/.scope/graph/acme.json` |
| **Driver** | Profil déclaratif d'un agent CLI : commande, args, env, fichier de contexte, adaptateur | `claude`, `codex`, `cursor-agent`, `zsh` |
| **Thread** | Un driver qui tourne dans un PTY, attaché à un scope et optionnellement à une task. Long, interruptible, reprenable | "Codex · acme · auth-refresh" |
| **Task** | Unité de travail nommée, sur 1..n repos d'un scope. Chaque repo impliqué reçoit une sandbox | `auth-refresh` → sandboxes sur `api` et `web` |
| **Sandbox** | `git worktree` d'un repo sur la branche de la task. Isole le *code*, pas le process : l'agent garde son accès disque et réseau | `~/.scope/sandboxes/acme/auth-refresh/api/` |
| **Delta** | Le diff, agrégé sur les repos d'une task ou vu repo par repo | — |

**Relations.** Un scope a des repos, des tasks et des threads. Une task a une sandbox par repo impliqué et 0..n threads. Un thread a un driver et un cwd (la task, ou la racine du scope). Deux scopes peuvent se chevaucher (un repo d'une org déclaré aussi comme scope seul) : c'est autorisé, Scope ne juge pas la structure.

**Kinds de scope**, détectés automatiquement :

- *Repo scope* : le dossier est un repo git. Les tasks portent sur ce seul repo.
- *Multi-repo scope* : le dossier contient des repos. Les tasks choisissent leurs repos.
- Un repo qui contient des repos imbriqués (submodules, vendoring) est un repo scope avec repos secondaires listés dans le graph.

---

## 3. Arborescence sur disque

Scope ne touche pas au dossier de l'utilisateur. Tout ce qu'il produit vit dans un dossier home, court et sans espace pour rester agréable dans un terminal.

```
~/.scope/                              # SCOPE_HOME, surchargeable
  config.json                          # scopes déclarés, préférences, éditeur
  drivers/*.json                       # profils de driver (les built-in sont copiés ici, éditables)
  graph/<scope-slug>.json              # graph par scope (cache)
  sandboxes/<scope-slug>/<task-slug>/  # racine de task = cwd du thread (multi-repo)
    AGENTS.md                          # projection du graph + périmètre de la task
    <task-slug>.code-workspace         # multi-root pour Cursor / VS Code
    api/                               # sandbox = worktree, branche scope/auth-refresh
    web/
  threads/<thread-id>.json             # driver, cwd, id de reprise, logs
  scope.sock                           # socket unix pour les adaptateurs

~/Library/Application Support/Scope/   # état purement UI (fenêtres, splits, onglets)
```

Option par scope : *sandboxes à côté des repos* (`<scope>/.scope/sandboxes/`), pour ceux qui préfèrent des chemins relatifs courts. Désactivée par défaut.

---

## 4. Fonctionnalités

### 4.1 Scopes

- **Déclarer un scope** : glisser un dossier sur l'app, `⌘O`, ou depuis le Finder (extension "Ouvrir dans Scope"). Aucune racine, aucune hiérarchie : la sidebar liste les scopes déclarés, dans l'ordre choisi.
- **Découverte** : Scope repère les repos (dossiers contenant `.git`) à profondeur 1, réglable par scope. Le remote `origin` sert à afficher `owner/repo` et à détecter les orgs.
- **Watcher** FSEvents sur chaque scope + rafraîchissement manuel.
- **Repos distants non clonés** : si le scope correspond à une org GitHub et que `gh` est présent, `gh repo list <org>` alimente le graph avec des repos grisés et un bouton *Cloner*.
- Retirer un scope ne supprime rien sur le disque, sauf demande explicite pour ses sandboxes.

### 4.2 Threads

- **Créer** : choisir un driver et un cwd. Par défaut, une task (l'agent voit uniquement ses sandboxes). Sinon la racine du scope (l'agent voit les bases : à utiliser pour explorer, pas pour modifier).
- **Terminal embarqué** : PTY complet (SwiftTerm), 256 couleurs, resize, copier/coller, scrollback, recherche. Onglets par thread, splits horizontaux et verticaux.
- **Environnement injecté** : `SCOPE_THREAD`, `SCOPE_SCOPE`, `SCOPE_TASK`, `SCOPE_SOCK`, `SCOPE_HOME`, plus l'env du profil de driver.
- **États** : `idle` · `running` · `waiting` (attend une réponse ou une permission) · `done` (tour fini, pas encore vu) · `failed` (tour arrêté sur une erreur de l'API) · `exited`. Montrer le thread ramène `done` et `failed` à `idle`. Sans adaptateur, seuls `running` et `exited` sont connus.
- **Reprise** : au redémarrage, les threads qui tournaient quand l'app s'est arrêtée (quit, mise à jour, crash, reboot) repartent seuls, en reprenant la session du driver quand elle est connue (commande de reprise du profil, ex. `claude --resume <id>`), sinon dans le même cwd. Le thread sélectionné part en premier, les autres sont échelonnés. Un thread dont le scope, la task ou le cwd a disparu reste arrêté et dit pourquoi. Réglage pour désactiver, opt-out par thread, ⇧ maintenu au lancement pour sauter une fois. Tout thread arrêté propose *Relancer* (qui reprend quand il peut) ou *Nouvelle session*.
- **Plusieurs drivers côte à côte** sur le même scope, y compris sur la même task.

### 4.3 Tasks et sandboxes

- **Créer une task** : nom → slug, choix des repos (pour un multi-repo scope ; suggestion depuis le graph : "quels repos pour *ajouter un refresh token* ?"), branche `scope/<slug>` (préfixe configurable) depuis la base à jour (`fetch` puis branche depuis `origin/<default>`).
- Pour chaque repo : `git -C <repo> worktree add <task-root>/<repo> -b scope/<slug> origin/<default>`, puis préparation de la sandbox, en arrière-plan, avant que le premier thread ne démarre (il attend) :
  1. **Copie des fichiers non versionnés** de la base vers la sandbox, par globs (`.env*` par défaut ; jokers dans le nom de fichier seulement). Refus de `..`, des chemins absolus, d'une source symlink qui sort de la base et d'une destination dont le chemin passe par un symlink ; un fichier déjà présent n'est jamais écrasé ; un fichier copié que le repo n'ignore pas est ajouté à `.git/info/exclude`.
  2. **Commande de setup** du repo (`pnpm i`, `bundle`, `make deps`) : le champ `setup` de la carte du graph, surchargé par repo dans la config du scope (`repoCommands` dans `config.json` : `setup`, `teardown`, `copyFiles` ; une chaîne vide désactive). Lancée avec `<shell> -c` dans la sandbox, avec l'environnement du shell de login plus `SCOPE_TASK`, `SCOPE_SCOPE`, `SCOPE_SANDBOX` (le worktree), `SCOPE_BASE_PATH` (le checkout principal), `SCOPE_DEFAULT_BRANCH` et `SCOPE_PORT`.
  - L'état du setup (`notRun` · `running` · `succeeded` · `failed` · `skipped`) et son log (borné à 64 Ko, la fin gardée) vivent sur le record de la task. Un échec va dans le Problem Center avec le log et *Relancer le setup*. Un setup interrompu par un quit est `failed` au lancement suivant.
  - Case *Lancer le setup* dans la feuille New Task ; `scope task new --no-setup`, `run_setup` côté MCP. Décochée, les fichiers sont copiés quand même.
- **Ports** : chaque task reçoit un bloc de 10 ports (41000–48999), stocké sur son record (stable au redémarrage), jamais partagé par deux tasks vivantes ; le premier est `SCOPE_PORT`, pour le setup comme pour les threads de la task.
- **Teardown** : le champ `teardown` (carte du graph, config du scope) tourne dans chaque sandbox avant *Archiver* et *Clôturer*, avec les mêmes variables et 10 minutes de délai. S'il échoue, la sandbox n'est pas supprimée et l'échec est montré ; l'utilisateur peut choisir de continuer sans.
- **Cwd du thread** : la sandbox elle-même si la task n'a qu'un repo (les drivers attendent une racine git), la racine de task sinon.
- **Ajouter un repo** à une task en cours : crée la sandbox manquante, régénère `AGENTS.md` et le `.code-workspace`.
- **Clôturer une task** : après merge, `worktree remove` + suppression de la branche locale ; ou *Archiver* (garde la branche, supprime la sandbox).
- **Garde-fous** : refus de supprimer une sandbox avec des changements non commités ; `git worktree prune` au démarrage ; avertissement si un repo a des submodules ou des hooks lourds (husky et consorts s'appliquent aux worktrees).

### 4.4 Delta

Panneau unique, indépendant du driver, agrégé sur les repos de la task.

- **Trois modes** : *Task* (branche vs `merge-base` avec la base), *Non commité* (working tree vs HEAD de la sandbox), *Base vs origin* (ma base est-elle en retard ?).
- **Vue** : fichiers groupés par repo avec compteurs `+/-`, rendu unifié ou côte à côte, coloration syntaxique, repli des hunks, navigation clavier (`j`/`k`, `]`/`[` par fichier).
- **Actions** : ouvrir dans l'éditeur sur la ligne du hunk, révéler dans le Finder, copier le patch, commit (message pré-rempli depuis la task), push, *Créer la PR* (`gh pr create`, corps pré-rempli), *Ouvrir la PR* si elle existe.
- Rafraîchissement : FSEvents sur les sandboxes + `git status` throttlé.

### 4.5 Base

- Pour n'importe quel repo du scope : arbre de fichiers de la base, visionneuse en lecture seule avec coloration, recherche plein texte (`rg`), historique récent.
- *Pull* (fast-forward uniquement) ; indicateur "en retard de N commits".
- *Ouvrir un shell ici* : un terminal secondaire, sans driver, dans la base. Pour lancer les tests sur `main`, comparer un comportement, etc.
- *Ouvrir dans l'éditeur*.

### 4.6 Graph

- **Par repo** : `name`, `remote`, `default_branch`, `purpose` (1–3 phrases), `stack`, `entrypoints`, `related` (dépend de / consommé par), `setup`, `test`, `tags`, `last_activity`.
- **Génération**, bouton *Analyser* :
  - Niveau 0, sans IA : README (premier paragraphe), manifestes (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`…), `git log` récent.
  - Niveau 1, avec IA : le driver par défaut en mode headless (`claude -p`, `codex exec`, `cursor-agent -p`) sur chaque repo, avec un prompt qui exige un JSON strict ; Scope valide le schéma avant d'écrire.
- **Cache** : clé = SHA de HEAD + hash du README + hash des manifestes. Édition manuelle possible et prioritaire sur la génération.
- **Vue** : cartes par repo en v1 ; une vue graphe des relations `related` quand le champ sera assez rempli pour la mériter.
- **Projection vers les drivers** : Scope écrit `AGENTS.md` (convention pivot, lue par Codex et Cursor) à la racine de task. Le profil Claude Code peut demander en plus un `CLAUDE.md` généré. Contenu : les repos de la task et leur rôle, les autres repos du scope avec leur rôle (pour que l'agent sache demander à en ajouter un), les règles (branche, ne pas toucher à la base).
- **Où** : le fichier est écrit là où démarrent les threads de la task — la sandbox quand la task n'a qu'un repo (y compris le cas mono-repo, où la racine de task *est* la sandbox), la racine sinon. Ailleurs, le driver ne le lit jamais.
- **Sous quels noms** : tous ceux que les profils déclarent (`context.file`, sauf `mode: none`), `AGENTS.md` toujours inclus — les threads d'une même task peuvent tourner sous des drivers différents. Même contenu dans chacun.
- **Fichier existant** : jamais écrasé, sauf s'il porte le marqueur de génération de Scope. Le nom laissé de côté est signalé dans le Problem Center : un agent qui démarre sans son contexte doit se voir.
- **Dans une sandbox** : chaque fichier écrit est ajouté à `.git/info/exclude`, donc le delta reste propre (décision ouverte 6 tranchée : fichier + exclude, tant qu'aucun driver n'expose de flag de contexte).

### 4.7 Adaptateurs et notifications

Un adaptateur transforme les événements d'un driver en états de thread. Mécanisme unique : le driver exécute une commande sur événement, cette commande est `scope-hook`, un binaire embarqué qui écrit `{thread, event, payload}` sur `scope.sock`.

- **Événements normalisés** : `turn.started`, `turn.ended`, `input.requested`, `permission.requested`, `thread.ended`.
- **Notifications macOS** sur `input.requested`, `permission.requested`, `turn.ended` si l'app n'est pas au premier plan, avec actions *Aller au thread* / *Voir le delta*. Badge = threads en attente.
- **Sans adaptateur** : `running` tant que le process vit ; heuristique regex sur la sortie, désactivée par défaut.
- Les adaptateurs sont déclarés dans les profils de driver, donc extensibles sans recompiler.

### 4.8 Ouvrir dans l'éditeur

Geste de premier rang, partout, toujours sur le **bon checkout** : la sandbox si on part d'une task ou d'un thread, la base si on part de la vue Base.

- **Éditeur par défaut** : détecté au premier lancement (Cursor, VS Code, Zed, Sublime, JetBrains, Nova), réglable. Chaque éditeur est un template : `cursor {path}`, `code -g {file}:{line}`, `zed {path}:{line}`, `open -a "Nova" {path}`. Template libre pour tout autre.
- **Cible résolue selon le contexte** : depuis un thread ou une ligne de task → `<task-root>/<repo>/` ; depuis Base → `<scope>/<repo>/` ; depuis un fichier du Delta → la sandbox, sur le fichier et la ligne ; depuis le Graph → sélecteur si le repo a plusieurs checkouts (base + N sandboxes), avec branche et état de chacun.
- **Task entière** : ouvre `<task-root>/<slug>.code-workspace` (un dossier par sandbox) pour Cursor / VS Code ; le dossier racine pour les autres.
- **Points d'entrée** : barre de titre du thread, clic droit sur un repo, icône sur chaque fichier du delta, palette, `⌘E` (repo courant), `⌘⇧E` (task entière). `⌥`-clic copie le chemin.

---

## 5. Profils de driver (v1)

Les mécanismes d'événements changent vite : à vérifier contre la doc de chaque outil au moment de l'implémentation.

| | Claude Code | Codex CLI | Cursor CLI | Générique |
|---|---|---|---|---|
| Commande | `claude` | `codex` | `cursor-agent` | `$SHELL -l` |
| Contexte lu | `CLAUDE.md` | `AGENTS.md` | `AGENTS.md`, `.cursor/rules` | — |
| Projection | `CLAUDE.md` généré ou flag de contexte | `AGENTS.md` | `AGENTS.md` | `AGENTS.md` |
| Reprise | `claude --resume <id>` | `codex resume` | `cursor-agent --resume` | — |
| Événements | hooks (`Notification`, `Stop`, `UserPromptSubmit`) via settings de thread | `notify` via override `-c` | hooks `.cursor/hooks.json` | aucun |
| Headless (graph) | `claude -p --output-format json` | `codex exec` | `cursor-agent -p` | — |

```json
{
  "id": "claude-code",
  "name": "Claude Code",
  "command": "claude",
  "args": [],
  "env": {},
  "context": { "file": "CLAUDE.md", "mode": "generate" },
  "resume": ["claude", "--resume", "{thread_id}"],
  "headless": ["claude", "-p", "{prompt}", "--output-format", "json"],
  "adapter": { "kind": "claude-hooks" }
}
```

Un driver custom = un fichier JSON dans `~/.scope/drivers/`. Contribuer un driver au projet = ouvrir une PR avec ce fichier et, si besoin, un adaptateur.

---

## 6. Architecture technique

**Stack**

- Swift 6, SwiftUI pour l'app, AppKit là où SwiftUI ne suffit pas (terminal, splits, menus contextuels).
- **SwiftTerm** pour le PTY et le rendu terminal.
- Git par `Process` sur `/usr/bin/git`, pas de libgit2 : comportement identique à ce que tu tapes, hooks respectés. Un acteur `GitClient` sérialise les commandes par repo.
- `gh` optionnel pour PR et liste des repos d'org.
- Coloration : Highlightr, tree-sitter si le besoin de précision se confirme.
- Persistance : JSON sur disque, pas de base de données. Tout ce qui est visible depuis un terminal est dans `~/.scope/`.
- Notifications : `UserNotifications`. Watchers : FSEvents.
- Distribution : hors App Store (PTY + binaires arbitraires → pas de sandbox macOS), signé Developer ID + notarisé, Homebrew cask. Sparkle pour les mises à jour.
- Licence : à choisir (MIT ou Apache-2.0).

**Modules**

```
Scope
├── Scopes       déclaration, découverte des repos, watchers
├── Git          GitClient, worktrees, parser de diff
├── Drivers      profils, lancement PTY, env, reprise
├── Threads      état, onglets, cycle de vie
├── Tasks        création, sandboxes, AGENTS.md, .code-workspace, clôture
├── Graph        génération L0/L1, cache, projection
├── Adapters     socket unix, événements normalisés → états
├── UI           Sidebar, TerminalPane, Inspector (Graph / Delta / Base), Palette
└── scope-hook   binaire CLI embarqué, appelé par les hooks des drivers
```

**Garde-fous**

- `scope-hook` n'accepte que les événements portant un `SCOPE_THREAD` connu.
- Aucune commande git destructive sans confirmation (`worktree remove` avec changements, `branch -D`, `reset --hard`).
- Scope ne stocke aucun token : `gh` et les drivers gèrent leur propre auth.
- La protection de la base est une convention (les agents travaillent dans les sandboxes), pas une garantie système. La doc le dit clairement.

---

## 7. Interface

Détaillée en maquettes SVG à l'étape 3. Squelette :

- **Sidebar** : scopes → tasks → threads, pastille d'état par thread. Détail d'une task : une ligne par repo (branche, `+/-`, état de la sandbox) avec *Ouvrir dans l'éditeur* et *Voir le delta* au survol. En bas : *Nouveau thread*, *Nouvelle task*.
- **Scène** (centre) : onglets de terminaux, splits. Barre de titre : driver · scope · task · état · *Ouvrir dans l'éditeur*.
- **Inspecteur** (droite, masquable) : *Graph*, *Delta*, *Base*. Le Delta suit la task du thread actif.
- **Palette** `⌘K` : nouveau thread, nouvelle task, ajouter un repo à la task, ouvrir `<repo>` dans l'éditeur, ouvrir la task dans l'éditeur, analyser le graph, aller à un thread, déclarer un scope.
- **Raccourcis** : `⌘O` déclarer un scope, `⌘T` nouveau thread, `⌘⇧T` nouvelle task, `⌘E` / `⌘⇧E` éditeur, `⌘D` delta, `⌘⇧B` base, `⌘1..9` threads.
- **Menu bar extra** (optionnel) : threads en attente, accès rapide.

---

## 8. Non-objectifs v1

- Pas de chat UI, pas de wrapper autour des agents.
- Pas de client git complet (rebase interactif, conflits : on ouvre l'éditeur).
- Pas de sync cloud, pas de multi-utilisateur, pas de Linux/Windows.
- Pas d'orchestration entre threads (un thread ne pilote pas un autre).
- Pas de gestion de secrets, pas d'isolation process.
- CLI `scope` complète (déclarer un scope, lancer un thread depuis le terminal) : après v1, sur la base de `scope-hook`.

---

## 9. Jalons

| Jalon | Contenu | Testable quand |
|---|---|---|
| **M0 · Squelette** | Déclarer un scope, découverte des repos, sidebar, un terminal embarqué avec `$SHELL` | Je lance un shell dans un scope depuis l'app |
| **M1 · Threads** | Profils Claude Code / Codex / Cursor, env injecté, onglets, reprise | Je lance Codex et Claude côte à côte, je ferme, je reprends |
| **M2 · Tasks + Delta** | Création de task, sandboxes, `AGENTS.md`, `.code-workspace`, Delta 3 modes, commit/push/PR, éditeur | Une task multi-repo de bout en bout jusqu'à la PR, éditeur ouvert sur la bonne sandbox |
| **M3 · Graph + Base** | Génération L0 puis L1, cache, projection, vue Base avec shell secondaire | Le graph est juste, un nouvel agent sait où aller |
| **M4 · Adaptateurs** | `scope-hook`, socket, états, notifications, badge, palette | Je suis prévenu quand un thread attend, sans regarder |

---

## 10. Décisions ouvertes

1. **`~/.scope/` vs Application Support** pour tout ce qui est visible en terminal (proposé : `~/.scope/`, surcharge `SCOPE_HOME`).
2. **Emplacement des sandboxes** par défaut : `~/.scope/sandboxes/` (proposé) ou à côté des repos, en opt-in par scope.
3. **Cwd par défaut d'un thread** : task (proposé) ou racine du scope ?
4. **Nom de branche** : `scope/<slug>` ou `<user>/<slug>` ?
5. **Base de branche** : `origin/<default>` fraîchement fetché (proposé) ou la base locale ?
6. ~~**Projection mono-repo** : flag de contexte du driver, ou fichier + `.git/info/exclude` ?~~ Tranché : fichier + `exclude`, écrit dans le cwd des threads, sous chaque nom déclaré par les drivers ; un fichier que Scope n'a pas généré est laissé en place et signalé.
7. **Rendu du delta** : natif SwiftUI + parser (proposé, cohérent, plus long) ou `WKWebView` + diff2html (rapide, moins natif).
8. **Graph L1** : quel driver par défaut ? Coût et durée acceptables par repo ?
9. **Repos non clonés** : `gh` obligatoire, ou API GitHub avec token ?
10. ~~**Setup post-sandbox** : commande dans le graph (proposé) ou détection depuis les manifestes ?~~ Tranché : commande de la carte du graph (éditable), surchargeable par repo dans la config du scope, avec un `teardown` symétrique ; Scope n'écrit rien dans les repos pour ça.
11. **Scopes imbriqués** : autorisés (proposé) ou refusés ?
12. **Licence** : MIT ou Apache-2.0.
