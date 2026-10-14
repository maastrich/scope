# Palette de marque Scope (source : charte "Identité visuelle — Système couleur")

Deux modes. Un mesh gradient par mode (bleu → lavande → jaune → orange, balayage horizontal).

## Midnight — Dark mode
Prioritaire sur : site web, mobile et application, réseaux sociaux, contenus vidéo, présentations en salle sombre.

| Nom | Hex |
|---|---|
| Onyx | `#101010` |
| Ink | `#141826` |
| Electric | `#0E55FB` |
| Lavender | `#DFCEFF` |
| Mist | `#D8EFF9` |
| Butter Yellow | `#FAF6B9` |
| Pumpkin Spice | `#F96B1A` |

## Daylight — Light mode
Pensé desktop. Mesh gradient légèrement différent du dark pour garantir l'accessibilité et éviter les contrastes trop agressifs.

| Nom | Hex |
|---|---|
| Ivory | `#FFFFF9` |
| Electric | `#0E55FB` |
| Periwinkle | `#9789E6` |
| Lavender | `#DFCEFF` |
| Butter Yellow | `#FAF6B9` |
| Frosted Mint | `#D6F0DC` |
| Pumpkin Spice | `#F96B1A` |

## Garde-fous
- Lavender, Mist, Butter Yellow, Frosted Mint = couleurs de **surface / fill**, jamais de texte.
- Electric `#0E55FB` sur Onyx `#101010` est limite pour du texte courant — accent / fill / stroke, pas du body.
- Le mesh gradient est un élément de marque, pas un fond d'UI dense. À doser.

## Rôles d'interface

Les rôles (fond, carte, texte, bordure, accent) et les couleurs sémantiques viennent du design system Mobsuccess : `DESIGN.md` §1.2–1.3 et `references/color-palette.md` du dépôt `mobsuccess-devops/design-system`. Leur traduction en tokens de l'app est décrite dans [`INFORMATION_ARCHITECTURE.md`](INFORMATION_ARCHITECTURE.md), « The finish pass ».
- Ink n'est **pas** un fond. Le fond sombre, c'est Onyx.
- En sombre l'accent est Periwinkle : Electric n'y fait que 3,0:1.
