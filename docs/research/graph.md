# The Graph sheet, redesigned

The sheet that lists a scope's repositories was unreadable on a real work scope of 14 repos: hashtags squeezed
into columns and cut mid-word, the stack said twice (`node` chips and `#node`), names and paths cut in the middle,
descriptions that were the README's first instruction ("1. Create a personal access token…"), rows as tall as their
tallest card, and the same four links under every card.

Mockups: `graph/png/` (built by `graph/build.py`, light and dark). Screenshots of the build: `graph/shots/` —
`before-*` is the sheet as it was, `after-*` the redesign, on @maastrich (33 repos, none linked) and on a demo scope
`acme` (14 repos, then 34 for the graph, with relations written by hand so they can be published).

## Decisions

**Cards: a uniform grid, not masonry.** Every card has the same parts at the same heights: the name (two lines at
most), `owner/repo` on its own line, two lines of description reserved even when shorter, one row of tags, *Details*
folded. Rows line up without the gaps the old grid had, the grid stays lazy, and reading and Tab order stay left to
right. Masonry fills gaps that cards of very different heights leave; those heights were the bug, and masonry would
also scatter the order across columns. Opening *Details* grows one row, which the person asked for.

**Tags: one row, merged, `+N`.** The stack and the tags become one list said once — compared without case, `#`, or
separators, with a few aliases (`node.js` = `node`, `github actions` = `github-actions`). As many chips as fit the
row, six at most, then `+N`, which opens the rest; a chip is never cut. `TagMerge` and `TagOverflow` are pure and
tested; the view only measures.

**Descriptions: the first good source.** By hand (an edited card) → GitHub (`gh repo view --json description`, kept
in the graph file; `""` means "asked, none") → the manifest's `description` (three words at least, not the name
again) → the AI analysis's purpose → the README's first prose sentence. The README reader skips headings, badges,
code, tables, lists, lines that introduce instructions ("To install dependencies:"), GitHub alerts (`> [!WARNING]`),
fully emphasized lines and generator boilerplate ("This project was created using `bun init`"). The AI purpose sits
between the manifest and the README: it was written to describe the repository and beats a README's opening, but a
GitHub or manifest description is the owner's own words.

**Facts refresh without an analysis.** Opening the sheet reads the files again and asks GitHub for the descriptions
it does not have (a few at a time, failures not cached), and writes only `<home>/graph/<scope>.json`. A graph written
by an older build therefore looks right at once instead of after the next commit in every repo.

**Groups: by domain, from the analysis or inferred.** The AI analysis now names a domain (prompt version 3);
otherwise `RepoDomain.infer` scores stack, tags, the words of the name and, weakly, of the description. Domains with
a single repo share one last group ("Front · Libs · Data") — eight groups of one card is a list with headers in it.
Groups fold, remembered per scope.

**Graph: layered, not force-directed.** The relations are dependencies, which a reader follows top to bottom.
Longest-path layers (dependents above), a repo nothing depends on moved down to just above what it uses (thirty
services on one library otherwise make a first row thirty wide), cycles broken by a depth-first walk in key order,
barycentre sweeps to undo crossings, layers wider than eight wrapped onto several rows. The same graph always gets the same drawing with no seed
to keep, and a new repo moves its own layer rather than the whole picture. Repos without a link are in a band below,
not scattered in the drawing. Hover lights a repo's links and neighbours; a click shows its card beside the drawing;
pinch, ⌘+ / ⌘− / ⌘0, scrolling and dragging zoom and move. The filter dims nodes rather than re-laying out.

**Filters: one bar for the three views.** Text over name, path, description, domain and tags; domain chips and the
most used tags (the rest under *More*). Chips of one kind widen, the two kinds narrow each other, the text narrows
both.

**Actions: on hover, focus, right-click and VoiceOver.** Editor (the checkout picker when there are sandboxes), Base,
Reveal, and a menu with Copy Path, Show in Graph and Edit Card. None destructive.

## Setup commands

Eight task setups had failed in the owner's history. Five ran `uv sync` in a repository whose `pyproject.toml` only
configures ruff: the AI analysis guessed the command, and nothing checked it. Two were `pnpm install` refusing the
Node version (`engine-strict` and a dependency's `engines`), an environment problem no scan can fix. Every failure was
buried under thirty identical "did not copy …: the sandbox has a symlink on that path" lines.

- `SetupCommandCheck` (ScopeTasks) reads a command against the folder it runs in: `uv sync` needs a `[project]`
  table, `pip install -e .` an installable project, `make X` the target X, `npm`/`pnpm` a `package.json`, `cd dir`
  the folder… It only answers for tools it knows and when the file is plainly missing.
- The quick analysis never proposes a command the check rules out; it reads `[project]` / `[tool.poetry]` instead of
  assuming any `pyproject.toml` installs, and falls back to the requirements files or the Makefile's install target.
- An AI answer the check rules out falls back to the quick analysis's command; a stored one is replaced when the
  sheet refreshes the facts (unless the card was edited by hand).
- A task's setup reports such a command instead of running it, and the copy refusals collapse to one line per reason.
