# UI custom ou terminal pour Claude Code dans Scope ?

Recherche du 2026-10-16, sur Scope `40ca4d3` (#64) et Claude Code 2.1.302. Rien n'est implémenté ici.
Sources :

- la doc officielle (`code.claude.com/docs`), le `CHANGELOG.md` public de Claude Code joint aux dates de
  publication npm, les types du paquet `@anthropic-ai/claude-agent-sdk` 0.3.302 (`sdk.d.ts`, 10 128 lignes) ;
- des essais sur cette machine : `claude -p --output-format stream-json --input-format stream-json` piloté par
  un script, les hooks `Stop`/`PostToolUse`/`UserPromptSubmit` capturés sur stdin, les transcripts JSONL
  locaux lus **en agrégats seulement** (types d'enregistrements, clés, versions) ;
- le code de Scope (`Sources/`, `App/`), `SPEC.md`, `CHANGELOG.md`, et les branches citées dans le brief ;
- un sondage des outils tiers (Conductor, Crystal, Claude Squad, Zed/ACP, VS Code, Warp, …).

Les chiffres marqués « mesuré » viennent des essais ou des comptages ; les autres sont des estimations.

---

## 1. Verdict

**Option b, l'hybride : le terminal reste la source de vérité et la seule entrée ; Scope ajoute à côté une
vue de lecture riche, alimentée par les hooks d'abord, par le transcript JSONL ensuite, jamais par le
stream-json.** Pas d'UI custom complète (option c) aujourd'hui, et pas non plus de statu quo pur (option a) :
Scope a déjà fait un tiers du chemin de l'hybride (colonne de lecture Markdown, activité par hook, timeline,
checkpoints) et il reste des gains nets, à coût de maintenance presque nul.

Pourquoi, en quatre faits :

1. **Claude Code sort une version par jour ouvré** (mesuré : 287 versions CLI en 12 mois, ~24/mois ; le SDK
   suit en lockstep, `0.3.302` ↔ `2.1.302`). Le protocole de contrôle du SDK a gagné **+27 sous-types et
   +33 littéraux de type en six mois, sans rien retirer** (mesuré, diff `sdk.d.ts` 0.2.112 → 0.3.301). Une UI
   custom qui veut rendre « tout » court derrière ~10 nouveautés de protocole par mois. C'est exactement
   l'update « tous les deux jours » que tu refuses.
2. **Les hooks, eux, ne changent que par ajout.** 33 événements aujourd'hui, 21 ajoutés en 12 mois, **zéro
   renommage ni suppression** d'événement ou de champ trouvé dans le changelog. Un lecteur tolérant (ignorer
   les clés inconnues) n'a jamais eu à être mis à jour pour continuer à marcher. Scope en consomme 8 et
   tourne depuis la v0.1.0 sur ce principe.
3. **Le TUI reste le seul client complet.** Les mods (panneaux dessinés dans le terminal, v2.1.287+), le mode
   vim, les keybindings, la status line, `/doctor` `/color` `/focus` (`terminal_slash_commands` dans l'init),
   la dictée vocale, les panneaux de sous-agents, le `Ctrl+O`, les suggestions de prompt… n'existent que dans
   le TUI (ou dans les clients d'Anthropic). L'extension VS Code d'Anthropic, qui parle le même protocole
   stream-json qu'un client custom parlerait, a reçu **392 entrées de changelog en 12 mois** : c'est le coût
   réel de « suivre ».
4. **Le terrain commercial bouge sous l'option c.** La doc du SDK interdit « d'offrir le login claude.ai ou
   ses rate limits » dans un produit tiers sans accord ; `--bare` « deviendra le défaut de `-p` » et « ne lit
   jamais les identifiants OAuth ni le trousseau ». Aujourd'hui `-p` marche sur l'abonnement Max (mesuré :
   `account.subscriptionType: "Claude Max"`, `apiProvider: "firstParty"` dans la réponse `initialize`), mais
   bâtir toute l'UI de Scope sur ce chemin, c'est parier sur sa pérennité. Le terminal, lui, est le produit
   qu'Anthropic vend : il ne disparaîtra pas.

La porte vers c n'est pas fermée : le protocole SDK est **conçu pour des clients dégradés** (négociation
`capabilities[]`, `supportedDialogKinds` avec « fail closed » vers le comportement par défaut, `dialog_kind`
transporté « opaquement »). Si un jour Scope veut piloter des threads sans TUI (threads de fond, exécution
headless longue), le protocole est là. Mais c'est un produit en soi, pas une feature.

---

## 2. Les canaux structurés, et leur stabilité

| Canal | Ce qu'il expose | Ce qu'il ne couvre pas | Changements de schéma (12 mois) | Garantie |
|---|---|---|---|---|
| **Hooks** (`settings.hooks`) | 33 événements, JSON sur stdin ; `transcript_path`, `cwd`, `permission_mode`, `effort` partout. `Stop.last_assistant_message`, `PostToolUse.tool_response` (structuré, durée), `SubagentStop.agent_transcript_path`, `PermissionRequest` (peut **répondre** allow/deny), `PreToolUse` sur `AskUserQuestion` (peut répondre via `updatedInput.answers`), `ExitPlanMode.plan`, `Pre/PostModelSwitch`, `Pre/PostCompact`, `UserPromptExpansion` (slash commands), **`MessageDisplay`** (texte de la réponse par lots de lignes pendant le stream, avec `message_id`, `index`, `final`) | Le thinking ; le token par token ; un événement « entrée en plan mode » dédié ; les artefacts (passent par `PreToolUse` générique) | 15 versions ont ajouté des événements, 24 ont ajouté des champs ou valeurs ; **0 renommage, 0 suppression** (hand-classified sur le changelog) | « Agent hooks are experimental and may change. » Rien de plus, mais l'historique est additif |
| **Transcript JSONL** `~/.claude/projects/<slug>/<session>.jsonl` (+ `subagents/agent-<id>.jsonl`) | Tout : `user`, `assistant` (blocs `text`, `tool_use`, `tool_result`, `thinking` signé mais souvent vide, `usage`), `system` (`compact_boundary`, `turn_duration`, `stop_hook_summary`…), `permission-mode`, `file-history-snapshot`, `pr-link`, `cost-state`… **26 types d'enregistrements** mesurés sur cette machine, 20 versions CLI dans l'échantillon | Un format documenté. Les réponses à `AskUserQuestion` et les décisions de permission n'ont pas de type dédié (`permissionDecision` est une clé de `user`) | ~5 versions ont ajouté du contenu, ~8 ont durci les lecteurs contre les lignes malformées. Mesuré : des clés nouvelles presque **à chaque version** (`effort`, `attribution*`, `thinkingDisplay`, `wireToolInputs`…), mais aucune disparue entre 2.1.181 et 2.1.302 | **Négative, explicite** : « The entry format is internal to Claude Code and changes between versions, so scripts that parse these files directly can break on any release. » |
| **`claude -p` stream-json** (entrée et sortie) | `system/init` (modèle, outils, `slash_commands`, `skills`, `capabilities[]`, `permissionMode`), `assistant`/`user` (avec `parent_tool_use_id` pour les sous-agents), `stream_event` (`--include-partial-messages`), `hook_started/response` (`--include-hook-events`), `permission_denied`, `rate_limit_event`, `result` (coût, `permission_denials`). **Protocole de contrôle** : `control_request`/`control_response`, ~70 sous-types (`initialize`, `can_use_tool`, `request_user_dialog`, `interrupt`, `set_model`, `set_permission_mode`, `rewind_files`, `get_context_usage`, `reload_skills`, `mcp_*`…) | Les commandes TUI-only (`/login`, `/doctor`, `/color`, `/focus`) ; le rendu : tout est à réimplémenter | ~8 versions ont touché les champs/flags/sous-types, ~38 ont touché stream-json (surtout des fixes) ; côté types SDK **+27 sous-types, +33 littéraux en 6 mois** | Aucune dans la doc. Détection de features par `capabilities[]` et par le « fail closed » des dialogues |
| **Agent SDK** TS `0.3.x` / Python `0.2.x` | Le stream-json ci-dessus, typé : `canUseTool`, `hooks`, `onUserDialog`+`supportedDialogKinds`, `interrupt()`, `setModel()`, `setPermissionMode()`, `supportedCommands()`, `rewindFiles()`, `getSessionMessages()`, `listSubagents()` ; messages `task_started/progress/notification` pour les sous-agents ; `/bridge` (@alpha) pour Remote Control | Une politique de stabilité. Plusieurs API `@alpha` ; `0.2 → 0.3` = cassant (pré-1.0) | **~26 releases npm/mois** (mesuré : 23 à 30 par mois depuis mars 2026), version = version CLI. 4 entrées cassantes en 12 mois (env, suppression de l'API v2, MCP en arrière-plan, `TodoWrite`→Task, `Agent`↔`Task` renommé puis annulé) | « The SDK version tracks the bundled Claude Code version. » Contrainte CGU : pas de login claude.ai tiers sans accord |
| **Modes serveur / IDE** | Remote Control (HTTPS sortant vers l'API, abonnement seulement), extension VS Code/JetBrains (UI native sur binaire embarqué, **parle stream-json**, changelog 2.1.281), Desktop « Code » | Le protocole filaire de Remote Control ; `--sdk-url` existe mais n'est pas documenté ; le rendu VS Code n'est pas public | Remote Control cité dans 212 entrées, VS Code dans 392 | Aucune |
| **Mods** (plugins JS in-process, v2.1.280+) | Handlers `tool.check`, `prompt.change`, `turn.step`, `agent.spawn`… ; **dessinent des panneaux dans le TUI** | Ce n'est pas un canal externe ; dessin terminal/Desktop/VS Code seulement | API touchée dans 7 des 8 dernières versions | Kill switch distant ; exemples « sans support » |

Ce que les essais locaux ont tranché (reproductibles, scripts dans le scratchpad de la session) :

- `-p --permission-prompts host` **sans** `--permission-prompt-tool stdio` : les permissions sont refusées
  (`system/permission_denied`, `result.permission_denials`), même après un `initialize`. **Avec**
  `--permission-prompt-tool stdio` : `control_request{subtype:"can_use_tool"}` arrive avec `input`,
  `permission_suggestions` (règles, dossiers, `setMode`), `blocked_path` ; répondre
  `{"behavior":"allow","updatedInput":…}` débloque l'outil. C'est ce que fait le SDK.
- Dans ce même mode, `AskUserQuestion`, `EnterPlanMode`, `ExitPlanMode` sont bien dans `init.tools`
  (absents en `-p` nu). `AskUserQuestion` arrive comme `can_use_tool` avec `requires_user_interaction: true` ;
  la réponse se donne via `updatedInput.answers`. `EnterPlanMode` entre en plan mode (`system/status`).
- La réponse à `initialize` liste `commands` (tous les skills/commands avec description), `agents`,
  `models` (13), `account`, `available_output_styles`, `session_state`, `capabilities`. Une UI custom peut
  donc **découvrir** les slash commands et les modèles sans les coder en dur.
- Le hook `Stop` porte bien `last_assistant_message`, `transcript_path`, `background_tasks`,
  `session_crons` ; `PostToolUse` porte `tool_response` structuré et `duration_ms`.

---

## 3. Les options

| Option | Couverture des features | Coût de maintenance | Risque de casse | Effort initial |
|---|---|---|---|---|
| **a. Terminal seul** (statu quo) | 100 %, le jour J | ~0. Le couplage existant tient à six points fragiles (meta-Return, paste bracketé + CR différé, DECSET 2004 comme « prompt prêt », Esc seul = interruption, CR = approbation, thème `-ansi` via `--settings`) qui ont coûté ~1 fix/trimestre (#48, #50, #65) | Faible : ces points ne dépendent pas du schéma, mais du comportement du TUI, qui bouge peu | 0 |
| **b. Hybride** : terminal = entrée + vérité, colonne de lecture riche à côté (Markdown live, outils de la turn, diff, questions) via hooks puis JSONL | Lecture : ~90 % de ce que tu lis (texte, outils, durée, sous-agents, compactions, changement de modèle, plan). Entrée : 100 % (c'est le terminal). Les blocs inconnus s'affichent génériquement | **~0,5 jour/mois** au pire : les hooks ne font qu'ajouter ; le JSONL est lu en tolérant (clé inconnue = ignorée, type inconnu = bloc générique) et seulement pour l'historique | Faible, et **jamais bloquant** : si la vue de lecture se trompe, le terminal est juste à côté, intact. Un bug de lecture ne bloque pas une turn | S + M : la colonne, le parseur Markdown, l'activité et la timeline existent déjà (§5). Reste : flux live (`MessageDisplay`), liste d'outils par turn, blocs génériques, diff |
| **c. UI custom complète** sur stream-json/SDK, repli « ouvrir dans le terminal » | Jour J : permissions, questions, plan mode, slash commands, modèles, sous-agents, interruption, compaction, rewind (tout est dans le protocole). **Jamais** : mods/panneaux, vim, keybindings, status line, voix, `terminal_slash_commands`. Chaque nouveauté arrive « cassée » ou en mode dégradé jusqu'à l'update | **2 à 4 jours/mois** si tu suis : ~26 releases SDK/mois, ~10 ajouts de protocole/mois, 4 cassures/an ; le rendu de chaque nouvel outil (diff d'`Edit`, résultats d'`Agent`, `Artifact`, `Workflow`…) est à écrire. Anthropic y met l'équivalent d'une release VS Code par jour | **Moyen à élevé** : une cassure du protocole ou un `--bare`/OAuth qui change bloque **l'entrée**, pas seulement la lecture. Le repli terminal veut dire relancer la session (`--resume`) dans un PTY : faisable, mais c'est deux UIs à maintenir | **2 à 3 mois** plein temps pour atteindre l'extension VS Code d'il y a un an ; Swift n'a pas de SDK officiel, il faut écrire le client du protocole |
| **d. Protocole tiers** (ACP de Zed via `claude-code-acp`) | Ce que l'adaptateur mappe : prompts, outils, permissions, modes, plans, terminaux. Les nouveautés passent par deux filtres (Anthropic → adaptateur → ACP) | Délégué à l'adaptateur, mais tu en hérites les lacunes et tu dépends d'un tiers pour chaque feature | Moyen : deux chaînes de versions | Moyen : un client ACP en Swift n'existe pas |

Les coûts de c sont des estimations. Le seul chiffre mesuré derrière est le rythme d'Anthropic (§1) ; la
traduction en jours suppose qu'un propriétaire seul veut rester à moins d'un mois de retard.

---

## 4. Ce qu'une UI custom perdrait face au TUI

Perdu définitivement (TUI-only, mesuré dans `init.terminal_slash_commands`, la doc des mods, `--help`) :

- les **mods** et leurs panneaux (bande au-dessus du prompt, panes, toasts) ; ils dessinent dans le terminal,
  Desktop et VS Code seulement, et c'est là que va l'extensibilité de Claude Code depuis 2.1.280 ;
- le mode **vim**, les **keybindings** (`~/.claude/keybindings.json`), la **status line**, les thèmes ;
- `/doctor`, `/color`, `/focus`, `/reload-plugins`, `/login`, le mode `!` bash ;
- la **dictée vocale** (2.1.280), les **suggestions de prompt**, le `@`-mention avec complétion (un
  `file_suggestions` existe côté contrôle, mais la complétion est à refaire) ;
- l'affichage **Ctrl+O** du transcript, les panneaux de **sous-agents**/teammates, le `Ctrl+B` background ;
- le rendu natif de chaque outil : le diff coloré d'`Edit`, le tableau d'`AskUserQuestion`, la vue plan,
  le spinner et ses verbes, l'affichage du thinking.

Perdu « jusqu'à la prochaine update », soit en permanence vu le rythme :

- chaque nouvel outil built-in (12 derniers mois : `Artifact`, `Workflow`, `Monitor`, `ScheduleWakeup`,
  `EnterWorktree`, `ReportFindings`, `SendMessage`, `ListAgents`, `LSP`…) arrive en « bloc générique » ;
- chaque nouveau `dialog_kind` de `request_user_dialog` est **refusé par défaut** tant que l'UI ne le déclare
  pas (`supportedDialogKinds`) : le flux se dégrade (c'est voulu), mais l'utilisateur ne voit rien ;
- chaque nouveau message système (`tool_use_summary`, `memory_recall`, `prompt_suggestion`,
  `model_refusal_fallback`… 40 types dans `SDKMessage` aujourd'hui).

Et un risque structurel : si `--bare` devient le défaut de `-p` et que le chemin OAuth se ferme aux clients
tiers, l'UI custom perd l'abonnement Max. Le terminal, non.

---

## 5. Ce que Scope a déjà

Tout ceci est **sur `main`** (les huit branches du brief sont squash-mergées, v0.21.0 à v0.23.0) :

| Brique | Où | Ce qu'elle donne à l'hybride |
|---|---|---|
| Pipeline de hooks | `Sources/ScopeDrivers/ClaudeHooksAdapter.swift`, `Sources/scope-hook/main.swift`, `Sources/ScopeAdapters/{HookStdin,HookEvent,ThreadActivity,ThreadStateMachine}.swift` | 8 hooks consommés (`SessionStart`, `UserPromptSubmit`, `PreToolUse` sur `AskUserQuestion\|ExitPlanMode`, `PostToolUse`, `Notification`, `Stop`, `StopFailure`, `SessionEnd`) ; `raw` complet (≤ 256 Ko) transporté sur la socket ; `ThreadActivity` garde outil, cible, question, 200 turns, `lastReply` (16 Ko), `transcriptPath` |
| Colonne de lecture Markdown | `Sources/ScopeCore/Markdown/MarkdownDocument.swift` (parseur CommonMark maison, testé), `App/Scope/Views/Inspector/Reading/{MarkdownReader,ReadingViewer}.swift`, `ReadingContent` (`.reply`, `.deliverable`, `.brief`, `.checkpoint`) | Le rendu « réponse » existe (#54, #61). Pas de bloc inconnu : tout ce qui n'est pas reconnu devient paragraphe |
| Activité, timeline, inbox | `ThreadActivityHeadline`, `Sources/ScopeTasks/{TaskTimeline,Inbox}.swift`, `TaskTimelineView` | « Editing X.swift », « Finished · 3 min », questions en attente avec champ de réponse, une piste par thread |
| Checkpoints par turn (#64) | `Sources/ScopeTasks/TaskCheckpoints.swift`, `AppModel+Checkpoints` | Le **diff par turn** existe déjà, nommé par la réponse |
| Réponse sans changer de thread (#43, #40) | `MessageComposer`, `InlineReplyRow`, `UNTextInputNotificationAction` | Une entrée native qui **tape dans le PTY**, gated sur le paste bracketé |
| Lecture du transcript | `Sources/ScopeAdapters/TranscriptUsage.swift` | Lecture incrémentale par offset, pré-filtre `"type":"assistant"`, décode 5 clés seulement, lit aussi `subgents/*.jsonl`. **Le squelette d'un lecteur tolérant est là** |
| Headless | `HeadlessDriver.swift`, templates `headless`/`headlessLight`/`headlessAssist` | `--output-format json` seulement, pas de stream-json, un seul envelope lu. Aucun client du protocole de contrôle |
| `thread.read` / `thread.wait` | `AppControlService.swift`, `ThreadWait.swift` | `view: reply` = `lastReply` ; `view: terminal` = scrape du buffer SwiftTerm |

Ce que `SPEC.md` dit, et qu'il faudra amender si b est retenu : principe 5 « **Le terminal est l'interface
de l'agent.** Pas de chat UI, pas de wrapper. Scope ajoute du contexte autour, pas au milieu » et §8 « Pas de
chat UI ». L'hybride respecte la lettre (le terminal reste l'interface, la lecture est « autour ») ; la
phrase « heuristique regex sur la sortie » de §4.7 décrit quelque chose qui n'existe pas dans le code.

Ce qui manque pour l'hybride, et seulement ça :

1. le **texte live** de la réponse (aujourd'hui `lastReply` n'arrive qu'au `Stop`) ;
2. la **liste des outils d'une turn** avec cible et durée (aujourd'hui un compteur et le dernier outil) ;
3. un **bloc générique** dans `MarkdownDocument`/`MarkdownReader` pour l'inconnu ;
4. la lecture **historique** d'une session (les turns précédentes, les sous-agents) depuis le JSONL, en
   tolérant.

---

## 6. Le principe « dégradé mais correct »

Ce qui fait qu'une vue de lecture n'a pas besoin d'update à chaque release :

- **Vérité = terminal.** La vue de lecture ne décide rien, ne répond à rien, ne bloque rien. Une turn qui
  n'est pas comprise par la vue est quand même visible, entière, dans la scène. Chaque élément de lecture
  porte un lien « voir dans le terminal » (déjà le cas : la scène est à côté).
- **Lecteur tolérant, pas validateur.** Décoder par clé, jamais par schéma complet : `type` inconnu →
  ignoré (JSONL) ou bloc générique « `<type>` » avec le JSON replié (stream, si un jour) ; clé inconnue →
  ignorée ; clé attendue absente → valeur par défaut, jamais une erreur. `TranscriptUsage` fait déjà ça.
  Mesuré : entre 2.1.181 et 2.1.302, 20 versions, le JSONL a **ajouté** des clés à chaque version et n'en a
  retiré aucune ; un tel lecteur n'aurait rien eu à changer.
- **Rendu par famille, pas par nom.** Un `tool_use` se rend comme « nom + cible + durée + résultat replié »,
  quel que soit le nom ; `HookStdin.toolTarget` a déjà la table nom → clé de cible (12 outils), avec un défaut
  (première chaîne courte) pour les autres. Un outil inconnu s'affiche correctement, juste sans cible jolie.
  Les trois seuls outils à rendu spécial restent `Edit` (diff), `AskUserQuestion` (options) et `ExitPlanMode`
  (plan), et ils sont déjà extraits par `HookStdin.question`.
- **Blocs Markdown inconnus.** Ajouter un cas `.raw(text)` à `MarkdownDocument` (HTML, images, directives,
  tout ce qui n'est pas CommonMark) rendu en préformaté, plutôt que de le fondre en paragraphe.
- **Hooks par adjonction.** Les nouveaux événements (`MessageDisplay`, `Pre/PostModelSwitch`,
  `PostCompact`, `SubagentStop`) peuvent être installés sans détection de version : un événement inconnu
  d'une vieille version est ignoré avec un avertissement et le reste du fichier s'applique (mesuré sur 2.1.302 :
  « Unknown hook event "…" was ignored … the rest of each file is in effect »). Installer, et recevoir ou pas.
- **Rien dans le chemin d'entrée.** Tant que la saisie passe par le PTY, aucune évolution de protocole ne
  peut empêcher d'envoyer un message. C'est la propriété que l'option c perd.

---

## 7. Ce que font les autres

| Outil | Approche | Canal | Blocs inconnus / repli | Ce que coûte le suivi (observé) |
|---|---|---|---|---|
| **Warp** (Oz) | **Hybride** : vrai TUI dans un pane + chrome riche (éditeur de prompt, revue de code inline renvoyée à l'agent, statut dans les onglets, Remote Control) | PTY + plugin de hooks `warpdotdev/claude-code-warp` (`SessionStart`, `UserPromptSubmit`, `PostToolUse`, `Stop` qui lit le JSONL pour extraire prompt + réponse, `Notification`, `PermissionRequest`) émis en OSC 777 avec version de protocole négociée | Rien à rendre : la nouveauté apparaît dans le TUI | Plugin versionné à part, « reinstall » si dépassé. Même modèle pour Codex et OpenCode |
| **Emdash** (YC W26) | Hybride à deux voies : TUI (node-pty + xterm) **ou** ACP pour les agents qui le parlent | PTY + hooks pour le statut (« n'infère jamais l'état depuis la sortie terminal »), ACP sinon | Voie TUI : rien ; voie ACP : hérite des trous de l'adaptateur | Leur argument marketing : « vous avez toujours la dernière version sans attendre une mise à jour d'Emdash » |
| **Superset** | Terminal (xterm.js) + panneaux diff/PR/éditeur/navigateur | PTY + hooks installés dans la config de chaque agent | Rien | Aucune note de compat trouvée en 15k étoiles |
| **Claude Squad** | Pur tmux + onglet diff (`git diff` toutes les 500 ms) | PTY seul | Rien | Un seul couplage : `--autoyes` greppe la phrase du prompt de permission |
| **Zed** via `claude-agent-acp` (ex `zed-industries/claude-code-acp`) | UI custom à travers ACP, adaptateur sur l'Agent SDK, maintenu par Zed/JetBrains, **pas** par Anthropic (demande ACP fermée « not planned », anthropics/claude-code#6686) | SDK → ACP JSON-RPC : `canUseTool`→`request_permission`, modes, slash commands depuis `initialize`, thinking, sous-agents en sessions filles | Types SDK inconnus → no-op. `AskUserQuestion` **désactivé** (« pas de bonne façon de l'exposer »), plan mode arrivé après le lancement, `session/load` ne rejoue que depuis la dernière compaction, sous-agents ni pilotables ni annulables | **10 releases en 16 jours** (0.85 → 0.92), dont 4 « bump SDK » ; 88 issues ouvertes, 56 PR. Repli : « Terminal Threads » (TUI, détection par BEL + titre seulement) |
| **Conductor** | UI chat custom sur l'Agent SDK, terminal en option (« Big Terminal Mode ») | SDK, binaire Claude Code embarqué | Blocs natifs pour plan, `AskUserQuestion`, approbations ; le reste → mode terminal | ~2 releases/semaine ; pins SDK explicites dans le changelog ; plusieurs fixes de compat (sous-agents bloqués sur approbation, timeouts rendus comme refus, auth qui redéclenche les hooks). Closed source |
| **claudecodeui** (siteboon) | UI web custom sur l'Agent SDK + shell xterm | SDK (`canUseTool`, `AskUserQuestion` en panneau, plan = allowlist) | Catégorie `default` pour les outils inconnus | Issues récentes = exactement « feature nouvelle pas atteignable » : plan mode introuvable (#1593), `claude --bg` qui forke (#1536), sous-agents (#1594), `--model` (#1543) |
| **Happy** | **Les deux** : TUI passthrough en local, UI custom sur SDK pour le mobile | fd 3 en local ; SDK en distant | Types inconnus loggés, pas affichés ; le repli = revenir au TUI | `--effort ultracode` → ZodError (#1878), `--remote-control` ignoré sous stream-json (#1859), `--plugin-dir` perdu (#1793), sandbox non appliqué (#1894) : tous en 6 semaines |
| **Vibe Kanban** | UI custom stream-json, **CLI épinglé** (`npx claude-code@2.1.119`) | stream-json + `--permission-prompt-tool stdio` + hooks | `ClaudeToolData::Unknown` → bloc générique | L'épingle est le coût : « tente d'installer claude-code@2.1.62 inexistant », hooks projet écrasés par `initialize`, effort `max` absent, 167 issues « claude code » |
| **Crystal**, **opcode/Claudia**, **Terragon** | UI custom stream-json / cloud | stream-json, `--dangerously-skip-permissions` | opcode : nom + JSON brut en `<pre>` | **Les trois sont morts** (Crystal → Nimbalyst qui embarque ghostty ; opcode sans commit depuis oct. 2025 ; Terragon « Shutdown ») |
| **VS Code / Desktop** (Anthropic) | UI custom, repli « Use Terminal » sur la même session | stream-json, binaire embarqué | Doc officielle : « Some features are only available in the CLI… run `claude` in the integrated terminal ». Même chez Anthropic, des features sont gated par version CLI (LaTeX ≥ 2.1.301) et `dontAsk`, ⇧Tab, `/plugin`, `/resume` manquent dans Desktop/cloud | 392 entrées de changelog en 12 mois |

Lecture : **tout ce qui embarque le TUI est immunisé par construction** et ne couple que le statut (hooks,
BEL, titre, `git diff`). **Toute UI custom survivante épingle une version et ship des bumps en continu, ou
s'appelle Anthropic.** Les trois projets morts sont des UIs custom. Les hybrides (Warp, Emdash, Superset,
Claude Squad) ne re-rendent jamais les messages de Claude depuis le stream : ils rendent l'état git et les
événements de hook, les deux canaux sur lesquels personne ne rapporte de casse. Warp est le modèle le plus
proche de ce que Scope a déjà commencé, jusqu'au `Stop` qui lit le JSONL pour la réponse.

---

## 8. Plan

Chaque étape est livrable seule et laisse le terminal intact.

**S. Réponse en direct dans la colonne de lecture** (premier pas, ~1 jour)
Installer le hook `MessageDisplay` dans `ClaudeHooksAdapter` (événement `turn.said`, payload `message_id`,
`index`, `final`, texte) ; `ThreadActivity` accumule les deltas de la turn ouverte dans `lastReply` ;
`ReadingViewer` sur `.reply` se met à jour pendant que l'agent écrit. Le `Stop` continue de poser la version
finale (`last_assistant_message`), donc un CLI sans `MessageDisplay` (< 2.1.152) se comporte comme
aujourd'hui. Zéro nouveau parseur. Test : `swift test --filter HookStdinTests` + ouvrir ⇧⌘R pendant une turn.

**M1. Les outils d'une turn** (~2 jours)
`ThreadActivity.Turn` garde la liste `[(tool, target, durationMs, isError)]` depuis `PostToolUse`
(`duration_ms`, `tool_response.is_error`), plafonnée (200 par turn). La colonne de lecture affiche cette liste
repliée au-dessus de la réponse, un outil inconnu = nom + cible générique. `SubagentStop` ajoute une ligne
« sous-agent · n outils » avec `agent_transcript_path` pour M3. La timeline de task réutilise la liste.

**M2. Bloc générique et diff** (~2 jours)
`MarkdownDocument.Block.raw` pour l'inconnu ; le diff du checkpoint de la turn (#64, déjà calculé) montré
sous la réponse, par fichier, replié. C'est le « diff » de l'hybride, sans lire aucun `Edit`.

**M3. Historique d'une session en lecture** (~3 jours, le seul morceau qui touche au JSONL)
Un `TranscriptReader` à côté de `TranscriptUsage` : lecture incrémentale, décode `type`, `uuid`,
`parentUuid`, `timestamp`, `message.content[]` (`text`, `tool_use.name/input`, `tool_result`), ignore tout
le reste. Rend les turns précédentes dans la colonne de lecture, et les sous-agents via `subagents/`. Sur
JSONL illisible : la vue dit « historique indisponible » et montre la dernière réponse par hook. Ne jamais en
faire dépendre `thread.wait` ni l'état.

**L (optionnel, plus tard, séparément). Un driver `claude-code-sdk` pour les threads sans écran.**
Un client Swift du protocole de contrôle (`initialize`, `can_use_tool`, `interrupt`, `set_model`), utilisé
d'abord pour les microsessions et les threads de fond où personne ne regarde le terminal. C'est là qu'on
apprend le vrai coût du protocole, sans mettre l'UI principale en jeu. Si après trois mois le driver n'a pas
demandé plus d'un fix par mois, la question de c peut être rouverte avec des chiffres à soi.

À ne pas faire : remplacer l'entrée PTY par stream-json ; parser le JSONL pour l'état d'un thread ; rendre
chaque outil par son nom.

---

## Annexe A. Mesures brutes

| Mesure | Valeur | Source |
|---|---|---|
| Versions CLI publiées, 12 mois | 287 (~24/mois) | npm `@anthropic-ai/claude-code` × `CHANGELOG.md` |
| Versions SDK TS, par mois (mars→sept. 2026) | 23, 29, 27, 30, 23, 29, 27 | npm `@anthropic-ai/claude-agent-sdk` |
| Événements de hook | 33 (SDK types : 33 ; Scope en consomme 8) | `sdk.d.ts` `HookEvent`, `ClaudeHooksAdapter.swift` |
| Événements de hook ajoutés, 12 mois | 21 ; renommés ou retirés : 0 | changelog, classement manuel |
| Sous-types `control_request/response` | ~70 ; +27 en 6 mois, 0 retirés | `sdk.d.ts` 0.2.112 vs 0.3.301 |
| Types de `SDKMessage` | 40 | `sdk.d.ts` |
| Types d'enregistrements JSONL observés | 26 ; `system.subtype` : 6 | 177 transcripts locaux, agrégats |
| Clés top-level d'`assistant` | 37 ; d'`user` : 45 | idem |
| Versions CLI dans les transcripts locaux | 20 (2.1.181 → 2.1.302), clés ajoutées à chaque, aucune retirée | idem |
| Blocs de contenu observés | `tool_use`, `tool_result`, `thinking`, `text`, `tool_addition`, `server_tool_use`, `advisor_tool_result`, `image` | idem |
| Entrées changelog VS Code, 12 mois | 392 ; Remote Control : 212 | changelog, regex |
| Entrées cassantes SDK TS, 12 mois | 4 | `claude-agent-sdk-typescript/CHANGELOG.md` |

## Annexe B. Essais stream-json (reproductibles)

Script : un `Popen` de `claude -p --output-format stream-json --input-format stream-json --verbose
--permission-mode default --permission-prompts host --permission-prompt-tool stdio --include-hook-events`,
qui envoie `control_request{subtype:"initialize"}` puis un message `user`, et répond à chaque
`control_request` par `control_response{behavior:"allow", updatedInput}`.

| Essai | Observé |
|---|---|
| `-p` nu, `Write hello.txt` | `init` → `assistant(thinking, tool_use)` → `user(tool_result)` → `assistant(text)` → `result` ; fichier écrit (settings de l'utilisateur) |
| `--permission-prompts host` seul, `touch` | `system/permission_denied`, `result.permission_denials=[Bash]`, aucun `control_request` |
| + `--permission-prompt-tool stdio`, `touch` | `control_request can_use_tool` avec `permission_suggestions` (addRules, addDirectories, setMode) et `blocked_path` ; après `allow`, le fichier existe |
| idem, `AskUserQuestion` + `EnterPlanMode` | les deux outils présents dans `init.tools` ; `can_use_tool` avec `requires_user_interaction: true` ; `allow` sans `answers` → « The user did not answer » ; `EnterPlanMode` → `system/status` + plan mode actif |
| `initialize` response | `commands` (62, avec descriptions), `agents` (5), `models` (13), `account`, `available_output_styles`, `session_state`, `capabilities`, `remote_control_available` |
| hooks `Stop` / `PostToolUse` / `UserPromptSubmit` sur stdin | `Stop`: `last_assistant_message`, `transcript_path`, `background_tasks`, `session_crons`, `effort`, `permission_mode` ; `PostToolUse`: `tool_response` structuré, `duration_ms`, `tool_use_id` |
