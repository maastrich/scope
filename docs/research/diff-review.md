# La vue diff de Scope : constats et propositions

Recherche du 2026-10-20, sur Scope `09a3eed` (v0.26.0). Sources :

- le code de l'inspecteur et du delta (`App/Scope/Views/Inspector/Delta/`, `DeltaModel`, `ReviewModel`,
  `Sources/ScopeGit/Diff/`, `Sources/ScopeTasks/Review/`, `TaskCheckpoints`), `SPEC.md` §4.4 et §7, `CHANGELOG.md` ;
- le journal d'usage local (`~/.scope/usage/usage-2026-10.jsonl`, 16–19 octobre), compté par id d'événement ;
- un sondage des outils de revue : GitHub, Graphite, Reviewable, Gerrit, Kaleidoscope, Xcode, Tower, Fork, VS Code,
  Zed, Cursor, Claude Code `/diff`, l'app Codex, Conductor, Warp, Vibe Kanban, Plannotator, et les billets de
  Devin Review, Amp, Bitloops, CodeRabbit sur la revue de code produit par un agent.

Un prototype en est sorti : les marques *viewed* persistantes et l'état *changed since viewed* (PR #71).

---

## 1. Ce qui existe déjà

Plus que la spec ne le laisse croire. La spec §4.4 annonce « rendu unifié ou côte à côte, coloration syntaxique » ;
le code n'a ni l'un ni l'autre, mais il a des choses que la spec ne nomme pas.

| Surface | État | Où |
|---|---|---|
| Trois modes (Task, Uncommitted, Base vs origin), agrégés sur les repos de la task | fait | `Delta.load`, `DeltaSection` |
| Liste de fichiers par repo, filtre par chemin, chips A / M / D | fait | `DeltaFileList` |
| Diff unifié, `NSTextView` monospace, repli des hunks, gouttière old/new | fait, **sans coloration syntaxique, sans côte à côte, sans ignorer les espaces** | `DiffView`, `DiffDocumentBuilder`, `MonoTextView` |
| Diff d'image | fait | `ImageDiffView` |
| `j`/`k` fichier, `]`/`[` hunk | fait, **jamais utilisé** (0 dans le journal) | `DeltaKeyboard` |
| Marquer comme vu | fait, en mémoire : **perdu au relancement**, effacé en silence dès que le diff du fichier change | `DeltaModel.viewed`, `DiffDigest` |
| Commentaires de revue sur une ligne ou une plage, édition, liste, envoi en un message au thread (`Send Review`) | fait, persistant (`<home>/reviews/<task>.json`), ancre par contenu qui suit les éditions de l'agent | `ReviewComment`, `ReviewRenderer`, `ReviewBar` |
| Checkpoint par tour, *Show diff* contre l'arbre courant | fait, **mais rendu en Markdown** (blocs ` ```diff `) dans la colonne de lecture : pas de liste de fichiers, pas de repli, pas de commentaire, pas de marque | `AppModel+Checkpoints`, `TaskCheckpoints.diff` |
| Section Pull Request : état, checks, *Send to Thread* sur un check rouge, *Fix Conflicts* | fait, rafraîchi chaque minute | `PullRequestSection` |
| Outils du tour (nom, cible, durée) par thread, 60 appels gardés par tour | fait, affiché dans la colonne de lecture seulement | `ThreadActivity.Turn.turnCalls`, `ReadingTurn` |
| Ouvrir dans l'éditeur sur la première ligne changée, révéler, copier le patch | fait | `DiffView.header` |
| Commit / Push / Create PR | fait, masqués par défaut | `DeltaSection.actions` |

### Ce que dit le journal d'usage

| Événement | 16–19 oct. |
|---|---|
| `inspector.delta` (section ouverte à l'écran) | 48 |
| `inspector.files` | 42 |
| `inspector.pull-request` | 38 |
| `inspector.delta.open-file` (clic sur un fichier) | 27 |
| `viewer` (colonne de lecture à l'écran) | 29 |
| `viewer.close` | 19 |
| `inspector.delta.refresh` | 4 |
| `toolbar.read-reply` | 5 |
| `inspector.delta.send-review` | **0** |
| `j` / `k` / `]` / `[` | **0** |
| Marquer comme vu | **non mesuré** (le bouton n'avait pas d'id d'usage ; corrigé dans le prototype) |

Lecture : l'utilisateur ouvre le Delta et la liste des fichiers plus souvent que tout le reste de l'inspecteur,
ouvre un fichier une fois sur deux, et ferme la colonne presque aussi souvent qu'il l'ouvre (19 fermetures pour
27 ouvertures) : il lit un fichier, ferme, choisit le suivant à la souris. Il n'a jamais envoyé de revue depuis
le diff — soit la gouttière cliquable n'est pas découverte (le `+` n'apparaît qu'au survol, rien ne l'annonce), soit
il préfère taper dans le terminal. Les raccourcis de navigation sont morts : ils exigent que la liste ou le diff ait le
focus clavier, et le focus est au terminal par défaut ; rien à l'écran ne les rappelle à part le `?` de la section.

### Ce que font les autres (résumé utile)

- **Marque *vu* + « changed since last view »** : GitHub décoche et pose un badge quand le fichier bouge ; Reviewable
  et Gerrit lient la marque à une révision et proposent *Show unreviewed diffs* ; Graphite offre *hide reviewed changes*
  (dernière version revue → courante). Tous gardent l'état côté serveur, donc à travers les sessions.
- **Diff entre deux révisions** (patchsets Gerrit, versions Graphite, révisions Reviewable) : c'est le vrai « depuis
  ma dernière lecture ». Scope a l'équivalent gratuit : un checkpoint par tour d'agent, avec son arbre git.
- **Diff par tour** : Claude Code `/diff` a un onglet par tour (rebâti depuis ses enregistrements d'outils) ; l'app
  Codex a une vue *Last turn* ; Conductor « turn by turn changes ». Aucun ne relie un *hunk* à l'appel d'outil
  qui l'a produit.
- **Commentaires groupés renvoyés à l'agent en un message** : Warp, Vibe Kanban, Codex, Plannotator, Conductor.
  Scope l'a déjà, mieux ancré qu'eux (ancre par contenu).
- **Annuler par hunk / fichier** (Warp, Codex, Zed *Review Changes*, Cursor) : la primitive d'acceptation la plus
  répandue chez les outils d'agents. Scope n'a que *Restore files* d'un checkpoint entier.
- **Bruit** : GitHub replie les fichiers `linguist-generated` (`.gitattributes`) ; Gerrit saute les fichiers dont le
  seul changement vient d'un rebase. Aucun outil d'agent ne documente de filtre lockfile.
- **Ordre de lecture** : Devin Review regroupe les hunks liés et les ordonne avec une explication par hunk ; Amp donne
  un ordre recommandé et un indicateur de churn par fichier. VS Code replie les régions inchangées et détecte les
  blocs déplacés.
- **Côte à côte, coloration, ignorer les espaces** : partout ailleurs (Kaleidoscope, Xcode, Tower, Fork, VS Code,
  Zed, Vibe Kanban). Scope est le seul sans coloration.

---

## 2. Idées, classées

Impact : ce que ça change pour *juger le travail de l'agent* (le geste dominant). Effort : S = une journée, isolé ;
M = quelques jours, touche plusieurs modèles ; L = une semaine ou plus, ou une dépendance nouvelle.

### 2.1 Mémoire de la revue

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| 1 | **Marques *vu* persistantes + état *changed since viewed*** | fort | **S** | La revue d'une task dure des jours (47 ouvertures du Delta sur quatre jours). Une marque perdue au relancement, ou effacée en silence quand l'agent retouche le fichier, dit « jamais lu » là où il faut dire « relis ça ». `DiffDigest` était déjà stable entre lancements. **Prototypé : PR #71.** |
| 2 | **Diff depuis ma dernière lecture, par fichier** : la marque *vu* mémorise aussi le numéro du dernier checkpoint ; sur un fichier *changed*, un bouton *What changed since* ouvre `TaskCheckpoints.diff` restreint à ce fichier | fort | M | C'est le « revision diff » de Reviewable/Gerrit, gratuit grâce aux checkpoints. Limite : le checkpoint précède la fin du tour, donc une marque posée en plein tour inclut un peu d'avant ; acceptable, la note le dit. |
| 3 | **« Hide viewed »** dans la barre de filtre, et `N of M viewed` dans l'en-tête fermé de la section | moyen | S | Reviewable compte « files that remain to be reviewed » ; c'est le vrai état d'une revue en cours. Deux lignes dans `DeltaFileList` une fois #1 posé. |
| 4 | **Marquer vu automatiquement** quand le diff a été lu jusqu'au bout (scroll au fond ou fichier court) — préférence, comme le *Mark Reviewed* de Gerrit | moyen | S | Ôte un clic par fichier ; l'utilisateur ferme déjà la colonne après chaque fichier. |

### 2.2 Relier le diff à l'agent

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| 5 | **Rendre le diff d'un checkpoint dans `DiffView`** au lieu du Markdown : un quatrième mode du Delta, *Since checkpoint N* (liste de fichiers, repli, marques, commentaires, j/k) | fort | M | Aujourd'hui *Show diff* produit un bloc Markdown sans liste ni commentaires : un checkpoint ne se *revoit* pas, il se lit. Techniquement, `TaskCheckpoints.diff` renvoie déjà des `[DiffFile]` ; il manque un `DeltaMode.sinceCheckpoint(n)` dans `Delta.load` (diff `tree(n)` → arbre courant via `WorkingTreeSnapshot`) et un sélecteur dans le menu *Mode*. Même chemin pour « diff du dernier tour » (= since checkpoint n−1), la vue *Last turn* de Codex. |
| 6 | **Attribuer chaque fichier au tour qui l'a touché** : dans la liste, une pastille « turn 7 · claude-main » ; au survol, les premiers mots de la réponse ; clic → ce tour dans la colonne de lecture | fort | M | C'est la question que l'utilisateur se pose en jugeant : « pourquoi a-t-il touché ça ? ». Deux sources déjà là : les checkpoints (arbres par tour → `git diff --name-only tree(n−1) tree(n)` dit quel tour a changé quel fichier, exact) et `turnCalls` (cible des outils `Edit`/`Write`, 60 par tour, approximatif mais instantané). Par hunk ce serait L (blame entre arbres de checkpoints) ; par fichier suffit. |
| 7 | **Ouvrir le diff depuis la réponse** : dans la colonne de lecture, la ligne *Changes* d'un tour ouvre #5 plutôt que du Markdown ; un chemin cité dans la réponse ouvre le diff du fichier s'il est dans le delta | moyen | S | Déjà presque là (`openChanges`, `openFileLink` « un fichier modifié par la task offre son diff »). |
| 8 | **Rendre les commentaires visibles** : afficher le `+` de la gouttière en permanence sur la ligne survolée *et* une ligne d'aide dans l'en-tête du diff (« click the gutter to comment ») ; `c` sur une ligne (Gerrit) ; compteur dans l'en-tête de la section Delta | moyen | S | Zéro `Send Review` en quatre jours alors que c'est la fonctionnalité la plus aboutie du panneau. Découvrabilité, pas capacité. |
| 9 | **Annuler un hunk / un fichier** (`git checkout -p`-like : réécrire le fichier sans ce hunk ; fichier entier = `git checkout <merge-base> -- path` ou suppression si ajouté), avec checkpoint préalable comme *Copy into…* | fort | M | La primitive commune de Warp, Codex, Zed, Cursor. Dans Scope l'utilisateur ne retouche pas lui-même (il renvoie à l'agent), mais « enlève ce fichier parasite » est un cas courant et un message à l'agent est lent pour ça. Checkpoint d'abord = undo gratuit. |
| 10 | **Message rapide depuis un fichier** : « Ask about this file » prérempli (`Why did you change api/Foo.swift?`) via `deliver` | faible | S | Variante légère de #8 pour qui ne commente pas ligne à ligne. |

### 2.3 Lire plus vite

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| 11 | **Coloration syntaxique** dans `DiffDocumentBuilder` (tokenizer maison pour une dizaine de langages, ou `Highlightr`/`tree-sitter`) | moyen | M–L | Seul outil du sondage sans. Mais le gain pour *juger* est moindre que #1/#5/#6 ; et une dépendance C/JS pèse sur un binaire ad-hoc. Tokenizer maison limité (mots-clés, chaînes, commentaires) = M. |
| 12 | **Diff intra-ligne** (mots changés surlignés dans une paire −/+) | moyen | S–M | Myers sur les mots d'une paire de lignes adjacentes ; grosse aide sur les renommages et les lignes longues, fréquents chez un agent. Tout dans `DiffDocumentBuilder`. |
| 13 | **Ignorer les espaces** (`-w`), bascule dans l'en-tête, mémorisée | moyen | S | Un agent reformate souvent ; `Delta.diffArguments` + un flag. |
| 14 | **Replier automatiquement le bruit** : lockfiles (`*.lock`, `package-lock.json`, `pnpm-lock.yaml`, `Package.resolved`), `linguist-generated` de `.gitattributes`, fichiers > N lignes, snapshots de tests ; groupe « Generated · 3 files » replié en bas de la liste, compté à part dans l'en-tête | moyen | S | Un lockfile de 2 000 lignes noie les 40 lignes qui comptent. Liste de motifs par défaut + lecture de `.gitattributes` (`git check-attr linguist-generated`). |
| 15 | **Ordre de lecture** : trier par « poids » (fichiers source avant tests avant docs avant généré ; ou par tour) plutôt qu'alphabétique | faible | S | Devin/Amp ; mais la liste est courte dans la plupart des tasks. |
| 16 | **Côte à côte** | faible | L | Demandé par la spec, offert partout ailleurs, mais sur une colonne de 50 % de la scène ça ne tient pas ; et l'usage ne le réclame pas. Remettre à plus tard. |
| 17 | **Navigation clavier qui marche sans focus** : `⌘]` / `⌘[` fichier suivant/précédent depuis n'importe où (menu *View*), et un hint « j / k » dans l'en-tête de la colonne de lecture | moyen | S | 0 usage : le focus est la cause, pas le besoin. Le `?` n'enseigne rien. |

### 2.4 Autour du diff

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| 18 | **Checks CI dans l'en-tête de la colonne de lecture** (le chip `✓ checks passed · 4 min`, cliquable vers la section) | faible | S | L'utilisateur ouvre Pull Request presque autant que Delta (38 vs 48) ; une ligne les met au même endroit. |
| 19 | **Commentaires GitHub dans le diff** : lire les review threads de la PR (`gh api`) et les afficher en lignes teintées comme les nôtres, *Send to Thread* dessus | moyen | M | Conductor le fait ; utile quand un bot (CodeRabbit, Copilot) a déjà commenté. |

---

## 3. Top 3 recommandé

### 1. Marques *vu* persistantes et *changed since viewed* — fait (PR #71)

Pourquoi en premier : c'est l'état de la revue elle-même, et il était perdu à chaque relancement. Esquisse telle que
livrée :

- `ViewedMarks` (ScopeTasks) : `[Mark{mode, repo, path, digest, at}]`, `state(…) → unviewed | viewed(at) |
  changedSinceViewed(at)`, `retain(mode:)` pour les fichiers sortis du delta ; `ViewedStore` à
  `<home>/reviews/<task>.viewed.json`, supprimé avec la task. Six tests (`ViewedMarksTests`).
- `DeltaModel` : charge les marques avec la task, sauvegarde en série comme `ReviewModel`, `viewedState(ref, file)`,
  `viewedCounts(in:)`. Le toggle compte désormais dans le journal d'usage.
- `DeltaFileList` : ☐ / ☑ (estompé) / ⚠ `changed` orange ; la ligne de groupe dit `· 3 viewed · 1 changed`.

Suite naturelle : #3 (*Hide viewed*, compteur dans l'en-tête fermé) et #2 (le checkpoint mémorisé à la marque).

### 2. Diff par checkpoint dans la vraie vue (#5), puis attribution par tour (#6)

Esquisse :

- `DeltaMode` gagne `.sinceCheckpoint(Int)` (ou un `DeltaMode` + `checkpoint: Int?` à côté dans `DeltaModel` pour
  garder l'enum `Codable` simple). `Delta.load` le traite comme `.uncommitted` avec `tree(n)` à la place de `HEAD` :
  `git diff <tree> ` + untracked, exactement ce que fait `TaskCheckpoints.diff` via `WorkingTreeSnapshot.diff`.
  Avantage : la liste, le repli, les marques et les commentaires viennent gratuitement.
- Le menu *Mode* liste *Task*, *Uncommitted*, puis *Since last turn* et *Since checkpoint…* (sous-menu des derniers
  checkpoints, libellés par `headline`). *Show diff* dans la section Task et la ligne *Changes* de la colonne de lecture
  passent par là.
- Attribution : à chaque chargement du delta en mode Task, pour chaque fichier, trouver le plus grand `n` tel que
  `git diff --name-only tree(n−1) tree(n) -- path` n'est pas vide (en une commande : `git diff --name-only` entre
  arbres consécutifs, mémorisé par paire d'arbres, les arbres ne bougent pas). Afficher `turn 7` en tertiaire dans
  la ligne, survol = `checkpoint.said`, clic = ce tour dans la colonne de lecture. Multi-tours : le dernier, avec
  `+2` si plusieurs.

Ordre : #5 d'abord (une journée, tout dans `Delta.load` + un menu), #6 ensuite (une journée de plus, tout dans
`DeltaModel`, testé sur dépôts temporaires comme `TaskCheckpointTests`).

### 3. Rendre la revue par commentaires découvrable (#8) et le bruit replié (#14)

Deux S qui attaquent les deux zéros du journal : zéro revue envoyée, et des lockfiles lus comme du code.

- #8 : dans l'en-tête de `DiffView`, à droite du chemin, un texte tertiaire « Click a line number to comment » tant
  que la task n'a aucun commentaire ; `c` sur la ligne sous le pointeur ouvre l'éditeur ; le compteur de commentaires
  monte dans l'en-tête fermé de la section Delta (`+108 −12 · 2 comments`).
- #14 : `NoiseFilter` (ScopeGit, pur, testé) : motifs par défaut + `git check-attr linguist-generated` sur les chemins
  du delta ; `DeltaFileList` met ces fichiers dans un groupe *Generated* replié sous les autres, `DiffView` les ouvre
  quand même. Préférence pour la liste de motifs.

---

## 4. Ce que je ne recommande pas maintenant

- **Côte à côte** (#16) : coûteux, et la colonne de lecture n'a pas la largeur ; l'usage ne le demande pas.
- **Coloration via une dépendance** (#11 en L) : un tokenizer maison borné vaut mieux qu'un `highlight.js`
  embarqué dans un binaire signé ad hoc ; à faire après le top 3.
- **Attribution par hunk** : un blame entre arbres de checkpoints par hunk est faisable mais lent sur un gros
  fichier, et « quel tour a touché ce fichier » répond à 90 % de la question.
