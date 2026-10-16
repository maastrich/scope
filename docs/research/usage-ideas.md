# Idées pour améliorer l'usage de Scope

Recherche du 2026-10-16, sur Scope v0.20.0. Rien n'est implémenté ici. Sources :

- `SPEC.md`, `CHANGELOG.md`, `docs/design/INFORMATION_ARCHITECTURE.md` ;
- le code (`Sources/`, `App/`) ;
- les enregistrements locaux du propriétaire, lus en **agrégats seulement** ;
- un sondage du marché (oct. 2026) ;
- un test réel d'Apple Foundation Models sur un M1 Max de 32 Go sous macOS 26.5.

Le dépôt est public : ce document ne cite aucun nom de task, de PR ni de dépôt du travail.

---

## 1. Ce que j'observe de l'usage actuel

### Dans les données (`~/.scope`, environ 5 semaines)

| Mesure | Valeur | Ce que ça dit |
|---|---|---|
| Tasks | 31, dont 23 archivées et 8 ouvertes | Rotation rapide. Le cycle « créer → livrer → archiver » est rodé. |
| Créées par | 22 par un agent via `scope-mcp`, 9 via `scope-cli`, **aucune par la feuille New Task** (sur les records conservés : clôturer une task efface son record) | La feuille de création n'est plus le chemin principal. Les tasks naissent d'une conversation avec un agent, ou d'une commande. |
| Taille du prompt de task | médiane ≈ 2,6 k caractères, max ≈ 8,9 k | Ce sont des briefs écrits par un agent, pas des titres. |
| Repos par task | 24 en ont 1, 7 en ont 2 | Le multi-repo existe mais reste minoritaire. |
| Topics | utilisés sur 4 tasks sur 31 | La fonction est récente (v0.19–0.20) et encore peu employée. |
| Nature des tasks ouvertes | environ la moitié sont des **études / recherches** (titre « Étude : … », « Recherche : … ») | Elles n'ont pas de PR. Leur livrable est un texte ou un fichier, et il **disparaît à l'archivage** : `ActivitySummary` le dit lui-même (« nothing of what was said in its threads survives them »). |
| Threads | 29 enregistrés, `claude-code` largement dominant | Un seul vrai driver en pratique. |
| Préférences | driver par défaut `claude-code-bypass`, `showGitActions: false`, menu bar activé, 2 scopes | Autonomie maximale. Les **permissions sont rares** : c'est la *fin de tour*, la *question* et l'*échec* qui comptent. Le commit, le push et la PR restent à l'agent. |

### Le profil qui en ressort

Le propriétaire est un **chef d'orchestre**, pas quelqu'un qui tape dans des terminaux. Il formule une intention à l'orchestrateur du scope, qui écrit un brief long et ouvre une task. Il revient quand quelque chose l'appelle : il lit, relance et merge (en squash), puis demande l'archivage.

Scope sert donc surtout à trois moments :

1. savoir **quoi regarder maintenant** ;
2. **lire vite** ce qu'un agent a produit ;
3. **ranger**.

Toute idée qui ajoute des boutons git ou un dialogue de confirmation va contre ce profil. Les préférences du propriétaire sont claires : l'autonomie d'abord, et quand un comportement fait doute, on décide et on le rend réglable.

### Ce qui existe déjà et n'est donc pas proposé

- Sur un thread : les états (running, waiting, done, failed), le badge Dock, les notifications, le menu bar extra, ⌥⌘↩ (thread suivant en attente), *Mark as Read*, des marques d'attention par tuile de scope.
- La palette ⌘K, ⌘1…9 et ⌃1…9, le balayage entre scopes.
- Les tasks : worktrees, setup et teardown, ports, sauvegarde des changements non commités (*salvage*), *Restore* dans l'UI, GC.
- La revue : Delta avec commentaires de ligne envoyés au thread, PR avec checks, *send failure to thread*, *Fix conflicts*.
- Les agents : CLI et MCP (`thread new/send/wait/read`, `task new/archive/close/topic`, `summary`, `gc`), un orchestrateur et un terminal résidents par scope, un budget et une profondeur pour les agents.
- La reprise des threads au relancement, les liens `scope://`, Vibe Island.

---

## 2. Idées par catégorie

Échelles : impact **H** (haut), **M** (moyen), **B** (bas) ; effort **S** (petit), **M** (moyen), **L** (gros). La source marché est entre crochets quand l'idée vient d'un autre outil.

### A. Savoir quoi regarder

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| A1 | **Une ligne « ce que fait l'agent » par thread** dans la sidebar (« édite TaskTopic.swift », « lance swift test », « attend ta réponse »). Version déterministe d'abord, sans IA : le nom de l'outil et le fichier, tirés de `PostToolUse`. | H | S | C'est la question ouverte Q4 de l'IA doc (§2.3, §8). Les données arrivent déjà : `PostToolUse` est câblé (`ClaudeHooksAdapter.entries`) et `HookStdin.toolName` est parsé. Il manque seulement `tool_input.file_path` / `command` et l'affichage. |
| A2 | **Une boîte « À traiter »** transverse à tous les scopes, en feuille ou dans le menu bar extra : seulement les questions, les fins de tour non lues, les échecs et les PR prêtes à merger. Chaque entrée a une action directe : répondre (champ texte → `thread.send`), ouvrir, marquer lu, archiver. [Warp, Vibe Island, Pinrail, Claude Agent View] | H | M | Q2 de l'IA doc (« what needs me in another scope ») reste à moitié résolue. Le menu bar liste les threads en attente, mais on ne peut pas y agir. Avec le driver bypass, les « questions » et les « fins de tour » sont ce qui reste à traiter. |
| A3 | **Un compteur d'usage Claude** dans la barre d'outils ou le menu bar : les tokens **consommés** sur 5 h et sur la semaine, par thread et par task. Le hook stdin de Claude Code donne `transcript_path`, et le JSONL contient `usage` par message, à agréger en tâche de fond. Le plafond du forfait et le pourcentage restant ne figurent pas dans le transcript : la source reste à trouver (non vérifié). [Vibe Island, Agent Deck, Devin] | H | M | Rien n'est lu aujourd'hui : aucune occurrence de `transcript_path` dans `Sources/`. Avec un orchestrateur qui ouvre des tasks en cascade, voir la consommation est le garde-fou qui manque à côté du budget de tasks. |
| A4 | **Rafraîchir les PR en arrière-plan, et archiver la task quand sa PR est vue mergée.** L'archivage automatique est une préférence, activée par défaut, et attend qu'aucun thread de la task ne tourne. | H | M | Aujourd'hui, seule la task **affichée** interroge GitHub (la boucle `.task(id:)` de `InspectorView.swift:48`). Les autres gardent leur état de checks et de PR de la dernière visite : leur glyphe dans la sidebar peut mentir. La règle « attendre MERGED, puis archiver » oblige l'agent à garder un thread qui attend GitHub ; Scope peut le faire à sa place. |
| A5 | **Signaler les tasks oubliées.** Une marque discrète sur une task ouverte sans activité de thread depuis N jours, une autre sur une PR fermée sans merge. Une section « Endormies » dans le rangement *By state*. | M | S | Il y a 8 tasks ouvertes pour 2 scopes, et elles retiennent le budget des agents. `ActivitySummary` sait déjà classer (`TaskOutcome`). |
| A6 | **Le poids disque des sandboxes** (les `node_modules` par worktree), dans les réglages du scope et dans `scope gc --dry-run`. | B | S | Une task sur un monorepo JS peut peser plusieurs Go. Le GC sait nettoyer, mais pas dire combien. |
| A7 | **Un tableau des tasks** en colonnes, sur tous les scopes : *travaille*, *t'attend*, *en revue (PR ouverte, checks)*, *mergée*. Glisser vers « archivée » archive la task. [Vibe Kanban, Superset, Nimbalyst] | M | M | C'est la vue manager du chef d'orchestre. La sidebar *By state* le fait par thread, pas par task, et pour un seul scope. |

### B. Clavier, palette, actions rapides

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| B1 | **« Demander à l'orchestrateur… » depuis ⌘K.** On tape une intention dans la palette, elle part au thread orchestrateur du scope (`thread.send`), sans changer la sélection. | H | S | C'est le geste principal de l'utilisateur, et aujourd'hui il coûte un changement de thread. |
| B2 | **Un raccourci global système** (configurable, par ex. ⌥Space) : une petite fenêtre flottante pour envoyer une intention à un orchestrateur, ou répondre au thread en attente le plus ancien. [Raycast, Claude Dispatch] | H | M | Une idée de task arrive souvent en dehors de Scope. |
| B3 | **Les actions de task qui manquent à la palette** : *Archive Task*, *Set Topic…*, *Restore Archived Task…*, *Open PR in Browser*, *Copy Branch*, *Send to Thread…*, *Summary of Today*. | M | S | Vérifié : `PaletteModel.swift` ne contient aucune action d'archivage, de topic, d'envoi ni de navigateur. On peut aller à une task, mais pas agir dessus. |
| B4 | **Répondre sans changer de thread.** ⌥↩ sur une ligne en attente ouvre un champ inline sous la ligne ; le message part au thread. | M | S | La sélection a des effets de bord : elle déplace le terminal et le clavier (IA doc §2.2). |
| B5 | **Traiter plusieurs tasks à la fois** : archiver, attribuer un topic, fermer. [Superset] | B | S | Utile pour ranger le vendredi. |

### C. Flux orchestrateur → task → thread

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| C1 | **`scope task restore` en CLI et `scope_task_restore` en MCP.** | H | S | C'est une lacune confirmée : *Restore* existe dans l'UI (`AppModel+Tasks.swift:433`), mais aucun `ControlCall` ne la porte. L'orchestrateur ne peut donc pas reprendre une task archivée, alors que c'est lui qui pilote tout. |
| C2 | **Garder le livrable à l'archivage.** Avant de raccrocher les threads, `dismantle` enregistre la dernière réponse de chaque thread (le `reply` du `Stop`, déjà transporté) dans le record de la task. `summary` et `task show` la rendent ensuite. Un type de task « étude » peut aussi récupérer un fichier désigné (`REPORT.md`) dans `SCOPE_HOME`. | H | M | Environ la moitié des tasks ouvertes sont des études sans PR. Leur seul produit est un texte, aujourd'hui perdu à l'archivage. |
| C3 | **Mentionner une ancienne task ou un ancien thread** dans un prompt (`@task:slug`). Scope injecte son brief, sa dernière réponse, sa branche et sa PR. [Nimbalyst, Amp] | M | M | Les études nourrissent des tasks d'implémentation. Aujourd'hui, l'orchestrateur recopie à la main. |
| C4 | **Une task depuis une issue GitHub** (URL ou `#123`). La microsession `headlessLight` résout déjà une PR évoquée dans le prompt : on étend son allowlist à `gh issue view`. Linear demanderait une autre voie (MCP), donc un effort M à part. [Conductor, Agent HQ] | M | S | C'est un petit changement dans un profil existant (penser à bumper `version`). |
| C5 | **Des checkpoints par tour.** À chaque `turn.ended`, un snapshot du worktree dans `refs/scope/checkpoints/<task>/<n>`, avec le même index privé que le salvage. Puis « Revenir au tour N » dans Delta. [Conductor, Claude Code rewind] | M | M | La mécanique existe déjà pour le salvage. En mode bypass, c'est le filet de sécurité naturel. |
| C6 | **Best-of-N** : un prompt envoyé à N tasks parallèles (drivers ou modèles différents), un diff comparé, on garde la meilleure, les autres sont fermées. [Cursor, Superset] | M | L | C'est audacieux, et le budget des agents le limite déjà. Ça vaut pour les tâches à forte incertitude. |
| C7 | **Passer un thread à un autre driver** (Claude → Codex) avec un résumé de contexte généré. [Superset] | B | M | Ça ne compte que le jour où un second driver est vraiment utilisé (aujourd'hui, environ 100 % Claude). |
| C8 | **Des prompts programmés** : chaque matin, l'orchestrateur reçoit « trie les PR aux checks rouges », « résume hier ». Le résultat arrive dans la boîte A2. [Codex Automations, Jules, Superset] | M | M | Audacieux. Il faut que l'app tourne, mais elle tourne déjà en continu avec son menu bar. |
| C9 | **Des missions à jalons** : l'orchestrateur découpe un objectif en tasks séquentielles, avec un critère de validation (tests, checks verts) avant de lancer la suivante. [Factory Missions] | M | L | Très audacieux. Une partie peut vivre dans le skill `scope` plutôt que dans l'app. |

Deux frictions rencontrées en lançant la vague 0 depuis un agent :

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| C10 | **Un `#N` cité dans un brief ne doit pas devenir le point de départ.** Il ne compte que s'il est la demande (« reprends #37 ») ; sinon on le laisse en contexte, ou il y a un paramètre explicite `start_pr`. | M | S | Un brief qui mentionnait « PR #37 » pour le contexte a été refusé (« #37 is not a pull request of a repository in this scope ») : la PR d'un autre dépôt, ou simplement citée, bloque la création. |
| C11 | **Le refus du préfixe `scope/` dit quoi faire.** Par exemple : « omit `branch` and Scope names it, or use another prefix ». La description MCP de `branch` le mentionne aussi. | B | S | `"scope/x" is not a valid task branch (the scope/ prefix is reserved)` alors que la spec présente `scope/<slug>` comme nom de branche par défaut. |

### D. Environnement et revue

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| D1 | **Repérer les serveurs lancés par une task** (ports en écoute dans le bloc `SCOPE_PORT…+9`, via le même balayage de process que le GC). Une puce « :41003 ↗ » dans la bande de la task. [Conductor, Superset, Vibe Kanban] | M | S | Les ports par task existent, mais on ne sait pas lequel sert. |
| D2 | **« Essayer dans mon checkout »** : passer temporairement la base sur la branche de la task pour un seul serveur de dev, puis la remettre. [Conductor Spotlight, Sculptor Pairing] | M | M | Contraire au principe « la base est intouchable » : à proposer seulement en opt-in explicite. |

### E. Design et UX

| # | Idée | Impact | Effort | Pourquoi |
|---|---|---|---|---|
| E1 | **Des notifications qui disent quelque chose, et auxquelles on répond.** Le corps de la notification devient le début de la question ou de la dernière réponse (le `reply` du hook `Stop`, déjà transporté). Une action *Répondre* avec champ texte (`UNTextInputNotificationAction`) envoie la réponse au thread par `thread.send`. | H | S | Aujourd'hui, le corps est générique : « needs your answer », « finished its turn » (`ThreadNotificationContent.swift:22-25`). Les seules actions sont *Go to thread* et *See delta*. Il faut ouvrir l'app pour savoir s'il faut l'ouvrir. |
| E2 | **Un mode lecture de la réponse.** La dernière réponse de l'agent, rendue en Markdown (titres, tableaux, code) dans la colonne de lecture qui existe déjà pour le diff et les fichiers. Elle s'ouvre par ⌘R ou par un clic sur la ligne du thread. Le terminal reste l'interface, et ceci n'est qu'une vue. [Vibe Island rend les plans en Markdown] | H | M | Les agents rendent des rapports longs, avec tableaux et listes. Un TUI les tronque et les replie : c'est le moment « lire ce qu'il a produit », celui qui coûte le plus aujourd'hui. Aucun rendu Markdown n'existe dans l'app (seul `SettingsView` en utilise). |
| E3 | **Le brief de la task en tête de l'inspecteur**, repliable, avec un lien « ouvrir en lecture ». | M | S | Les briefs font environ 2,6 k caractères de médiane. Ils ne sont visibles qu'au survol, dans `TaskHoverCard`, après 700 ms et tronqués. Or c'est le contrat de la task. |
| E4 | **Une frise de la task** dans sa bande : les tours (start et end, depuis les hooks), le temps de travail des agents contre le temps d'attente de toi, la PR et les checks. On voit d'un coup d'œil « 3 h d'agent, 20 min bloquée sur moi ». | M | M | Répond à « temps passé » et à « où ça a coincé » sans rien demander à l'agent. Les horodatages arrivent déjà au socket (`HookEvent.sentAt`). |
| E5 | **L'arbre de délégation.** Une task créée par une autre task (`origin.ancestors` existe dans le record) s'affiche sous sa parente, ou porte un lien « ouverte par … ». Survoler l'orchestrateur montre ce qu'il a en cours. | M | S | Les tasks s'enchaînent par délégation, mais la sidebar les montre à plat. Le lien parent/enfant est enregistré et jamais dessiné. |
| E6 | **Une fraîcheur explicite** sur les données lues à distance : « checks · il y a 14 min » dans la bande et dans la carte au survol. Un état gris quand la donnée est vieille. | M | S | C'est la conséquence UX directe du constat A4 : un statut périmé affiché comme frais trompe plus qu'un statut absent. |
| E7 | **Ce qui change pendant que tu regardes ailleurs.** Au retour sur un scope ou un thread, un résumé discret « depuis ta dernière visite : 2 tours finis, PR ouverte, checks verts », effacé au premier geste. [Linear, Slack « catch up »] | M | M | Le propriétaire passe de scope en scope. Changer de scope remet bien la sélection, mais ne dit pas ce qui a bougé. |

### Écarté volontairement

- Plus de boutons commit, push ou PR : l'agent s'en charge.
- Une UI de chat : non-objectif.
- Une synchro cloud ou une app iOS : hors périmètre.
- Les réglages d'approbation par commande (allowlist façon Warp) : contraire au principe d'autonomie.

---

## 3. L'IA en continu dans l'app

### Ce qu'elle peut faire d'utile

Les cas sont classés par rapport valeur / coût. Une règle s'applique à tous : **elle ne tourne que sur événement** (`turn.ended`, `input.requested`, `turn.failed`, un thread en `running` depuis plus de N minutes), jamais en boucle.

| Cas | Entrée | Sortie | Qui le fait |
|---|---|---|---|
| **Détecter un thread bloqué** : boucle d'erreurs, retry identique, attente d'une chose impossible | les ~60 dernières lignes du terminal | `{stuck, reason}` | local |
| **Ligne d'activité** enrichie (au-delà de A1) | la queue du terminal | ≤ 8 mots | local |
| **Trier les notifications** : « question bloquante » contre « fin de tour, juste pour info » ; ne notifier que la première catégorie | la dernière réponse (`reply`) | un enum | local |
| **Proposer d'archiver** : PR mergée, ou task « étude » dont la dernière réponse ressemble à un livrable final | la dernière réponse et l'état de la PR | un booléen et une raison | local |
| **Proposer un topic** pour une task neuve, parmi les topics existants du scope | le brief tronqué et la liste des topics | un choix dans une liste fermée | local (le choix contraint marche bien) |
| **Le titre ou le slug** d'une task ou d'un thread | le brief | 2–4 mots en anglais | **Haiku** (le local échoue, voir plus bas) |
| **Le digest de fin de journée** : un paragraphe par scope à partir de `scope summary` et des dernières réponses | plusieurs Ko | du texte | **Haiku** (le contexte local est trop court) |

### Ce que j'ai mesuré : Apple Foundation Models, M1 Max, macOS 26.5

C'est un test de fumée (2 scénarios, 8 appels en tout), pas une évaluation.

- `SystemLanguageModel.default.availability` vaut `available`, et **`contextSize` vaut 4096 tokens**, entrée et sortie confondues.
- **Classification guidée** (`@Generable ThreadDigest { activity, stuck, reason }`) :
  - sur une queue où `swift test` échoue trois fois de suite avec la même erreur : `stuck: true`, raison « dependency file error » ;
  - sur une queue saine (lecture, édition, tests verts) : `stuck: false`, activité « Updating MCP catalogue » ;
  - **juste 8 fois sur 8.**
- Le binaire de test était compilé par `swiftc` et non signé, et le framework a répondu : c'est bon signe pour l'app, qui est signée ad hoc.
- **Latence** :
  - à chaud, environ **0,8–1 s** par appel ;
  - au premier appel d'un processus, de 1,7 s à **12 s** ;
  - `prewarm()` suivi de 3 s d'attente laissait encore un appel à 6,4 s : il ne masque pas tout le démarrage à froid.
  - C'est acceptable sur événement, en tâche de fond. Ce ne l'est pas pour une interaction synchrone.
- **Nommage : échec.** Pour un brief en français, il recopie le français tronqué (« les-tasks-archivées-ne »), même contraint à 2–4 mots. La génération libre ignore la consigne de longueur.

**Conclusion** : le modèle local est bon pour **classer et extraire en sortie structurée**, et mauvais pour **rédiger ou traduire**.

Côté marché : WWDC26 annonce aussi un modèle Private Cloud Compute (32 k de contexte), mais il est hors appareil. MLX ou Ollama avec Qwen3.5-2B/4B ou Gemma 4 E4B tient en environ 3–4 Go de RAM, à environ 30 tok/s de génération et environ 350 tok/s de lecture de prompt sur un M4 de base. Une queue de 4 k tokens y coûte donc environ 12 s : c'est faisable, mais lourd à embarquer.

### Le modèle recommandé : deux étages, pour ne pas vider tes tokens

1. **Étage 0 : Apple Foundation Models (local, gratuit, 0 Mo dans le processus de Scope)** pour tout ce qui est classement : blocage, tri des notifications, activité, proposition d'archivage, choix de topic. Il couvre la grande majorité des appels.
2. **Étage 1 : Haiku**, avec un **nouveau gabarit sans outils** dans le profil (par ex. `headlessAssist` : `claude -p {prompt} --output-format json --model haiku --tools "" --setting-sources "" --strict-mcp-config --no-session-persistence`, avec `{prompt}` avant les flags variadiques, et un `version` du profil bumpé).

   On ne réutilise **pas** `headlessLight` : il autorise `Bash(gh …)` et `Bash(git log …)`, et on lui donnerait de la sortie de terminal non fiable.

   Ce gabarit ne sert que pour :
   - ce que le local rate (titres et slugs, traduction FR → EN) ;
   - ce qui dépasse 4 k tokens (le digest du soir) ;
   - les cas où le local est indisponible (Apple Intelligence désactivé, ou macOS < 26).
3. **Un garde-fou de consommation** :
   - un plafond d'appels Haiku par jour, en préférence (par ex. 40) ;
   - un debounce par thread (au plus 1 appel par tour) ;
   - une entrée tronquée à environ 3 k tokens ;
   - un compteur visible dans A3.

   **Mesuré** : un appel avec le gabarit ci-dessus et une queue de 9,3 k caractères (environ 2,5 k tokens).

   | Mesure | Valeur |
   |---|---|
   | Durée | 2,5 s |
   | Entrée | **≈ 8,1 k tokens** (7 462 en création de cache, 649 lus du cache) |
   | Sortie | 293 tokens |
   | Coût équivalent API | 0,0016 $ |
   | Verdict | juste : `stuck: true`, avec une raison meilleure que le modèle local (« il dit "clean and retry" mais ne nettoie jamais ») |

   **Environ 5 k tokens par appel sont le prompt système de Claude Code lui-même**, même sans outils. Au plafond de 40 appels par jour : environ 330 k tokens et environ 0,07 $ par jour. Ces appels passent par `claude`, donc ils **comptent dans la même fenêtre d'abonnement que tes sessions Opus**.

   Deux leviers pour réduire :
   - n'appeler Haiku qu'en second avis, quand le modèle local dit `stuck` ;
   - ou, si une clé API est configurée, appeler l'API Messages directement (sans les ~5 k de prompt système, hors abonnement).

   Pas d'Ollama ni de MLX par défaut : ce serait un téléchargement de plusieurs Go pour un gain marginal sur cette machine. On peut l'ajouter plus tard comme fournisseur optionnel (« si Ollama répond sur `localhost:11434` »).

### Architecture d'intégration

Elle suit `CLAUDE.md` : la logique testable va dans le package, AppKit et le framework restent dans l'app.

```
ScopeKit (testé)
  Sources/ScopeAssist/
    AssistModel.swift       protocol AssistModel { func classify<T>(…) async throws -> T; var isAvailable: Bool }
    AssistTriggers.swift    pure function: (HookEvent, ThreadState, lastRun) -> AssistJob?
                            debounce per thread, daily cap, "running > N min" detection
    AssistJobs.swift        ThreadDigest, NotificationTriage, ArchiveHint, TopicPick: prompt + schema
    TranscriptTail.swift    last N lines of ThreadTranscript, ANSI stripped, ~3k-token cap,
                            between the untrusted-output markers
    HeadlessAssistModel.swift  calls the profile's headlessLight (Haiku) with a JSON schema
App (not tested)
  App/Scope/Assist/
    FoundationAssistModel.swift   #if canImport(FoundationModels), if #available(macOS 26, *),
                                  availability check, one session per job (4k context)
    AppModel+Assist.swift         subscribes to hook events, runs the jobs at .utility priority,
                                  writes ThreadSession.assistNote (activity line, stuck flag)
```

- **Repli** : `FoundationAssistModel`, puis `HeadlessAssistModel` si la préférence l'autorise, puis rien. La fonction est désactivée sans bruit.
- **Où ça s'affiche** :
  - la ligne d'activité sous le titre du thread (A1) ;
  - un point orange « semble bloqué » qui devient un état d'attention ;
  - les notifications triées ;
  - une proposition d'archivage dans la bande de la task. C'est une proposition, pas une action, sauf la règle déterministe A4.
- **Sécurité** : la sortie de terminal est une donnée non fiable, et le modèle ne déclenche aucune action. Il produit des étiquettes que l'UI affiche.
- **Préférence** : *Settings › Assist* avec trois positions, *Off*, *On-device only* (par défaut) et *On-device + Haiku* (avec le plafond quotidien).

### Prototype minimal (1–2 jours)

Le périmètre est un seul cas : **« ce thread semble bloqué »**, plus la ligne d'activité.

1. `AssistTriggers` : sur `turn.started` sans `turn.ended` depuis plus de 4 min, et ensuite toutes les 4 min au plus, émettre un `AssistJob.digest(thread)`. Le tester comme fonction pure.
2. `FoundationAssistModel.digest(tail:)` : le code ci-dessous, appelé avec les 60 dernières lignes de `ThreadTranscript`.
3. Afficher `activity` en légende de la ligne du thread. Si `stuck`, poser une marque d'attention et envoyer une notification « *Scope · task* semble tourner en rond : *reason* ».
4. Mesurer pendant une semaine (en log local seulement) : appels par jour, latence p50/p95, faux positifs signalés par un bouton « pas bloqué ».

Le code qui a servi au test se compile tel quel avec `swiftc main.swift` sous macOS 26 :

```swift
import Foundation
import FoundationModels

@Generable
struct ThreadDigest {
    @Guide(description: "What the agent is doing right now, max 8 words, present tense, no subject")
    var activity: String
    @Guide(description: "true if the agent is stuck, looping, or waiting on something it cannot get")
    var stuck: Bool
    @Guide(description: "One short reason if stuck, else empty")
    var reason: String
}

let tail = """
⏺ Bash(swift test --filter TaskTopicTests)
  ⎿  error: unable to open dependencies file (.../Scope.build/...)
⏺ The build failed with a dependency file error. Let me retry.
⏺ Bash(swift test --filter TaskTopicTests)
  ⎿  error: unable to open dependencies file (.../Scope.build/...)
"""

let model = SystemLanguageModel.default
guard case .available = model.availability else { print(model.availability); exit(1) }
print("context:", model.contextSize)                       // 4096 on this machine
let session = LanguageModelSession(instructions: "You watch a coding agent's terminal and report on it tersely.")
let start = Date()
let digest = try await session.respond(to: "Terminal tail:\n\(tail)", generating: ThreadDigest.self)
print(Date().timeIntervalSince(start), digest.content)    // ~1 s warm; stuck: true
```

---

## 4. Top 5 pour commencer

| # | Quoi | Effort | Preuve |
|---|---|---|---|
| 1 | **E1 : des notifications avec un extrait et une réponse inline** | S | Le corps actuel est générique. Le `reply` est déjà transporté. Répondre depuis le centre de notifications supprime l'aller-retour vers l'app. |
| 2 | **C1 : `task restore` en CLI et MCP**, et **B1 + B3 : la palette qui parle à l'orchestrateur et agit sur les tasks** | S | Aucune task des records conservés n'est née de la feuille : on passe par un agent ou une commande. Restore n'existe que dans l'UI, et la palette ne sait pas archiver, ranger dans un topic ni envoyer un message. |
| 3 | **A1 : une ligne d'activité par thread**, en version déterministe | S | C'est la question Q4, laissée ouverte par l'IA doc. Les données de `PostToolUse` (`toolName`) arrivent déjà au socket et sont jetées. |
| 4 | **E2 + C2 : le livrable lisible (Markdown) et conservé à l'archivage** | M | Environ la moitié des tasks ouvertes sont des études sans PR. Leur résultat se lit mal dans un TUI et disparaît avec les threads. |
| 5 | **Prototype « thread bloqué »** sur Foundation Models, avec Haiku en second avis plafonné | M | Mesuré : environ 1 s à chaud, 8/8 justes, 0 token. Haiku coûte environ 8 k tokens par appel (mesuré), donc seulement en second avis. |

Juste après : **A4 + E6 (PR rafraîchies en arrière-plan, archivage auto, fraîcheur affichée)**, **A3 (compteur d'usage)** et **A2 (boîte « À traiter »)**. Claude Code a désormais sa propre Agent View, qui recoupe A2 ; l'angle propre à Scope reste le multi-driver et le multi-scope.
