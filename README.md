# Claude PR Hover

A floating macOS panel that shows all your open, non-draft pull requests generated with Claude Code — so you always see what's ready for review or merge.

![Panel](docs/screenshot.png)

## What it shows

PRs are found via GitHub search: open PRs authored by you whose body contains "Generated with Claude Code" (the marker Claude Code adds to every PR it creates), sorted by most recently updated, drafts excluded. Each row shows:

- Repo and PR number, title, and last-updated time
- CI status (green check / red X / yellow pending)
- Review state (Approved / Needs review / Changes requested)
- A merge-conflict warning when the PR can't merge cleanly

Each row has four actions:

- **Remove** — hide the PR from the panel (persisted across refreshes; doesn't touch GitHub)
- **Open Folder** — open `~/GitHub/<repo>` in Finder (disabled if not cloned locally)
- **Session** — find the local Claude Code session that worked on this PR (by searching `~/.claude/projects` transcripts for the PR URL) and resume it in Terminal via `claude --resume`
- **Open PR** — open the PR in your browser (clicking the row does the same)

The list refreshes automatically every 5 minutes.

## Requirements

- macOS 13+
- [`gh` CLI](https://cli.github.com) installed and authenticated (`gh auth login`)

## Build & run

```sh
swift build -c release
.build/release/ClaudePRHover &
```

The panel hovers at the top-right of your screen (always on top, visible on all Spaces) and can be dragged anywhere. A menu-bar icon (✨) lets you show/hide the panel, refresh, or quit. There is no dock icon.

To test the data fetch without launching the GUI:

```sh
.build/debug/ClaudePRHover --dump
```

## Start at login

```sh
swift build -c release
mkdir -p ~/.local/bin && cp .build/release/ClaudePRHover ~/.local/bin/
```

Then add `~/.local/bin/ClaudePRHover` as a Login Item in System Settings → General → Login Items.

## How PRs are detected

The panel queries GitHub for open PRs you authored whose body contains "Generated with Claude Code" — the attribution footer Claude Code adds to every PR it opens. If your Claude Code setup uses a different PR footer, adjust the search query in `Sources/ClaudePRHover/GitHubClient.swift`.

## License

MIT
