# Claude Code Desktop : ce qu'on reprend pour Scope

*Recherche UI, 2026-10-20. Pas de code de production : des sources, une analyse, des maquettes HTML/PNG et un
plan par étapes.*

## En deux mots

Claude Code Desktop (v2.42304, octobre 2026) a remplacé ses onglets et ses barres au-dessus du prompt par un
**rail de cartes** à droite de la conversation : Environment, Context, Connectors, Changes, Outputs, Servers,
Background tasks. Chaque carte est repliable, dit **une chose par ligne** (une icône, un nom, une valeur à
droite), et son en-tête fermé résume. Les vues lourdes (diff, terminal, fichiers, navigateur) ne sont pas dans le
rail : ce sont des **panes** à part, ouverts depuis une barre d'icônes, redimensionnables, détachables. La sidebar
groupe les sessions par **état** (*Needs input / Working / Completed*), imbrique les sessions filles sous leur
parent, et remplace le point d'état par un glyphe de PR quand la session en a une.

Scope a déjà la moitié de tout ça, souvent avec plus de profondeur (frise, checkpoints, Inbox, PR multiples,
Base). Ce qui lui manque est surtout **la forme** : des cartes plutôt que des sections plates, un en-tête qui
porte le résumé *et* un accès direct aux panes, et trois cartes qui n'existent pas encore : **Environment**
(setup, ports, process), **Artifacts** (REPORT.md, fichiers produits, pages publiées) et **Connecteurs**. Les
maquettes dans [`mockups/`](mockups/) montrent le résultat aux couleurs de Scope, en clair et en sombre.

## Sources

Tout est dans [`sources/INDEX.md`](sources/INDEX.md) : 17 images (blog et docs Anthropic, pièces jointes
d'issues GitHub, images extraites des vidéos de démo publiées sur X) avec URL et date, plus les pages lues. Deux
captures sont les nôtres (`own-*`) : l'app installée sur la machine, ouverte sur l'onglet Code, état déconnecté ;
titres de sessions et chemins masqués, l'app a été fermée ensuite. Sans permission d'accessibilité, impossible de
cliquer dans l'app : on n'a donc pas de capture des cartes Context, Connectors, Outputs ou Servers ouvertes, ni
du pane diff dans la version actuelle. Ce qui suit distingue ce qui est **vu** (capture), **décrit** (docs ou
changelog) et **déduit**.

Attention à la coexistence de deux layouts dans les sources : l'ancien (PR et branche dans une barre au-dessus du
prompt, jusqu'en septembre) et l'actuel (rail de cartes, depuis v2.37337). Les docs officielles distinguent les
deux ; plusieurs blogs mélangent.

## Ce qu'on voit dans Claude Code Desktop

### Le rail de session (droite)

| Élément | Ce qu'il montre | Statut |
|---|---|---|
| **Barre d'icônes** en haut à droite du titre de session | rail on/off, Terminal, Changes (diff), Browser, Files, `⋮` (autres panes : Background tasks…) | vu (`own-01`) |
| **Environment** | `This computer` + lien *Save* (environnement réutilisable), dossier, branche, interrupteur *Remote Control* | vu (`own-01`) |
| **Context** | taux d'usage du contexte (`Context 78 %`), modèle | décrit (changelog, issue #102219) |
| **Connectors** | serveurs MCP de la session, état connecté / à ré-authentifier | décrit ; carte vue fermée |
| **Changes** | une ligne par PR : icône d'état (check vert, glyphe merge violet), titre tronqué, `repo #n`, `+61 −23`, `• 13/14` checks, menu `⋮` (Auto-fix, Merge when ready, auto-archive) | vu (`04`) |
| **Outputs / Servers / Background tasks** | fichiers produits, serveurs de preview (`.claude/launch.json`), sous-agents et commandes de fond (`Running · 9m 12s`, chip `Agent ›` / `Bash ›`) | décrit ; tasks vues dans l'ancien layout (`12b`) |
| Choix des cartes | clic droit sur un en-tête → cocher les cartes visibles | décrit (changelog) |
| Largeur | fixe, non redimensionnable ; se masque | décrit (issue #102104) |

Densité : cartes blanches à bord 1 px et rayon ~10 px sur fond crème, titre ~14 px semi-gras avec chevron,
lignes de ~36 px avec glyphe monochrome 16 px à gauche et contrôle aligné à droite. Pas d'actions au survol dans
les cartes ; tout passe par le `⋮` ou le lien de la ligne.

### Les panes

Diff : sections par fichier (dossier atténué, nom en gras), `+N −N` par fichier, gouttière ancienne/nouvelle,
hunks non modifiés repliés (`38 unmodified lines`), case à cocher par fichier, bouton *Review code* ; un clic sur
une ligne ouvre un commentaire, `⌘↩` envoie tous les commentaires (vu `01`, `12a`). Terminal : onglets, `+`,
pop-out, s'ouvre dans le cwd de la session (vu `12b`). Les panes s'empilent, se redimensionnent, se détachent
dans leur fenêtre et se redockent (vu `11b`).

### La sidebar

| Élément | Statut |
|---|---|
| Entrées fixes : *Search*, *+ New*, *Artifacts*, *Customize*, *More* | vu |
| Groupement par **état** : *Needs input* (triangle ⚠ sur chaque ligne), *Working*, *Completed* ; options None / Status / Date / Environment ; sections personnalisées | vu (`10`, `08a`) |
| **Sessions imbriquées** sous leur parent, avec un filet vertical à gauche | vu (`10`) |
| Point d'état devant le titre : plein orange = travaille, creux gris = inactif ; **remplacé par un glyphe de PR** (avec compteur si plusieurs) quand la session a une PR ; glyphe d'environnement (laptop, nuage) en fin de ligne des sessions terminées | vu (`07`, `08a`, `10`) |
| Nom du projet en petit sous le titre quand on ne groupe pas par projet | vu (`08a`) |
| *Group and sort* au survol d'un en-tête de groupe ; menu par ligne (Archive, Rename, Delete, Open in) ; `⌘`-clic = split view | décrit |
| Pas de branche dans la ligne ; pas de multi-sélection | déduit / issue #85704 |

Rangées ~36 px, titres en sentence case, en-têtes de groupe en gris sans capitales. Une seule couleur d'accent
(orange) pour l'état « travaille » et le bouton d'envoi.

## Ce qui plaît, et pourquoi

1. **Une carte = une question.** « Où ça tourne ? » (Environment), « Qu'est-ce qui a changé ? » (Changes),
   « Avec quoi l'agent parle ? » (Connectors). Le découpage suit les questions de l'utilisateur, pas les objets
   techniques. Dans Scope, *Task* mélange brief, branche, repos, ports, frise et checkpoints : c'est la section
   qui répond à cinq questions à la fois.
2. **L'en-tête fermé est déjà une réponse.** `Changes ˅` ouvert ou `Context 78 %` fermé : on survole sans
   ouvrir. Scope fait pareil (c'est même une règle du SPEC), mais ses en-têtes sont des bandes uppercase 10,5 pt
   collées : on lit une table des matières, pas des cartes.
3. **Une ligne par PR, avec tout dessus.** État, titre, repo, numéro, stats, checks : la carte Changes résume ce
   que Scope étale entre la liste des PR, le détail et le panneau des checks. Le compteur `13/14` dit plus que
   « checks pending ».
4. **Les panes hors du rail.** Le diff et le terminal ont la hauteur qu'il leur faut, le rail reste une liste de
   faits. Scope a la colonne de lecture pour ça, mais on y entre par un geste (clic sur un fichier, `⌘⇧R`), pas
   par un bouton visible. La barre d'icônes rend les panes **découvrables**.
5. **La sidebar met en premier ce qui attend.** *Needs input* en tête, avec un triangle qui ne ressemble à rien
   d'autre. Scope a le mode « par état » (*needs you / working / finished / quiet / dormant*), plus fin ; mais
   il est derrière `⌃⌘G` et l'arbre reste le défaut.
6. **Les sessions imbriquées.** Le filet vertical montre d'un coup d'œil qu'un agent en a lancé un autre. Scope
   montre les threads d'une task sous elle, mais une task lancée depuis une autre n'est pas imbriquée (choix
   assumé du SPEC : le topic les regroupe). Le filet reste une bonne idée pour les threads d'une task.
7. **Le glyphe de PR à la place du point.** Quand la session est « devenue » une PR, c'est l'état qui compte.
   Scope a le glyphe de task (`arrow.triangle.pull`, `merge`) à gauche *et* le point de thread à droite ;
   l'information y est, deux fois.

Ce qui plaît moins : la largeur fixe du rail (issue #102104), le point d'état qui ne distingue que occupé /
inactif (issue #89531, Scope fait mieux avec quatre formes et des couleurs 3:1), l'absence d'actions au survol
(tout est à deux clics), et une typographie confortable qui coûte cher en hauteur sur un écran de portable.

## Scope aujourd'hui, face à face

| Besoin | Claude Code Desktop | Scope (v0.27) | Verdict |
|---|---|---|---|
| Où tourne la task | carte Environment : machine, dossier, branche, Remote Control | bande de 30 pt + *TaskVersionStrip* (branche, base, SHA, ↑N) + lignes de repos + chips de ports, tout dans *Task* | **adapter** : sortir dans une carte Environment avec setup, ports, process |
| État du setup | pas montré dans le rail | `TaskSetupRecord` (état, log) existe, affiché seulement dans la carte de survol | **manque** dans l'inspecteur |
| Ports / serveurs | carte Servers (launch.json), Background tasks | chips `localhost:PORT ↗` depuis `listeningPorts` ; pas de liste de process | **adapter** : ports + process qui écoutent (`ProcessSweep` sait déjà les lister) |
| Changements | carte Changes = PR ; pane Diff pour le diff | section Delta (liste), colonne de lecture (diff), modes Task / Uncommitted / Base vs origin, vu / changé depuis, commentaires + *Send review* | **Scope est devant** ; ajouter le mode « depuis le dernier tour » (déjà recommandé dans `diff-review.md`) et les comptes dans l'en-tête |
| Pull requests | une ligne par PR, checks `13/14`, menu Auto-fix / Merge when ready | plusieurs PR par task (#78), checks détaillés, *Send the failure to the thread*, review decision, retard sur main, conflits | **reprendre la forme** (ligne compacte), garder le fond |
| Terminal secondaire | pane Terminal à onglets | thread « shell » = une ligne de plus dans la sidebar, un terminal entier | **manque** : un pane Shell léger de la task |
| Artifacts / rapports | sidebar *Artifacts*, carte Outputs | `deliverable`, REPORT.md lu dans la colonne de lecture, checkpoints ; pas de liste des fichiers produits hors diff, pas de pages publiées | **manque** : carte Artifacts |
| Contexte | carte Context : % du contexte | brief replié + *Read in full*, fichier de contexte écrit par Scope, `TokenMeter` 5 h ; modèle sur le `ThreadRecord` ; skills copiés mais non listés | **adapter** : réunir brief, fichier, modèle, % contexte, skills |
| Connecteurs / MCP | carte Connectors | rien : Scope installe son propre serveur MCP, n'observe pas ceux du thread | **manque** ; dépend des hooks (`mcp` events de Claude Code) |
| Choisir les cartes | clic droit sur un en-tête | sections mémorisées par scope ; `InspectorSection.allCases` fixe | **reprendre** : menu « Cards » dans `⋮` |
| Sidebar par état | défaut ; sections custom | mode `⌃⌘G`, cinq états | **promouvoir** le mode par état |
| Imbrication | sessions filles sous le parent | threads sous la task (sans filet) ; *from <parent>* en texte | **reprendre** le filet pour les threads |
| État dans la ligne | point plein/creux, glyphe PR, ⚠ | glyphe d'état 16 cas + point de thread 4 formes + légende en mots + `+N −M` | **garder** Scope ; **retirer les compteurs**, qui tronquent le nom |
| Actions au survol | aucune (menu `⋮`) | éditeur, archiver, `⋮`, fermer, répondre `⌥↩` | **garder** Scope |

## Ce qu'on reprend, adapte, laisse

**On reprend**

- Le rail **en cartes** : bord 1 px, rayon 8, fond `Surface.panel`, 8 pt entre cartes, titre en sentence case
  12,5 semi-gras, résumé à droite quand c'est fermé. Les sections existantes deviennent des cartes sans changer
  leur contenu.
- La **barre d'icônes** dans la bande de 30 pt : Overview, Changes (badge = fichiers), Shell, Pull requests
  (badge = checks rouges), Files, `⋮`. Un clic ouvre la carte *et* son pane quand il y en a un ; `⌘D`, `⌘⇧B`
  et `⌘⇧R` restent.
- La **ligne de PR** compacte : état · titre · `repo #n` · `+a −d` · `✗ 1 / 4` · review.
- Le **menu des cartes** (quelles cartes, reset) dans `⋮`, mémorisé par scope comme aujourd'hui.
- Le **filet vertical** sous une task pour ses threads.

**On adapte**

- **Environment** reprend ce que *Task* porte déjà (version strip, repos, ports) et ajoute le setup (état,
  durée, log au clic), les process qui écoutent sur les ports de la task, disque et temps d'agent en pied de carte.
- **Context** réunit le brief (4 lignes + *Read in full*), le fichier de contexte écrit par Scope et celui du
  repo, le modèle et l'effort, le pourcentage de contexte (déjà dans `tokens.json`), les skills chargés, la
  frise. La frise sort de *Task* et vit ici, avec ses trois nombres.
- **Artifacts** : le `deliverable` et REPORT.md en tête avec un aperçu de quelques lignes ; les fichiers écrits
  hors du diff git (binaires, dossiers ignorés, `/tmp` de la task) ; les URL que l'agent a publiées (artifact,
  PR, page) ; les checkpoints en bas. Tout vient de ce que les hooks rapportent déjà (`PostToolUse` Write / Bash)
  plus un filtre sur les URL dans les réponses.
- **Sidebar** : le mode par état devient le défaut proposé à l'installation, avec *Needs you* en tête et le
  compte par groupe ; l'arbre par topic reste un réglage. En ligne compacte, une task mergée montre un chip
  `merged` plutôt qu'un point ; un seul indicateur de droite par ligne. Les compteurs `+N −M` **quittent la
  ligne** : à 264 pt ils tronquent le nom de la task (*Plusieurs b…*, *Recherche UI : s…*), et Claude Code
  Desktop n'en met aucun dans sa sidebar. Ils restent dans la carte de survol, l'en-tête de Changes et la bande.
- **Shell** : un pane de la colonne de lecture, pas un thread. Un `zsh` dans la sandbox avec `SCOPE_*` injectés,
  onglets pour les commandes longues, pop-out plus tard. Il ne crée pas de record de thread.

**On laisse**

- La largeur fixe : l'inspecteur reste tirable (320–520 pt).
- L'absence d'actions au survol : les actions du `CollapsibleSection` restent, elles passent dans l'en-tête de
  carte.
- La typographie à 14 px et les rangées de 36 px : on garde l'échelle de `Theme.swift` (13 / 11,5 / 11 / 9,5),
  les rangées de 22 à 28 pt.
- La marque : pas d'orange d'accent, pas de police géométrique, pas de pilule de saisie. Les couleurs sont
  celles de `Assets.xcassets` (Ivory / Onyx, Electric / Periwinkle, états teal / ambre / bleu).
- *Auto-fix* et *Merge when ready* en boutons : ce sont des demandes à l'agent, elles restent des phrases
  envoyées au thread (*Ask the agent*), conformément à la décision « l'agent fait le git ».
- Grouper par environnement : Scope n'a qu'une machine.

## Maquettes

HTML statique dans [`mockups/src/`](mockups/src/) (fragments), assemblées par `mockups/build.py` avec les
tokens de [`mockups/tokens.css`](mockups/tokens.css) (copie des valeurs du catalogue d'assets) et rendues en PNG
2× par Chrome headless dans [`mockups/png/`](mockups/png/). Chaque page existe en clair et en sombre.

| Page | Ce qu'elle montre | PNG |
|---|---|---|
| `inspector-overview` | le rail d'une task en cours : Environment ouvert (branche, repo, setup ✓, ports, process), Changes fermé avec résumé, Pull requests (2 PR, checks, retard), Artifacts, Context, Connectors, Repository | [clair](mockups/png/inspector-overview-light.png) · [sombre](mockups/png/inspector-overview-dark.png) |
| `inspector-delta` | la carte Changes dépliée en liste : filtre A/M/D, groupe par repo, tour d'origine par fichier, cases *vu*, groupe *Generated* replié, barre de review | [clair](mockups/png/inspector-delta-light.png) · [sombre](mockups/png/inspector-delta-dark.png) |
| `inspector-pullrequests` | trois PR dont une mergée et un draft sur un autre repo, détail de la sélection (branche, auteur, retard, reviewers, checks), pied *Ready to merge* | [clair](mockups/png/inspector-pullrequests-light.png) · [sombre](mockups/png/inspector-pullrequests-dark.png) |
| `inspector-artifacts` | REPORT.md avec aperçu, fichiers produits hors diff avec vignette, pages publiées, checkpoints | [clair](mockups/png/inspector-artifacts-light.png) · [sombre](mockups/png/inspector-artifacts-dark.png) |
| `inspector-context` | Context (brief, fichiers de contexte, skills, modèle et jauge, frise) et Connectors ouverts, menu *Cards* du `⋮` | [clair](mockups/png/inspector-context-light.png) · [sombre](mockups/png/inspector-context-dark.png) |
| `inspector-empty` | sans task (carte Repository, cartes de task grisées) et task fraîche (setup en cours, états vides de Changes, PR, Artifacts) | [clair](mockups/png/inspector-empty-light.png) · [sombre](mockups/png/inspector-empty-dark.png) |
| `pane-shell` | le pane Shell (onglets, commande longue) et le pane Changes avec un commentaire de ligne, côte à côte | [clair](mockups/png/pane-shell-light.png) · [sombre](mockups/png/pane-shell-dark.png) |
| `sidebar` | à gauche par état en lignes détaillées (digest, groupes, filet des threads, actions au survol) ; à droite l'arbre par topic en lignes compactes | [clair](mockups/png/sidebar-light.png) · [sombre](mockups/png/sidebar-dark.png) |
| `window` | la fenêtre entière : sidebar, terminal du thread, pane Changes, rail | [clair](mockups/png/window-light.png) · [sombre](mockups/png/window-dark.png) |

Régénérer : `python3 docs/research/claude-desktop-ui/mockups/build.py` (Chrome dans `/Applications`).

## Plan d'implémentation

Tailles : **S** une demi-journée, **M** un à deux jours, **L** plus.

### Étape 1 · la forme (S + S + M)

1. **S · Cartes.** `CollapsibleSection` prend un style `card` : fond `Surface.panel`, bord `Surface.stroke`,
   rayon 8, 8 pt d'écart dans la colonne, titre `.scopeBody` semi-gras en sentence case, résumé en
   `.scopeCaption` à droite. Les sections ouvertes partagent la hauteur comme avant (les sashes restent).
2. **S · Renommages.** *Delta* → *Changes*, *Pull Request* → *Pull requests*, *Base* → *Repository*. La bande
   de 30 pt garde le sujet.
3. **M · Barre d'icônes.** Dans la bande : un `pane-strip` (segmented sans bordure, `Fill.quiet`) avec Overview,
   Changes, Shell, Pull requests, Files, `⋮`. Badges : fichiers changés, checks rouges. Le `⋮` ouvre le menu
   *Cards*. `InspectorLayout` ajoute `visibleSections` par scope.

### Étape 2 · les cartes manquantes (M + M + L)

4. **M · Environment.** Déplace version strip, repos et ports hors de *Task* ; ajoute la ligne Setup depuis
   `TaskSetupRecord` (état, durée, log dans la colonne de lecture) et les process qui écoutent sur les ports
   de la task (`ProcessSweep` + `lsof -i :PORT` à la demande). Pied : disque, temps d'agent.
5. **M · Context.** Brief, fichiers de contexte (`contextFileURL` + ceux du repo que le profil du driver
   déclare), modèle et effort (`ThreadRecord.model`), jauge de contexte (`TokenLedgerStore`), frise. Les skills
   demandent un événement de hook de plus (`SkillLoaded` n'existe pas ; en attendant, lister ce que
   `SandboxFileCopy` a copié).
6. **L · Artifacts.** Nouveau type pur dans ScopeKit : `TaskArtifacts` agrège le `deliverable`, les `Write`
   hors des worktrees (depuis `turnCalls`), les URL `https://` des réponses (`ThreadActivity.turns.said`) et
   les checkpoints. Testé. La carte les montre en quatre groupes ; l'aperçu du rapport réutilise
   `MarkdownReader`.

### Étape 3 · panes et sidebar (M + S + M)

7. **M · Pane Shell.** Un `ThreadPane` sans record : PTY `zsh` dans `threadCwd`, env `SCOPE_*`, onglets
   (`TabStrip`), fermé avec la task. `⌃\`` ouvre / ferme.
8. **S · Sidebar.** Retirer `DeltaCounts` des lignes de task et de thread (le nom reprend la largeur), filet
   vertical sous les tasks, chip `merged` en ligne compacte à la place du point, mode par état proposé par
   défaut (réglage existant).
9. **M · Pull requests.** Ligne compacte par PR (état · titre · repo #n · stats · `✗ 1 / 4` · review) ;
   compte `n / total` depuis `checkRuns` ; pied *Ready to merge* / *Checks failing* avec *Ask the agent*.

### Plus tard

- Pop-out d'un pane dans sa fenêtre (`NSWindow` hébergeant la colonne de lecture).
- Connecteurs : lire les événements `mcp` des hooks Claude Code quand ils existent ; sinon lire
  `.mcp.json` et `~/.claude.json` du thread, en lecture seule.
- Mode « depuis le dernier tour » du Delta et attribution par tour (déjà dans `diff-review.md`).

## Risques

- **Contredire l'architecture d'information.** `INFORMATION_ARCHITECTURE.md` a tranché « sections, pas
  d'onglets ». La barre d'icônes n'est pas un jeu d'onglets : toutes les cartes restent dans la colonne, un
  clic ouvre la carte et son pane. Si un test montre que les gens croient à des onglets exclusifs, retirer la
  barre et garder les badges dans les en-têtes.
- **Hauteur.** Six cartes avec 8 pt d'écart et des titres de 30 pt coûtent ~60 pt de plus que les sections
  plates. Sur un 13" la carte ouverte doit rester la seule à prendre la hauteur ; `InspectorLayout` le garantit
  déjà (listes vs blocs). Vérifier sur 800 pt de haut.
- **Process et ports.** Lister les process d'une task est fragile (`KERN_PROCARGS2` cache l'env des binaires
  de plateforme, voir la mémoire du projet). Se limiter aux ports du bloc de la task et à `lsof` à la demande.
- **Artifacts hors diff.** Un `Write` dans `/tmp` ou dans un dossier ignoré n'est pas versionné : la carte doit
  dire que le fichier peut avoir disparu et ne jamais le recopier.
- **Connecteurs.** Aucun hook ne rapporte aujourd'hui les serveurs MCP d'un thread. La carte peut être vide
  longtemps ; la masquer par défaut tant qu'il n'y a rien à montrer.
- **Marque.** La tentation de copier la pilule de prompt, l'orange et la police : hors sujet, le terminal est
  l'entrée de l'agent et le reste.

## Ne pas faire

- Un chat UI ou une barre de prompt dans Scope (décision `custom-ui.md`).
- Des boutons *Auto-fix* / *Auto-merge* : une phrase à l'agent suffit (`scope-owner-git-workflow`).
- Un rail à largeur fixe.
- Grouper par environnement.
