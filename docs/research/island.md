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
- **Toujours noir** (refonte d'octobre 2026, remplace « noir autour de l'encoche, design system en dessous »). La
  pastille blanche posée sur une barre des menus colorée se lisait comme un bouton égaré, plus haute qu'elle-même
  semblait devoir l'être, avec un « 1 » (les threads actifs) à côté de quatre points (tous les threads montrés) et
  un anneau gris sur gris. Maintenant : une capsule noire qui pend du bord haut, 6 pt plus courte que la barre ; le
  compteur compte exactement les points ; l'anneau a une piste #3A3A3C et un arc clair, orange dès 80 %. Autour d'une
  encoche, deux ailes symétriques, rien sous l'encoche. Une demande élargit l'îlot jusqu'à la réponse (le
  comportement de la maquette B) ; ouvert, une carte noire liste les demandes puis les threads par task, la todo list
  du thread survolé et les limites 5 h / 7 j (la maquette A). Couleurs d'état sur noir : #FF9F0A, #0A84FF, #FF453A
  et un vert #208F3E plutôt que #30D158, qui a la luminance de l'orange (0,47 contre 0,46) ; testé dans
  `IslandLookTests`. Avec Allow à l'écran, la commande passe à la ligne au lieu d'être tronquée.
- **Focus.** `INFocusStatusCenter`, autorisation demandée la première fois que l'îlot s'affiche. Sans autorisation,
  Scope considère qu'il n'y a pas de Focus, et Réglages ▸ Island le dit. **Non vérifié** : aucune demande n'apparaît
  dans le journal TCC pour le build Debug signé ad hoc. L'API demande peut-être un droit qu'un tel build n'a pas.

## Les autres apps d'encoche (octobre 2026)

Les onze apps de [la liste de Vibe Island](https://vibeisland.app/best-ai-agent-notch-apps/), lues dans leur code
quand il est ouvert (Open Island, Ping Island, CodeIsland, Notchi, Claude Island/Vibe Notch, ClaudeNotch, Buddi),
sinon sur leur site (Claude Pulse, Notchcode, NotchClaude), plus boring.notch et NotchNook pour la discrétion.

| Ce qui les garde hors du chemin | Qui |
|---|---|
| Pas d'ouverture auto si l'utilisateur a touché clavier/souris dans les 30 s (indice et son quand même) | Ping Island |
| Signal discret au lieu d'une carte : point, rebond, lueur ; ou jamais d'ouverture auto | CodeIsland (« glance dot »), Claude Pulse, Notchcode, Notchi |
| Rien quand la session est déjà au premier plan | CodeIsland, Open Island, Claude Island, Buddi, Claude Pulse, Ping Island |
| Masqué en plein écran, une zone de survol garde l'accès | CodeIsland, Ping Island, boring.notch |
| Réglage par événement, un seul son pour une rafale d'approbations | CodeIsland |
| Rappels pour une demande qui attend, désactivés par défaut | CodeIsland |
| Raccourci global sans Accessibility (`RegisterEventHotKey`) ; Entrée/Échap globaux exigent Accessibility | Notchi, CodeIsland, Ping Island / ClaudeNotch, Claude Pulse |

Aucune ne lit le Focus de macOS ni ne détecte le partage d'écran (code cherché). CodeIsland a ralenti son sondage de
`CGWindowListCopyWindowInfo` à 5 s pour son impact énergie. Le multi-écran va de « l'écran principal » à « suit la
fenêtre active » (CodeIsland) ou « tous les écrans à la fois » (ClaudeNotch).

**Retenu dans Scope** :
- **Au travail, seules les demandes interrompent.** Une entrée HID depuis moins de 30 s
  (`CGEventSource.secondsSinceLastEventType`, aucune permission) retient la révélation d'un tour fini ou échoué ; une
  question, une permission ou un plan révèlent toujours, puisqu'un agent est bloqué. Réglage *Interrupt while I work* :
  *Never*, *Only when an agent is waiting* (défaut), *Always*. Retenue, pas différée : le point du thread sur l'îlot
  replié a déjà changé, c'est le « glance dot » sans rien ajouter.
- **Masqué au-dessus d'une app en plein écran** sur son écran (une fenêtre de layer 0 qui couvre tout l'écran, lue dans
  la même liste que le placement) ; une demande en attente ou l'îlot ouvert passent quand même. Pas de zone de survol :
  sortir du plein écran ou changer d'app le ramène. Réglage, activé par défaut.
- **Sondage à 2 s** au lieu d'1 s ; l'activation d'une app reste immédiate.

**Laissé pour plus tard** : rafales regroupées, rappels, raccourci global, sourdine par scope ou task.

## Coexistence avec Vibe Island

Testé sur deux écrans LG sans encoche, Vibe Island lancée : sur le **même écran**, sa fenêtre (niveau 27) couvre
la bande de l'îlot (niveau 25) ; la liste ouverte reste visible dessous. Sur des **écrans différents**, aucun
conflit. Les deux reçoivent la même permission : Vibe Island par son hook `PermissionRequest`, Scope par l'état de
la session. Une réponse donnée dans l'îlot de Scope a bien été tapée et exécutée ; ce que fait ensuite le hook en
attente de Vibe Island n'a pas été observé. Tant que les deux tournent, mettre l'îlot de Scope sur un autre écran.

## Limites connues

- Aucun écran à encoche sur la machine de test : le placement autour de l'encoche n'est couvert que par les tests
  (`IslandPlacementTests`).
- Les captures (`shots/`) sont prises de l'intérieur de l'app (`CGWindowListCreateImage` sur sa propre fenêtre et la
  bande d'écran autour, sans Enregistrement d'écran), sur un écran LG sans encoche, avec de vrais threads Claude Code
  d'une instance jetable. Le rendu autour d'une encoche n'est vérifié que par la géométrie (`IslandPlacementTests`).
- Survol et clic non pilotés (pas d'Accessibility) : les états ont été forcés par `$SCOPE_HOME/island-command`
  (Debug), qui appelle le même chemin que les boutons.
- Hooks perdus : #101 a corrigé la perte au niveau de la socket, pas la réconciliation d'état. Un `Stop` perdu sans
  réponse dans le transcript laisse un thread « running » ; l'îlot l'affiche « No news », sans le solder.
