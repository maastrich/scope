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
    api/                               # sandbox = worktree, branche feat/auth-refresh
    web/
  threads/<thread-id>.json             # driver, cwd, id de reprise, logs
  usage/usage-YYYY-MM.jsonl            # journal local d'usage de l'app (ids seulement, 180 jours)
  usage/registry.json                  # tout élément instrumenté : id, libellé, zone
  scope.sock                           # socket unix pour les adaptateurs

~/Library/Application Support/Scope/   # état purement UI (fenêtres, splits, onglets)
```

Option par scope : *sandboxes à côté des repos* (`<scope>/.scope/sandboxes/`), pour ceux qui préfèrent des chemins relatifs courts. Désactivée par défaut.

---

## 4. Fonctionnalités

### 4.1 Scopes

- **Déclarer un scope** : `⌘O`, ou depuis le Finder (extension "Ouvrir dans Scope"). Pas de glisser-déposer : un drop dans la fenêtre va au terminal, qui insère le chemin sur la ligne de commande. Aucune racine, aucune hiérarchie : la sidebar liste les scopes déclarés, dans l'ordre choisi.
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
- **Threads résidents** : chaque scope déclaré garde à sa racine un *orchestrateur* (un agent — préférence *Orchestrator driver*, automatique = driver par défaut puis premier agent installé) et un *terminal* (le shell). Ce sont des threads ordinaires marqués d'un rôle (`ThreadRecord.resident`), créés par Scope — à la déclaration, au lancement, et rétroactivement pour les scopes existants. On ne peut pas les fermer (⌘W, bouton, menu, `thread close` refusent) ; ils partent avec leur scope. *Stop* reste permis et les laisse arrêtés jusqu'à *Relancer* ou jusqu'au prochain lancement de Scope (⇧ au lancement pour prolonger). Un processus qui meurt seul est relancé (crash → reprise de session, sortie propre → nouvelle session) avec un délai croissant ; trois sorties rapides d'affilée (< 10 s) ou un exit 127 et Scope abandonne en le signalant. Ils démarrent à la première visite du scope (ceux du scope ouvert au lancement), pas tous au démarrage ; un message envoyé à l'un le démarre. ⇧ au lancement les laisse arrêtés. Dossier du scope absent : arrêtés, repartent à la visite suivante une fois le dossier revenu. Dans la sidebar ils sont en tête (⌘1, ⌘2), hors *Loose threads*, et ne changent pas de groupe en mode *By state*.
- **Plusieurs drivers côte à côte** sur le même scope, y compris sur la même task.

### 4.3 Tasks et sandboxes

- **Créer une task** : nom → slug, choix des repos (pour un multi-repo scope ; suggestion depuis le graph : "quels repos pour *ajouter un refresh token* ?"), branche proposée d'après la convention du repo (le driver en headless lit les branches et les commits récents ; à défaut, préfixe dominant ou `feat/`/`fix/`, sinon le slug nu), depuis la base à jour (`fetch` puis branche depuis `origin/<default>`). Le préfixe `scope/` est réservé à Scope et refusé, avec la marche à suivre : omettre la branche, ou un autre préfixe comme `feat/`. La préférence `branchPrefix` n'est plus lue.
- **Partir d'une pull request** : sa tête est checkoutée au lieu d'une nouvelle branche. Explicite (`scope task new --pr <ref>`, `start_pr` côté MCP), elle doit se résoudre, sinon la création échoue. Sinon, seule une PR que le prompt demande de travailler compte — le prompt n’est guère que la référence ou s’ouvre sur une ligne qui l’est, ou une phrase s'ouvre sur un verbe d'action qui la vise (« review #123 », « rebase la pr <url> ») ; une PR citée pour contexte dans un brief n'est pas un point de départ. Une PR ainsi lue qui ne se résout pas dans le scope (autre repo, inexistante) est ignorée : la task part d'une nouvelle branche et la réponse le dit en une ligne.
- Pour chaque repo : `git -C <repo> worktree add <task-root>/<repo> -b <branche> origin/<default>`, puis préparation de la sandbox, en arrière-plan, avant que le premier thread ne démarre (il attend) :
  1. **Copie des fichiers non versionnés** de la base vers la sandbox, par globs (`.env*` par défaut ; jokers dans le nom de fichier seulement). Refus de `..`, des chemins absolus, d'une source symlink qui sort de la base et d'une destination dont le chemin passe par un symlink ; un fichier déjà présent n'est jamais écrasé ; un fichier copié que le repo n'ignore pas est ajouté à `.git/info/exclude`.
  2. **Commande de setup** du repo (`pnpm i`, `bundle`, `make deps`) : le champ `setup` de la carte du graph, surchargé par repo dans la config du scope (`repoCommands` dans `config.json` : `setup`, `teardown`, `copyFiles` ; une chaîne vide désactive). Lancée avec `<shell> -c` dans la sandbox, avec l'environnement du shell de login plus `SCOPE_TASK`, `SCOPE_SCOPE`, `SCOPE_SANDBOX` (le worktree), `SCOPE_BASE_PATH` (le checkout principal), `SCOPE_DEFAULT_BRANCH` et `SCOPE_PORT`.
  - L'état du setup (`notRun` · `running` · `succeeded` · `failed` · `skipped`) et son log (borné à 64 Ko, la fin gardée) vivent sur le record de la task. Un échec va dans le Problem Center avec le log et *Relancer le setup*. Un setup interrompu par un quit est `failed` au lancement suivant.
  - Case *Lancer le setup* dans la feuille New Task ; `scope task new --no-setup`, `run_setup` côté MCP. Décochée, les fichiers sont copiés quand même.
- **Ports** : chaque task reçoit un bloc de 10 ports (41000–48999), stocké sur son record (stable au redémarrage), jamais partagé par deux tasks vivantes ; le premier est `SCOPE_PORT`, pour le setup comme pour les threads de la task.
- **Teardown** : le champ `teardown` (carte du graph, config du scope) tourne dans chaque sandbox avant *Archiver* et *Clôturer*, avec les mêmes variables et 10 minutes de délai. S'il échoue, l'échec est montré et la suppression continue : le sweep de process qui suit arrête ce qu'il devait arrêter.
- **Cwd du thread** : la sandbox elle-même si la task n'a qu'un repo (les drivers attendent une racine git), la racine de task sinon.
- **Ajouter un repo** à une task en cours : crée la sandbox manquante, régénère `AGENTS.md` et le `.code-workspace`.
- **Archiver / clôturer une task** (`TaskManager.dismantle`, un seul pipeline pour l'UI, la CLI, le MCP, le Retry et le GC) : verrou par task (un second appel rejoint celui en cours), record persisté après chaque étape avec `cleanup` jusqu'à la fin. Ordre : threads raccrochés (groupe de process), teardown, sweep des process (cwd sous la racine de la task ou `SCOPE_TASK_ROOT`, SIGTERM puis SIGKILL après 3 s), sauvegarde des changements non commités, worktree renommé dans `sandboxes/.trash` et son dossier `.git/worktrees/<nom>` supprimé, racine supprimée. *Archiver* garde la branche et le record ; *Clôturer* supprime le record, et la branche si demandé.
- **Rien ne se perd, rien ne demande** : aucun dialogue. Les changements non commités (suivis et non suivis, ignorés exclus, non suivis de plus de 50 Mo exclus et nommés) sont commités via un index privé sous `refs/scope/salvage/<slug>-<id>/changes-<time>` ; une branche non mergée supprimée à la clôture garde son dernier commit de la même façon. *Restaurer* rouvre une task archivée avec ces changements — depuis la notice d'archivage, la palette, ou par un agent (`scope task restore <slug>`, `scope_task_restore` ; `scope list` marque les tasks archivées). Pour un agent, restaurer compte dans son budget de tasks et suit la même approbation qu'en créer une. Un échec laisse la task hors de la sidebar, avec *Réessayer* ; le lancement suivant termine.
- **Pull requests en arrière-plan** : la PR de chaque task ouverte — liée, ou que sa branche pourrait porter (au moins un commit) — est relue toutes les 5 minutes par `gh pr view`, deux appels à la fois, l'ordre étalé sur l'intervalle, un échec doublant l'attente (jusqu'à 1 h), une PR mergée ou fermée relue toutes les 30 min ; rien en mode économie d'énergie. La task à l'écran garde sa boucle d'une minute. Planning pur et testé : `PullRequestRefreshSchedule`.
- **Archivage au merge** (préférence *Archive a task when its pull request merges*, activée par défaut) : quand une relecture voit la PR `merged` et qu'aucun thread de la task n'est en cours de tour, la task est archivée par le même pipeline que la sidebar, avec une seule notice discrète *Archived <task>: pull request merged* et *Restore*. Un thread en cours repousse à la relecture suivante. Une PR fermée sans merge n'archive jamais. Une task restaurée après son merge porte `keptOpenAfterMerge` et reste ouverte (`MergedTaskArchive`). Les agents n'ont plus à attendre le merge pour archiver.
- **Tasks dormantes** : une task ouverte sans activité de thread (fin de tour, outil, lancement, ou sa création) depuis N jours (préférence, 3 par défaut, *Never* possible), ou dont la PR a été fermée sans merge, porte une légende `idle 4d` / `PR closed` dans sa ligne et, rangée par état, va dans le groupe *Dormant* — sauf si elle attend l'utilisateur ou travaille (`TaskDormancy`).
- **GC automatique** (au lancement, toutes les 30 min, après chaque archivage ; préférence *Clean up automatically*) limité à `SCOPE_HOME` : process dont le cwd ou `SCOPE_TASK_ROOT` est sous `sandboxes/` hors task vivante, dossiers sans task (changements sauvés d'abord, grâce de 10 min, rien si un record est illisible), suppression des enregistrements git des seuls worktrees qui vivaient sous `sandboxes/` (jamais de `git worktree prune` global : il effacerait les worktrees de l'utilisateur sur un volume démonté), refs de salvage non référencées de plus de 30 jours. `scope gc [--dry-run]`.
- **Garde-fous** : avertissement si un repo a des submodules ou des hooks lourds (husky et consorts s'appliquent aux worktrees).

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
- **Quel repo est montré.** Dans l'ordre : le repo épinglé dans le contexte courant, la ligne de repo sélectionnée, le repo où travaille le thread affiché (le dossier annoncé par son shell, ou celui du dernier fichier touché par l'agent, remonté par ses hooks), le repo du fichier ouvert dans le Delta, le premier repo de la task, le dernier repo montré dans le scope, le premier du scope. Le panneau dit laquelle de ces raisons s'applique.
- **Épingle.** Choisir un repo dans l'en-tête l'épingle pour le contexte courant — la task, le thread libre ou le scope — et seulement pour lui. Elle est visible, se retire d'un clic, et survit au redémarrage.

### 4.6 Graph

- **Par repo** : `name`, `remote`, `default_branch`, `purpose` (une phrase), `stack`, `entrypoints`, `related` (dépend de / consommé par), `setup`, `test`, `tags`, `last_activity`.
- **Génération**, bouton *Analyser* :
  - Niveau 0, sans IA : README (premier paragraphe), manifestes (`package.json`, `Cargo.toml`, `pyproject.toml`, `go.mod`…), `git log` récent.
  - Niveau 1, avec IA : le driver par défaut en mode headless (`claude -p`, `codex exec`, `cursor-agent -p`) sur chaque repo, avec un prompt qui exige un JSON strict ; Scope valide le schéma avant d'écrire. Le `purpose` y est demandé comme la description d'un skill : une phrase, tirée de ce que fait le code (manifestes, arborescence, points d'entrée) et non recopiée du README, qui dit ce que fait le repo puis quand y travailler. Un repo inchangé n'est tenu pour fait que si sa carte vient du niveau demandé : l'analyse avec IA repasse sur ceux que seul le niveau 0 a décrits, et sur ceux qu'une version antérieure du prompt a décrits.
- **Cache** : clé = SHA de HEAD + hash du README + hash des manifestes. Édition manuelle possible et prioritaire sur la génération.
- **Vue** : cartes par repo en v1 ; une vue graphe des relations `related` quand le champ sera assez rempli pour la mériter.
- **Projection vers les drivers** : Scope écrit `AGENTS.md` (convention pivot, lue par Codex et Cursor) à la racine de task. Le profil Claude Code peut demander en plus un `CLAUDE.md` généré. Contenu : le contexte du scope tel que son propriétaire l'a écrit (réglages du scope), les repos de la task et leur rôle, les autres repos du scope avec leur rôle (pour que l'agent sache demander à en ajouter un), les règles (branche, ne pas toucher à la base).
- **Où** : le fichier est écrit là où démarrent les threads de la task — la sandbox quand la task n'a qu'un repo (y compris le cas mono-repo, où la racine de task *est* la sandbox), la racine sinon. Ailleurs, le driver ne le lit jamais.
- **Sous quels noms** : tous ceux que les profils déclarent (`context.file`, sauf `mode: none`), `AGENTS.md` toujours inclus — les threads d'une même task peuvent tourner sous des drivers différents. Même contenu dans chacun.
- **Fichier existant** : jamais écrasé, sauf s'il porte le marqueur de génération de Scope. Le nom laissé de côté est signalé dans le Problem Center : un agent qui démarre sans son contexte doit se voir.
- **Dans une sandbox** : chaque fichier écrit est ajouté à `.git/info/exclude`, donc le delta reste propre (décision ouverte 6 tranchée : fichier + exclude, tant qu'aucun driver n'expose de flag de contexte).

### 4.7 Adaptateurs et notifications

Un adaptateur transforme les événements d'un driver en états de thread. Mécanisme unique : le driver exécute une commande sur événement, cette commande est `scope-hook`, un binaire embarqué qui écrit `{thread, event, payload}` sur `scope.sock`.

- **Événements normalisés** : `turn.started`, `turn.ended`, `input.requested`, `permission.requested`, `thread.ended`.
- **Activité du thread** : chaque événement est aussi replié dans une `ThreadActivity` (`ScopeAdapters`) — dernier outil et sa cible (fichier, première ligne de la commande, motif, URL, description du sous-agent ; une ligne, 120 caractères au plus, extraite par `scope-hook` dans `payload["tool"]` / `payload["target"]`), tour en cours, les 200 derniers tours avec leur début, leur fin et leur issue (terminé, échoué, question, permission, interrompu, arrêté), la fin de la dernière réponse (16 Ko) et le chemin du transcript (`payload["transcript"]`). Un tour s'ouvre sur un prompt, ou sur le premier outil après une attente, et se ferme dès que l'agent s'arrête : une permission accordée ouvre donc un nouveau tour. Gardée à côté de l'enregistrement du thread, dans `<home>/threads/<id>.activity.json`, écrite à chaque fin de tour (pas à chaque outil) ; `scope list` en montre une ligne par thread (`activity`).
- **Notifications macOS** sur `input.requested`, `permission.requested`, `turn.ended` si l'app n'est pas au premier plan, avec actions *Répondre* / *Aller au thread* / *Voir le delta*. Badge = threads en attente.
  - Le corps cite l'agent : la question qu'il pose (`AskUserQuestion`, le plan d'`ExitPlanMode`, le message d'un `Notification` qui n'est pas la phrase standard), sinon la fin de sa dernière réponse si elle date du tour en cours ; pour `turn.ended`, le début de la réponse. Markdown retiré, blancs écrasés, ~180 caractères coupés sur un mot ; le constat (« needs your answer », …) passe en sous-titre. `turn.failed` et `permission.requested` gardent leurs mots. Préférence *Show what the agent said* (activée par défaut) pour revenir au corps générique.
  - *Répondre* (`UNTextInputNotificationAction`, bouton *Send*) tape la réponse dans le thread par le même chemin que `thread.send` (origine utilisateur, ↩ inclus), sans ramener l'app au premier plan, puis retire la notification. Une réponse vide n'envoie rien ; un échec remplace la notification par « Reply not sent ».
- **Sans adaptateur** : `running` tant que le process vit ; heuristique regex sur la sortie, désactivée par défaut.
- Les adaptateurs sont déclarés dans les profils de driver, donc extensibles sans recompiler.

### 4.8 Ouvrir dans l'éditeur

Geste de premier rang, partout, toujours sur le **bon checkout** : la sandbox si on part d'une task ou d'un thread, la base si on part de la vue Base.

- **Éditeur par défaut** : détecté au premier geste (Zed, Cursor, VS Code, Sublime, JetBrains, Nova, dans cet ordre ; ceux qui tournent déjà d'abord), enregistré, réglable. Aucun point d'entrée n'est grisé faute d'éditeur. Un éditeur connu est piloté à sa façon — son outil en ligne de commande est pris dans le bundle de l'app, pas sur le `PATH` — ; tout autre est un template libre : `{path}`, `{file}`, `{line}`.
- **Une fenêtre par checkout, retrouvée** : rouvrir un checkout revient à sa fenêtre au lieu d'en créer une (`zed -e`, comportement natif de Cursor / VS Code). On passe toujours la racine du checkout, jamais le sous-dossier où le thread s'est déplacé.
- **Cible résolue selon le contexte** : depuis un thread → sa sandbox (dans une task à plusieurs repos, celle où l'agent a touché un fichier en dernier ; la task entière à défaut), ou le repo qui contient son dossier pour un thread libre ; depuis Base → `<scope>/<repo>/` ; depuis un fichier du Delta → la sandbox **et** le fichier, sur la ligne, pour qu'il s'ouvre dans son projet ; depuis le Graph → sélecteur si le repo a plusieurs checkouts (base + N sandboxes), avec branche et état de chacun.
- **Task entière** : Cursor / VS Code → `<task-root>/<slug>.code-workspace` (un dossier par sandbox) dès qu'il y a plusieurs sandboxes, la sandbox seule sinon ; Zed, Sublime → les sandboxes côte à côte dans une fenêtre ; les autres → le dossier racine.
- **Points d'entrée** : barre de titre du thread, survol d'une ligne de task, clic droit sur un repo, icône sur chaque fichier du delta, palette, `⌘E` (repo courant), `⌘⇧E` (task entière). `⌥`-clic copie le chemin.

### 4.9 Usage de l'app

Pour savoir ce qui sert vraiment dans Scope — et ce qui ne sert jamais — l'app tient un journal **local** de son propre usage. Rien ne quitte le Mac : ni réseau, ni SDK, ni tiers. Activé par défaut ; *Réglages ▸ General ▸ Usage* le coupe (*Record how I use Scope*) et efface l'historique (*Clear History*).

- **Journal** : `<home>/usage/usage-YYYY-MM.jsonl` (mois UTC), un événement par ligne `{at, kind, id, source, scope?, context?, duration?}`. `kind` ∈ `click`, `shortcut`, `menu`, `palette`, `notification`, `control`, `view`, `setting`. Jamais de chemin, de prompt, de texte du terminal, de nom de repo ou de branche : des ids d'éléments et de méthodes, le scope par son UUID, une préférence par sa clé (pas sa valeur). Écrit par un acteur (`UsageRecorder`, `ScopeCore`) qui reçoit les événements par un flux — le thread principal ne fait qu'enfiler —, écrit toutes les 5 s et à la fermeture, plafonne un mois à 8 Mo et supprime au lancement ce qui a plus de 180 jours.
- **Ids** : `<zone>.<élément>`. Les contrôles de l'app (`Controls.swift`, `IconButtonStyle`) comptent un clic dans la zone où ils sont dessinés (`.usageArea` : `sidebar`, `inspector.delta`, `sheet.graph`, `settings.terminal`…) sous leur `.usageID`, sinon `<zone>.button`. Les commandes du menu sont lues sur `NSMenu.didSendActionNotification` (menu principal seulement ; `shortcut` si un `keyDown` les a déclenchées) et partagent leur id `command.<…>` avec la ligne de palette de la même commande. Le reste : sélection d'une ligne de la sidebar à la souris, balayage entre scopes, sections de l'inspecteur et feuilles (temps à l'écran), lien ⌘-cliqué dans le terminal, fichier ouvert depuis Delta, revue envoyée, actions de notification, et chaque appel CLI/MCP (méthode, appelant agent ou utilisateur).
- **Registre** : `<home>/usage/registry.json`, chaque élément dessiné ou déclaré au moins une fois (menu principal parcouru au lancement), pour pouvoir dire ce qui n'a *jamais* servi.
- **Lecture** : `scope usage [période] [--area A] [--limit N] [--json]`, outil MCP `scope_usage` (lecture seule, permis aux agents comme `summary`). Mêmes périodes que `scope summary`. Réponse : éléments les plus utilisés, par zone ; éléments jamais utilisés sur la période ; clavier / menu / palette / souris par commande ; appels agent / utilisateur par méthode ; temps passé par feuille et section ; tendances face à la période précédente de même durée ; et les `limits` (ce que le journal ne peut pas savoir).

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

Le raisonnement, les options écartées et ce qui a été construit sont dans `docs/design/INFORMATION_ARCHITECTURE.md`. Squelette :

- **Trois colonnes à plat** sous une seule barre d'outils, séparées par des filets : sidebar, scène, inspecteur. Pas de panneau flottant, pas de matériau translucide. Couleurs de la charte par défaut — fond Ivory et cartes blanches en clair, fond Onyx et surfaces marine en sombre, accent Electric (Periwinkle en sombre) ; un jeu de gris neutres reste un réglage. Le terminal garde ses propres couleurs.
- **Sidebar** : le travail du scope courant — threads libres, puis tasks avec leurs threads. Une ligne dit ce qui se passe en mots (*waiting for your permission*, *an agent is working*), sur une ou deux lignes au choix, rangée en arbre ou par état (*needs you*, *working*, *finished*, *quiet*, *dormant*). Une task oubliée le dit en fin de ligne (`idle 4d`, `PR closed`). La ligne sélectionnée est un fond gris arrondi qui garde les couleurs du texte. En lignes détaillées, la seconde ligne d'un thread dit ce que fait son agent dès que son driver l'a rapporté : l'outil en cours en mots (*Editing TaskTopic.swift*, *Running swift test*, *Searching "topic"* ; le chemin réduit à son dernier composant, entier dans l'aide au survol), ce qu'il demande quand il attend (la question, ou *Asks to run swift test*), puis comment son tour a fini et depuis quand (*Finished · 3m ago* — un réglage montre plutôt la première ligne de sa réponse). L'heure avance par pas de 30 s dans la seule légende. Une task à un seul thread prend cette ligne tant que l'agent travaille, attend ou a un résultat non lu ; ensuite son propre état en dit plus. La barre de titre reprend la phrase tant que l'agent travaille ou attend. Une task lancée depuis une autre n'est pas imbriquée sous elle — elles partagent en général un topic, qui les rassemble déjà : en arbre, tant qu'aucun de ses agents ne travaille ni n'attend, sa seconde ligne commence par *from <parent>*, un lien qui sélectionne le parent ; la carte de survol du parent liste les tasks lancées depuis lui, et le menu contextuel mène de l'un à l'autre. La section *Repositories*, repliée par défaut, annonce le nombre de repos modifiés. En bas : *Nouveau thread*, *Nouvelle task*.
- **Scopes** : chaque scope est une tuile dans l'en-tête de la sidebar — sa première lettre sur une couleur à lui, une icône ou une image choisies. L'image est copiée sous le home, réduite à un carré de 128 px en PNG, et tient toujours dans le carré de la tuile : une photo le remplit, un logo sur fond uni y est posé entier sur ce fond, une image transparente est posée sur une plaque (ou dessinée comme la lettre, sur la couleur, quand c'est un pictogramme d'un seul ton). Une seconde image peut la remplacer en apparence sombre. On la choisit, on la colle ou on la dépose — sur la tuile ou dans les **réglages du scope**, une feuille qui réunit son nom, sa tuile, le contexte donné aux agents, la profondeur de découverte et son graph. Le scope courant porte son nom ; les autres tiennent à côté tant qu'il y a de la place, le reste derrière un compteur `+N`. Une marque au coin dit ce qui s'y passe : un thread attend, un tour a échoué, un résultat n'est pas lu, des agents travaillent ; rien si rien ne se passe. Les tuiles suivent l'anneau des scopes, dans l'ordre déclaré à partir du scope courant : la première est le scope suivant, la dernière le précédent — là où mène un balayage. Quand la place manque, le réglage choisit seulement lesquelles restent (les plus urgentes, ou les plus proches) ; le suivant et le précédent gardent toujours la leur. Changer de scope ramène là où on en était : la ligne, le thread, les sections ouvertes de l'inspecteur.
- **Liens du terminal.** Un `⌘`-clic sur un chemin ou un lien `file://` (OSC 8) qu'un agent affiche ouvre le fichier dans la colonne de lecture : la copie de la sandbox si le thread appartient à une task, celle de la base sinon, le fichier lui-même s'il est ailleurs, à la ligne indiquée. Un chemin relatif est cherché depuis le dossier du thread, puis à la racine de chaque repo de la task — l'agent omet souvent le nom du repo ; si plusieurs fichiers correspondent, l'en-tête les propose. Un fichier modifié par la task offre son diff. Les liens web vont au navigateur.
- **Ce qu'ouvre un agent ne prend pas l'écran.** Un thread ou une task ouverts par un agent apparaissent dans la sidebar avec leur état, mais ne remplacent le terminal affiché que si aucun thread n'est à l'écran dans ce scope (réglable : jamais, toujours).
- **Scène** (centre) : le terminal du thread sélectionné. Barre de titre : le chemin *scope › task › thread*, puis driver · dossier · état · *Ouvrir dans l'éditeur*.
- **Inspecteur** (droite, masquable) : sous une bande de 30 pt qui nomme le sujet (la task, sinon le repo montré par Base), une colonne de sections repliables à la VSCode — *Task*, *Delta*, *Pull Request*, *Base*, *Files*, *Search*, *History*. Pas d'onglets : toutes les sections sont toujours là ; fermée, une section ne coûte qu'une ligne dont l'en-tête porte son résumé (`+108 −12`, la branche et son retard, l'état des checks et l'âge de leur lecture — `✓ checks passed · 4 min ago`, en gris passé trois intervalles de relecture (15 min) — le nombre de fichiers). Ce qui est un état reste visible dans l'en-tête (le mode du Delta, le repo de Base, *Pull* quand la base est en retard, *Fix Conflicts*) ; les actions (rafraîchir, éditeur, shell, Finder) apparaissent au survol. Plusieurs sections peuvent être ouvertes : les listes se partagent la hauteur, la séparation entre deux listes ouvertes se tire. Les sections ne contiennent que des listes : le diff et le fichier de base s'ouvrent dans une colonne de lecture à part, entre la scène et l'inspecteur, sur toute la hauteur — l'équivalent de la zone d'édition de VSCode. Elle partage par défaut 50/50 la largeur laissée au terminal, se tire (la proportion est gardée), s'ouvre sur un geste (clic sur un fichier, `j`/`k`, un résultat de recherche, un lien du terminal) et se ferme d'un ✕ ou d'Échap. Sans task, Task, Delta et Pull Request restent affichées, grisées. Au repos, seul Delta est ouvert avec une task, seul Base sans ; Files est fermé et son arbre s'ouvre tous dossiers fermés (un saut de recherche n'ouvre que les dossiers du fichier). Les sections ouvertes sont mémorisées par scope, séparément avec et sans task. `⌘D` / `⌘⇧B` ouvrent et focalisent leur section, sans jamais la refermer. Le *Graph* et la liste des pull requests du scope sont des feuilles ouvertes depuis la sidebar. Les boutons *Commit*, *Push*, *Créer la PR* et *Merge* sont masqués par défaut : c'est le travail de l'agent dans son thread, le panneau sert à lire ce qu'il a fait.
- **Palette** `⌘K` : nouveau thread, nouvelle task, ajouter un repo à la task, ouvrir `<repo>` dans l'éditeur, ouvrir la task dans l'éditeur, analyser le graph, aller à un thread, déclarer un scope. Sur la task courante : l'archiver, la classer sous un topic ou l'en sortir, ouvrir sa pull request, copier sa branche ; *Restore Archived Task…* liste les tasks archivées du scope. Aucune confirmation : archiver ne perd rien. *Ask Orchestrator…* (`⌘⇧K`) transforme la palette en champ de message adressé à l'orchestrateur du scope (`↩` envoie, `⇧↩` va à la ligne) ; *Send to Thread…* choisit d'abord un thread dans la même liste que *Go to Thread*. Le texte part comme un `thread.send`, sans signature puisqu'il vient de l'utilisateur ; un thread arrêté est démarré pour le recevoir, et le message attend que le driver lise son entrée. La sélection et le terminal ne bougent pas ; un toast *Sent to <scope> orchestrator* offre *Show*. Une recherche qui ne trouve rien, ou qui se lit comme une phrase (trois mots ou plus), propose en dernière ligne *Ask Orchestrator: <texte>* : `⌘K`, taper, `↩` suffit.
- **Répondre sans changer de thread** : `⌥↩` sur une ligne de la sidebar (quand la liste a le clavier) ou *Reply…* dans son menu contextuel ouvre un champ sous la ligne, précédé des dernières lignes de la réponse de l'agent (rien si elle précède le dernier prompt). Mêmes touches que la palette, `Esc` referme. Pas pendant qu'un tour est en cours.
- **Raccourcis** : `⌘O` déclarer un scope, `⌘T` nouveau thread, `⌘⇧T` nouvelle task, `⌘E` / `⌘⇧E` éditeur, `⌘D` delta, `⌘⇧B` base, `⌘1..9` threads, `⌃1..9` scopes (dans l'ordre déclaré), `⌥⌘←` / `⌥⌘→` scope précédent / suivant, `⌃⌘S` sidebar, `⌃⌘L` lignes détaillées ou compactes, `⌃⌘G` rangement en arbre ou par état, `⌘⇧K` demander à l'orchestrateur, `⌥↩` répondre depuis la sidebar. Un balayage horizontal à deux doigts sur la sidebar change aussi de scope, en boucle dans les deux sens ; pendant le geste, le scope de destination apparaît dans l'espace ouvert et sa tuile s'allume dans l'en-tête.
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
4. ~~**Nom de branche** : `scope/<slug>` ou `<user>/<slug>` ?~~ Tranché : la convention du repo, proposée par le driver ; `scope/` réservé.
5. **Base de branche** : `origin/<default>` fraîchement fetché (proposé) ou la base locale ?
6. ~~**Projection mono-repo** : flag de contexte du driver, ou fichier + `.git/info/exclude` ?~~ Tranché : fichier + `exclude`, écrit dans le cwd des threads, sous chaque nom déclaré par les drivers ; un fichier que Scope n'a pas généré est laissé en place et signalé.
7. **Rendu du delta** : natif SwiftUI + parser (proposé, cohérent, plus long) ou `WKWebView` + diff2html (rapide, moins natif).
8. **Graph L1** : quel driver par défaut ? Coût et durée acceptables par repo ?
9. **Repos non clonés** : `gh` obligatoire, ou API GitHub avec token ?
10. ~~**Setup post-sandbox** : commande dans le graph (proposé) ou détection depuis les manifestes ?~~ Tranché : commande de la carte du graph (éditable), surchargeable par repo dans la config du scope, avec un `teardown` symétrique ; Scope n'écrit rien dans les repos pour ça.
11. **Scopes imbriqués** : autorisés (proposé) ou refusés ?
12. **Licence** : MIT ou Apache-2.0.
