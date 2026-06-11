# Helipad

A floating macOS panel that shows all your open, non-draft pull requests generated with Claude Code — so you always see what's ready for review or merge.

![Panel](docs/screenshot.png)

## What it shows

PRs are found via GitHub search: open PRs authored by you whose body contains "Generated with Claude Code" (the marker Claude Code adds to every PR it creates), sorted by most recently updated, drafts excluded. Each row shows:

- Repo and PR number, title, and last-updated time
- CI status (green check / red X / yellow pending)
- Review state (Approved / Needs review / Changes requested)
- A merge-conflict warning when the PR can't merge cleanly

Each row has four actions:

- **Archive** — move the PR to the Archived tab (persisted across refreshes; doesn't touch GitHub)
- **Open Folder** — open `~/GitHub/<repo>` in Finder (disabled if not cloned locally)
- **Session** — open the Claude Code session behind this PR in Terminal. Resolution order: the background-job registry (`~/.claude/jobs/*/state.json` links jobs to the PRs they created) — attaching live with `claude attach` if the agent is still running, or `claude --resume` if finished; then running agents whose transcript mentions the PR; then Claude Code's own `claude --from-pr` tracking
- **Open PR** — open the PR in your browser (clicking the row does the same)

A filter menu (funnel icon) controls which statuses are shown; by default only PRs needing your attention appear (approved, changes requested, CI failed, conflicts). The first page loads immediately and more PRs load as you scroll. The list refreshes automatically every 5 minutes.

## Requirements

- macOS 13+
- [`gh` CLI](https://cli.github.com) installed and authenticated (`gh auth login`)

## Install

Download the DMG from the [latest release](https://github.com/ronreiter/helipad/releases/latest), open it, and drag Helipad into Applications (signed and notarized). Every push to `main` publishes a new release automatically.

## Build & run from source

```sh
swift build -c release
.build/release/Helipad &
```

The panel hovers at the top-right of your screen (always on top, visible on all Spaces) and can be dragged anywhere. A menu-bar icon lets you show/hide the panel, refresh, or quit. There is no dock icon.

To test the data fetch without launching the GUI:

```sh
.build/debug/Helipad --dump
```

## Start at login

```sh
swift build -c release
mkdir -p ~/.local/bin && cp .build/release/Helipad ~/.local/bin/
```

Then add `~/.local/bin/Helipad` as a Login Item in System Settings → General → Login Items.

## How PRs are detected

The panel queries GitHub for open PRs you authored whose body contains "Generated with Claude Code" — the attribution footer Claude Code adds to every PR it opens. If your Claude Code setup uses a different PR footer, adjust the search query in `Sources/Helipad/GitHubClient.swift`.

## License

MIT
