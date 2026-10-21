# L'îlot sous l'encoche

Recherche courte, octobre 2026 (Scope 0.29.1, Claude Code 2.1.306, Vibe Island 1.0.53, macOS 26.5). Maquettes :
`docs/research/island/` (`python3 docs/research/island/build.py`) ; captures de l'implémentation sur une instance
jetable et un vrai thread Claude Code : `docs/research/island/shots/`.

## Verdict

Scope a déjà tout ce que Vibe Island affiche, et souvent mieux réconcilié : l'état des threads, ce que demande une
permission ou une question (#102), le plan, les limites 5 h / 7 j par le relais statusline, les sous-agents et le
travail de fond. Il lui manquait la **surface** : un endroit visible depuis n'importe quelle app, qui ne demande pas
d'ouvrir la fenêtre. L'îlot est cette surface, branchée sur l'état existant. Il n'ajoute ni hook, ni protocole.

## Ce que fait Vibe Island

Observé en lecture seule : bundle (`Info.plist`, `Localizable.strings`, ressources), réglages
(`defaults read app.vibeisland.macos`), hooks dans `~/.claude/settings.json`, site public.

- **Réception.** Quatorze hooks Claude Code appellent `~/.vibe-island/bin/vibe-island-bridge --source claude`. Le
  `PermissionRequest` a un timeout de 86 400 s : c'est le hook qui *décide* la permission quand on clique Allow dans
  l'encoche. L'usage arrive par un bloc injecté dans le script statusline de l'utilisateur, qui écrit
  `~/.vibe-island/cache/rl.json`.
- **Replié.** Une barre noire autour de l'encoche (une pastille en haut au centre sans encoche), le nombre de
  sessions, l'usage. App `LSUIElement`, fenêtre de 680 × 580 au niveau 27, qui suit l'écran du focus
  (`vibeIsland.screen.mode = focus`).
- **Ouvert** (survol 0,15 s, ou clic). Une carte par session : agent, terminal, projet, worktree, modèle, effort,
  outil en cours, sous-agents, checklist de tâches, durée.
- **États.** Processing, Thinking, Running tool, Needs approval, Waiting for answer, Waiting for input, Compacting,
  Done, Interrupted, « May need attention ».
- **Actions.** Allow Once / Always Allow / Allow All / Deny, avec un aperçu du diff ; question par option (raccourcis
  numérotés) ; plan rendu en Markdown, avec un champ de feedback et le choix du mode (auto, bypass, manuel) ; clic sur
  une session → saut vers l'onglet exact du terminal (iTerm2, Ghostty, Warp, Kitty…).
- **Alertes.** La carte s'ouvre seule pour une question ou une fin de tour (réglable), « smart suppression » quand
  l'onglet de l'agent a le focus, rappel après N minutes, « scènes calmes » : Focus, partage d'écran, écran verrouillé.
- **Sons.** Dix catégories (fin de tour, approbation, erreur, contexte presque plein, usage presque plein, reset
  d'usage…), sons 8-bit, packs importables, heures calmes, volume.
- **Réglages.** Écran (principal, focus, spécifique), dimensions de l'encoche, masquer en plein écran, ce que montre
  une carte, raccourcis clavier, rappels, notifications iPhone (Bark), SSH distant. Une trentaine d'agents.

## Ce qu'on reprend

| Vibe Island | Scope |
|---|---|
| Barre autour de l'encoche, pastille centrée sans encoche | Pareil (`Island.band`), sur l'écran principal, celui du pointeur ou un écran nommé |
| Ouverture au survol (0,15 s) ou au clic | Pareil, réglable ; un clic ailleurs referme |
| Allow / Deny, options d'une question, aperçu du plan | Pareil, par `answerPendingRequest` (#102) |
| Ouverture auto pour une fin de tour ou une demande | Une **révélation** de 5 s, par type d'événement |
| Silence pendant un Focus ou écran verrouillé | Pareil (`IslandQuiet`) |
| Pas de révélation pour la session au premier plan | Pareil : le thread affiché dans Scope, app active |
| Usage en tête | Anneau 5 h replié, barre ouverte, mêmes données que le compteur de la sidebar |
| Sons | Trois sons système (fin, échec, demande), off par défaut |

## Ce qu'on fait mieux

- **Une seule source d'état.** L'îlot lit `displayState` et `pendingRequest(of:)`, déjà réconciliés : une permission
  décidée ailleurs disparaît (`decidedElsewhere`, `claude agents --json`), un tour dont le hook de fin s'est perdu
  mais que la dernière réponse a clos est soldé (`settleOutlivedTurn`, appelé à chaque lecture de l'îlot). Vibe
  Island n'a que ses hooks.
- **Un thread silencieux le dit.** Un thread « running » sans aucun événement depuis 10 min, sans sous-agent ni
  travail de fond, affiche « No news for 14 min » au lieu de prétendre travailler.
- **Allow n'est proposé que pour ce qui est lu en entier.** Une commande de plus d'une ligne ou de 120 caractères
  n'a que Deny et Open : on n'approuve pas ce qu'on n'a pas vu. Aucun « Always Allow », aucun Stop, Close ou Archive.
  La touche n'est tapée que si le terminal montre ce dialogue précis (`ClaudeDialogAnswer.check`).
- **Groupé par task**, demandes en tête, et un clic ouvre Scope sur le bon thread, terminal au clavier : pas de
  dépendance aux terminaux tiers ni à l'Automation.
- **Dédupliqué.** Une révélation par demande (clé = id de la requête) ou par tour (`turnRevision`) ; une révélation
  sautée (premier plan, Focus, réglage) est mémorisée et ne ressort pas plus tard.

## Ce qu'on laisse

- Le **diff** d'une édition dans l'îlot (il est dans l'inspecteur), le **feedback** et le choix de mode d'un plan
  (les options du dialogue changent avec les réglages : on ouvre le thread).
- Les **packs de sons**, le volume, les heures calmes, les rappels après N minutes, Bark, SSH, les autres agents :
  Scope se concentre sur Claude Code.
- La détection du **partage d'écran** : pas d'API publique fiable.
- Les **dimensions d'encoche** réglables : `safeAreaInsets` et `auxiliaryTop*Area` suffisent.

## Décisions

- **Activé par défaut** dans l'app installée, **désactivé dans un build Debug** (`IslandSettings.enabled = nil`,
  « automatique ») : l'îlot ne paraît que s'il y a un thread qui travaille, attend ou a fini sans être lu, et occupe
  l'espace mort de l'encoche ; sans lui la fonction ne se découvre pas. Les builds Debug de plusieurs worktrees
  empileraient leurs îlots au même endroit.
- **Noir autour de l'encoche, design system en dessous.** La bande doit se fondre dans l'encoche matérielle ; la
  liste, les cartes et la pastille sans encoche suivent `Surface` / `Ink`, clair ou sombre.
- **Focus.** `INFocusStatusCenter` (autorisation demandée au premier lancement de l'îlot). Sans autorisation, Scope
  considère qu'il n'y a pas de Focus ; Réglages ▸ Island le dit.

## Coexistence avec Vibe Island

Testé sur deux écrans LG sans encoche, Vibe Island lancée : sur le **même écran**, sa fenêtre (niveau 27) couvre
la bande de l'îlot (niveau 25) ; la liste ouverte reste visible dessous. Sur des **écrans différents**, aucun
conflit. Les deux reçoivent la même permission : Vibe Island par son hook `PermissionRequest`, Scope par l'état de
la session. Une réponse donnée dans l'îlot de Scope a bien été tapée et exécutée ; ce que fait ensuite le hook en
attente de Vibe Island n'a pas été observé. Tant que les deux tournent, mettre l'îlot de Scope sur un autre écran.

## Limites connues

- Aucun écran à encoche sur la machine de test : le placement autour de l'encoche n'est couvert que par les tests
  (`IslandPlacementTests`).
- Survol et clic non pilotés (pas d'Accessibility) : les états ont été forcés par `$SCOPE_HOME/island-command`
  (Debug), qui appelle le même chemin que les boutons.
- Hooks perdus : #101 a corrigé la perte au niveau de la socket, pas la réconciliation d'état. Un `Stop` perdu sans
  réponse dans le transcript laisse un thread « running » ; l'îlot l'affiche « No news », sans le solder.
