# Scope Claude-native : ce que Claude Code expose, et ce que Scope en fait

Recherche du 2026-10-20, sur Scope `5ee1298` (PR 85) et Claude Code 2.1.304. Sert de base au chantier
« Claude-native » : Scope se concentre désormais sur Claude Code (SPEC §1, §5), et une feature n'a plus besoin
d'exister pour les autres drivers pour être livrée.

Sources :

- la doc officielle (`code.claude.com/docs` : *hooks*, *statusline*, *tools-reference*, *sub-agents*,
  *agent-sdk/typescript*, *headless*, *plugins/mods*, *channels-reference*, *cross-session-messaging*) et le
  `CHANGELOG.md` public de Claude Code, lu sur six mois ;
- `claude --help`, `claude agents --json`, `claude mcp --help` sur cette machine ;
- 236 transcripts JSONL locaux (187 principaux, 49 de sous-agents, ~202 000 lignes, Claude Code 2.1.181 →
  2.1.304), lus **en agrégats seulement** : types d'enregistrements, clés, valeurs d'énumération, comptes. Aucun
  contenu (prompt, code, chemin, nom de serveur ou de skill) n'est recopié ici. Les fixtures de test qui en sont
  tirées remplacent chaque chaîne par un marqueur (`<text>`, `<id>`, `<path>`).

Étiquettes de stabilité : **doc** = documenté, contrat public ; **obs** = observé dans les transcripts ou les
fichiers, non documenté, peut changer sans préavis — à lire comme un indice, jamais comme un contrat, et à
parser de façon tolérante (champ ou type inconnu ignoré).

---

## 1. Les sources

### 1.1 Hooks (doc)

Scope installe aujourd'hui `SessionStart`, `UserPromptSubmit`, `PreToolUse` (`AskUserQuestion|ExitPlanMode`),
`PostToolUse`, `Notification` (permission, question, élicitation), `Stop`, `StopFailure`, `SessionEnd`,
`MessageDisplay`, `SubagentStart`, `SubagentStop`, et la *status line* (`ClaudeHooksAdapter.entries`).

Champs communs à tous les événements : `session_id`, `prompt_id`, `transcript_path`, `cwd`, `hook_event_name`,
`permission_mode` (`default|plan|acceptEdits|auto|dontAsk|bypassPermissions`), `effort.level` (dans un
contexte d'outil), `agent_id` / `agent_type` quand le hook part d'un sous-agent.

| Événement | Ce qu'il apporte en plus | Installé ? |
|---|---|---|
| `SessionStart` | `source` (`startup\|resume\|clear\|compact\|fork`), `model`, `agent_type` ; à la reprise : `context_tokens`, `seconds_since_last_response`, `prompt_cache_likely_expired` | oui (id de reprise seulement) |
| `UserPromptSubmit` | `prompt` — part aussi pour `/loop`, un cron, **le rapport d'un sous-agent en arrière-plan** (le texte est une `<task-notification>`), un message d'une autre session | oui |
| `PreToolUse` | `tool_name`, `tool_input`, `tool_use_id`, `mcp_server {name, source}` ; peut répondre `allow\|deny\|ask` et **`updatedInput`** | oui, matcher questions seulement |
| `PermissionRequest` | `tool_name`, `tool_input`, `permission_suggestions[]` — **part immédiatement**, avant la boîte ; peut répondre `allow\|deny` à la place de l'utilisateur | non, volontairement (SPEC §4.7) |
| `PermissionDenied` | refus du classifieur du mode auto : `tool_name`, `tool_input`, `reason` | non |
| `PostToolUse` | `tool_response` **structuré** (voir 1.2), `tool_use_id`, `duration_ms` | oui, cible et durée seulement |
| `PostToolUseFailure` | `error` (`Exit code N` pour Bash), `is_interrupt` | non |
| `Notification` | `notification_type` : `permission_prompt` (~6 s), `idle_prompt`, `elicitation_*`, `agent_needs_input`, `agent_completed`, `quota_auto_resume_*`, `auth_success` | oui |
| `SubagentStart` | `agent_id`, `agent_type` | oui, compte seulement |
| `SubagentStop` | `agent_id`, `agent_type`, `agent_transcript_path`, `last_assistant_message`, `background_tasks[]`, `session_crons[]` | oui, compte seulement |
| `Stop` | `last_assistant_message`, **`background_tasks[]`** `{id, type: shell\|subagent\|monitor\|workflow\|teammate\|…, status, description, command?, agent_type?}`, **`session_crons[]`** `{id, schedule, recurring, prompt}` | oui, réponse seulement |
| `StopFailure` | `error` : `rate_limit\|overloaded\|authentication_failed\|billing_error\|server_error\|max_output_tokens\|…` | oui |
| `TaskCreated` / `TaskCompleted` | `task_id`, `task_subject`, `task_description` | non (pris par la carte Plan, chantier UI) |
| `PreCompact` / `PostCompact` | `trigger` (`manual\|auto`, l'auto inclut la compaction au repos), `custom_instructions` / `compact_summary` | non |
| `PreModelSwitch` / `PostModelSwitch` | `from_model`, `to_model`, `source`, `context_tokens`, `estimated_cache_write_usd` | non |
| `Elicitation` / `ElicitationResult` | un serveur MCP demande une saisie : `mcp_server_name`, `message`, `mode`, `url`, `requested_schema` ; peut répondre `accept\|decline\|cancel` | non (la notification `elicitation_dialog` l'est) |
| `ConfigChange`, `CwdChanged`, `FileChanged`, `DirectoryAdded`, `InstructionsLoaded` | réglages ou skills modifiés, `cd`, fichier surveillé, `/add-dir`, CLAUDE.md chargé | non |
| `WorktreeCreate` / `WorktreeRemove` | worktree créé par l'agent (`EnterWorktree`, `isolation: worktree`) — le hook **remplace** le comportement de git | non, et à ne pas installer |
| `UserPromptExpansion` | slash command ou skill tapé : `command_name`, `command_args`, `command_source` | non |
| `PostToolBatch` | une fois par lot d'appels parallèles | non |
| `MessageDisplay` | la réponse en cours d'écriture | oui |

### 1.2 Résultats d'outils (`PostToolUse.tool_response`, doc + obs)

| Outil | Entrée utile | Résultat utile |
|---|---|---|
| `Agent` (ex-`Task`) | `description`, `subagent_type`, `model`, `run_in_background`, `isolation` | en arrière-plan (cas par défaut depuis 2.1.198) : `status: async_launched`, **`agentId`**, `outputFile`, `resolvedModel` ; synchrone : `totalTokens`, `totalDurationMs`, `totalToolUseCount`, `toolStats` |
| `Bash` | `command`, `description`, `run_in_background` | `backgroundTaskId` (préfixe `b`), `timedOutAfterMs` (passée en arrière-plan sur timeout), `persistedOutputPath`, `bashEditDiff` (fichiers modifiés par la commande), **`gitOperation`** `{commit, push, branch, pr{action, number, url}}` |
| `Monitor` | `command` ou `ws`, `description`, `timeout_ms` (≤ 30 min) | `taskId`, `timeoutMs`, `persistent` |
| `TaskStop` (ex-`KillShell`) | `task_id` | `task_type`, `command` |
| `ScheduleWakeup` | `delaySeconds`, `reason`, `prompt` | `scheduledFor` (epoch ms), `stopped` |
| `CronCreate` / `CronDelete` / `CronList` | `cron`, `prompt`, `recurring`, `durable` | `id`, `humanSchedule` |
| `AskUserQuestion` | `questions[{question, header, multiSelect, options[{label, description, preview}]}]` | `answers{question: label}`, `annotations` |
| `ExitPlanMode` / `EnterPlanMode` | `plan`, `planFilePath` | `planWasEdited` |
| `Skill` | `skill`, `args` | `commandName`, `status: forked` + `agentId` pour un skill forké |
| `EnterWorktree` / `ExitWorktree` | `name` / `action: keep\|remove` | `worktreePath`, `worktreeBranch` |
| `Workflow` | `script`/`name` | `taskId`, `runId`, `transcriptDir` |
| `mcp__<serveur>__<outil>` | — | `mcp_server.source` dans le hook ; un appel long passe en arrière-plan (tâche `k…`) |

`TaskOutput` / `BashOutput` n'existent plus (2.1.277) : Claude relit `outputFile`. Aucun hook ne part quand un
shell ou un Monitor en arrière-plan se termine.

### 1.3 Transcript JSONL (obs)

`<projet>/<session>.jsonl`, et pour chaque sous-agent `<projet>/<session>/subagents/agent-<agentId>.jsonl` +
`agent-<agentId>.meta.json` (`agentType`, `description`, `toolUseId`, `spawnDepth`, `model`, `isFork`,
`worktreePath`, `finished`, `name`). L'`agentId` du fichier = l'`agent_id` des hooks = l'`agentId` du résultat
de l'outil (48 sur 51 vérifiés ; les 3 autres sont des forks).

| Enregistrement | Contenu utile |
|---|---|
| `user` avec `origin.kind: task-notification` | **fin d'une tâche de fond** : `<task-notification>` avec `task-id`, `tool-use-id`, `output-file`, `status` (`completed\|failed\|killed\|stopped`), `summary`, et pour un sous-agent `result`, `usage{subagent_tokens, tool_uses, duration_ms}`, `worktree`. Un `Monitor` y pousse ses événements (`event`). **Écrit trois fois** (queue-operation, attachment `queued_command`, message) : dédoublonner par `task-id` |
| `attachment` `task_status` | état d'une tâche de fond : `taskId`, `taskType` (`local_bash\|local_agent`), `status`, `description`, `outputFilePath`, `deltaSummary` |
| `attachment` `deferred_tools_delta` | **état des serveurs MCP** : `pendingMcpServers[]`, `failedMcpServers[{name, error, errorCode}]`, `needsAuthMcpServers[]` |
| `system` `compact_boundary` | `compactMetadata{trigger, preTokens, postTokens, durationMs}` |
| `system` `turn_duration` | `durationMs`, `messageCount`, `pendingBackgroundAgentCount` |
| `system` `stop_hook_summary` | hooks de l'utilisateur lancés au Stop : `hookCount`, `hookInfos[{command, durationMs}]`, `hookErrors[]` |
| `attachment` `hook_success` / `hook_non_blocking_error` | chaque hook de l'utilisateur qui a tourné, son code de sortie, sa durée |
| `permission-mode` | `permissionMode` à chaque changement (`auto`, `bypassPermissions`, `acceptEdits`, `default`, `plan`) |
| `user.permissionDecision` | après coup : `decision` (`accept\|reject\|cancelled`), `source` (`config\|hook\|user_*`), `reasonType` ; `toolDenialKind` |
| `pr-link` | `prNumber`, `prUrl`, `prRepository` |
| `cost-state` | `totalCostUSD`, durées API / outils, `totalLinesAdded/Removed`, `modelUsage` par modèle |
| `frame-link` | artifacts publiés : `frameUrl`, `title`, `artifactCount` |
| `assistant` | `message.model`, `effort`, `message.usage`, `isApiErrorMessage` + `error` |
| `attachment` `plan_mode` / `plan_mode_exit` | entrée et sortie du mode plan, `planFilePath` |
| `attachment` `invoked_skills`, `skill_listing` | skills invoqués / disponibles |
| `ai-title`, `custom-title`, `agent-name`, `last-prompt`, `queue-operation`, `file-history-*` | titre, nom, dernier prompt, file d'attente, checkpoints de Claude Code |

Absents du corpus : `progress`, `summary`, `api_error` en sous-type système, toute trace de rate limit ou de
retry (seul `cost-state.totalAPIDurationWithoutRetries` les trahit).

### 1.4 Status line (doc)

Déjà relayée par `scope-hook statusline` (PR 79), qui n'en lit que `rate_limits`. Elle porte aussi `model`,
`context_window{used_percentage, context_window_size, current_usage}` (lu par la carte Context du chantier UI),
`cost{total_cost_usd, total_lines_added, …}`, `effort.level`, `thinking.enabled`, `fast_mode`, `output_style`,
`pr{number, url, review_state}`, `worktree`, `prompt_cache`, `agent.name`. Elle tourne à chaque message de
l'assistant, après une compaction, à un changement de mode de permission ; muette au repos.

`subagentStatusLine` (doc, 2.1.214) : une commande appelée à chaque tick avec `tasks[{id, agentType, status,
description, label, startTime, model, effort, tokenCount}]` — un flux vivant par sous-agent. Un seul réglage :
Scope devrait envelopper celui de l'utilisateur, comme pour `statusLine`.

### 1.5 Hors session

- **`claude agents --json`** (doc, 2.1.145) : chaque session vivante, interactives comprises, avec `pid`,
  `sessionId`, `status` (`busy|waiting|idle`) et **`waitingFor`** (`permission prompt`, `input needed`,
  `dialog open`…) — immédiat, là où la notification `permission_prompt` attend ~6 s.
- `~/.claude.json` (lecture seule) : serveurs MCP déclarés (user, projet), compte (`oauthAccount`, déjà lu).
- `claude mcp list` : vérifie la config du dossier en relançant les serveurs ; ne dit rien de la session vivante.
- `--output-format stream-json` / Agent SDK : `system/init` (serveurs MCP et leur `status`, outils, slash
  commands, skills, mode), `task_started/updated/notification`, `background_tasks_changed`,
  `compact_boundary`, `session_state_changed`… **inaccessible à une session interactive** dans un PTY.

### 1.6 Agir sur une session sans taper dans le terminal

| Voie | Ce qu'elle permet | Limites |
|---|---|---|
| Réponse d'un hook (doc) | `PermissionRequest` → allow/deny ; `PreToolUse` + `updatedInput.answers` → répondre à `AskUserQuestion` ; `Elicitation` → accept/decline | le hook doit **bloquer** jusqu'à la réponse ; non vérifié que le TUI reste vivant pendant ce temps |
| Mods (doc, 2.1.287) | plugin JS en process : `$.prompt.submit`, `tool.check`, `$.agent.list()`, `$.session.usage()` | trois semaines d'âge, le moins stable ; coupable par les réglages managed |
| Channels (doc, research preview) | le serveur MCP `scope` pousse un tour, relaie les permissions | `--dangerously-load-development-channels` + politique d'org |
| Socket de messagerie entre sessions (obs) | message d'un pair | ne peut pas approuver, tenu derrière une confirmation en mode bypass |
| Frappes dans le PTY (aujourd'hui) | tout ce que l'utilisateur peut faire | dépend du dessin du TUI |

---

## 2. Inventaire des features

Valeur : ★★★ change la façon de suivre un agent ; ★★ utile au quotidien ; ★ confort. Effort : S < 1 jour,
M quelques jours, L plus.

| Feature | Source | Stabilité | Valeur | Effort | Déjà fait ? |
|---|---|---|---|---|---|
| **Sous-agents** : liste, type, description, état, durée, tokens, résultat, transcript | hooks `SubagentStart/Stop` (`agent_type`, `agent_transcript_path`, `last_assistant_message`) + `Agent` `tool_response.agentId` + `meta.json` + `<task-notification>` (`usage`) | doc + obs | ★★★ | M | compte seulement (`ThreadActivity.agents`, tient `thread.wait`) |
| Sous-agents vivants (progression, tokens en direct) | `subagentStatusLine` | doc | ★★ | M | non |
| **Shells en arrière-plan** : commande, état, code de sortie, sortie, kill | `Bash.tool_response.backgroundTaskId` + `Stop.background_tasks[]` + `<task-notification>` + `outputFile` | doc + obs | ★★★ | M | non (le `PostToolUse` tardif est même ignoré par `isLate`) |
| **Monitors** (watchers) : commande, expiration, événements | `Monitor.tool_response.taskId` + `background_tasks[type=monitor]` + `<task-notification>` `event` | doc + obs | ★★ | S (avec les shells) | non |
| **Réveils `/loop` et crons** | `ScheduleWakeup` / `CronCreate` résultats + `Stop.session_crons[]` | doc | ★★ | S | non |
| **Permission en attente, avec son contenu** (outil, commande, fichier) | `PermissionRequest` (immédiat, contenu) ; `claude agents --json` `waitingFor` | doc | ★★★ | M | état `waiting` sans contenu, ~6 s de retard |
| **Question en attente** (`AskUserQuestion`) : question, options | `PreToolUse` | doc | ★★★ | S | question seulement (sidebar, notification, Inbox) |
| Répondre depuis Scope (permission, question) | frappes PTY ou réponse de hook | doc | ★★ | M–L | réponse libre seulement (notification, Inbox) |
| Élicitation MCP (formulaire, URL) | `Elicitation` | doc | ★ | S | état `waiting` seulement |
| **Serveurs MCP** : en attente, en échec (code), à authentifier | `deferred_tools_delta` + `~/.claude.json` | obs | ★★ | M | non |
| Outils MCP appelés | `PreToolUse.mcp_server` | doc | ★ | S | nom de l'outil dans l'activité |
| **Compactions** : quand, auto/manuel, tokens avant/après | `PreCompact` / `PostCompact` + `compact_boundary` | doc + obs | ★★ | S | non |
| % de contexte | status line `context_window` | doc | ★★★ | S | chantier UI (carte Context, `ContextWindow`) |
| **Mode de permission** (default / auto / bypass / plan / acceptEdits) | `permission_mode` sur chaque hook + `permission-mode` | doc | ★★ | S | non (seulement le nom du profil) |
| Mode plan : entrée, plan, sortie | `EnterPlanMode` / `ExitPlanMode` + `plan_mode*` | doc | ★★ | S | `ExitPlanMode` traité comme question |
| Modèle courant et effort | `SessionStart.model`, `PostModelSwitch`, status line `model` / `effort` | doc | ★★ | S | modèle choisi au lancement seulement |
| Todos / tâches de l'agent | `TaskCreate/Update` + hooks `TaskCreated/Completed` | doc | ★★ | M | chantier UI (carte Plan). **Désactivés par défaut sur les modèles récents** (2.1.233, 2.1.268) : il faut `CLAUDE_CODE_ENABLE_TODO_TOOLS=1` |
| Coût et lignes par session | status line `cost`, `cost-state` | doc + obs | ★ | S | tokens par transcript (TokenLedger) |
| Fichiers modifiés par tour | `Edit`/`Write` `tool_input.file_path`, `Bash.bashEditDiff` | doc + obs | ★★ | S | checkpoints par tour (diff de worktree) |
| **PR créées / poussées par l'agent** | `Bash.gitOperation.pr`, `pr-link`, status line `pr` | doc + obs | ★★ | S | PR de la task via `gh` toutes les quelques minutes |
| Artifacts publiés | `frame-link`, résultat de `Artifact` | obs | ★ | S | chantier UI (carte Artifacts) |
| Skills invoqués | `Skill` (`PreToolUse`), `UserPromptExpansion` | doc | ★ | S | nom dans l'activité |
| Hooks de l'utilisateur qui ont tourné / échoué | `stop_hook_summary`, `hook_*` | obs | ★ | S | non |
| Erreurs d'API, rate limit | `StopFailure.error`, `isApiErrorMessage` | doc | ★★ | S | `turn.failed` + code |
| Limites d'abonnement | status line `rate_limits` | doc | ★★★ | — | **fait** (PR 79) |
| Worktrees créés par l'agent | `EnterWorktree`, `isolation: worktree`, `worktree` de la notification | doc | ★ | S | non |
| Reprise, fork, `/clear` | `SessionStart.source`, `SessionEnd.reason` | doc | ★ | S | id de reprise |
| Titre de session | `ai-title`, `custom-title` | obs | ★ | S | non (titre de thread Scope) |
| Slash commands, output style | status line `output_style`, `<command-name>` | doc + obs | ★ | S | non |
| Messages entre sessions Claude | `SendMessage` | obs | ★ | S | Scope a son propre `thread.send` |

### Ce qui sert aux agents orchestrateurs (CLI / MCP)

- `thread wait` qui comprend les tâches de fond : il tient déjà sur les sous-agents ; les shells et les Monitors
  doivent être **rapportés**, pas attendus (un serveur de dev ou un Monitor de 30 min ferait courir chaque attente
  jusqu'à son timeout).
- `scope list threads` / `thread read` : sous-agents, tâches de fond, demande en attente avec son contenu,
  mode de permission, compactions.

---

## 3. Découpage retenu

1. **Fondation** (ce chantier) : `scope-hook` transmet ce que les features lisent (`tool_response` utiles,
   `background_tasks`, `session_crons`, `agent_type`, `permission_mode`, compactions) ; une lecture incrémentale
   du transcript, typée et tolérante (notifications dédoublonnées, `task_status`, `compact_boundary`,
   `permission-mode`, `deferred_tools_delta`, `pr-link`) ; un conteneur `ClaudeSession` par thread, hors de la
   logique de tour (`isLate` ne doit pas avaler le travail de fond).
2. **Sous-agents** : arbre sous le thread dans la sidebar, carte dans le panneau, CLI/MCP.
3. **Tâches de fond** : shells, Monitors, réveils, crons — liste, état, sortie, arrêt confirmé.
4. **Demandes en attente** : contenu de la permission et de la question dans la ligne, la notification et l'Inbox ;
   réponse depuis Scope si elle est sûre.
5. **Session** : serveurs MCP (modèle exposé à la carte Connectors du chantier UI), compactions, mode de
   permission, modèle et effort, PR détectées.

Hors de ce chantier : la carte Plan et les todos, la carte Context, Artifacts et Connectors (chantier UI) ; la
suppression des autres drivers (décision séparée).

## 4. Pour plus tard

- Mods Claude Code : la voie la plus riche pour piloter une session (prompt, permissions, liste d'agents) sans
  dépendre du dessin du terminal, quand l'API aura mûri.
- `claude agents --json` : adopté pour confirmer tout de suite une permission décrite par `PermissionRequest`
  (une exécution par permission non tranchée au bout d'une seconde). À étendre à l'élicitation (`waitingFor`
  d'un formulaire MCP), dont la notification `elicitation_dialog` attend elle aussi ~6 s.
- Répondre par un hook bloquant (`PermissionRequest` → allow/deny, `PreToolUse` + `updatedInput.answers`) : pas
  livré — il faudrait prouver que le TUI reste utilisable pendant que le hook attend. Scope répond aujourd'hui par
  les touches du terminal, après avoir vérifié la boîte à l'écran.
- Répondre depuis Scope à un plan (options variables selon les réglages : lire les libellés à l'écran) et à un
  formulaire MCP ; exposer la réponse aux agents (CLI/MCP) derrière `AutomationPolicy`.
- Notification d'une question : actions par option (catégorie dynamique) au lieu du *Reply* libre.
- `PreModelSwitch` / `PostModelSwitch` pour suivre `/model` en direct.
- Hooks `ConfigChange` / `InstructionsLoaded` : montrer quel CLAUDE.md et quels réglages un thread a chargés.
- Coût d'une reprise (`SessionStart.estimated_cache_write_usd`) avant de relancer un vieux thread.
