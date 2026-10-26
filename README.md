# CodexReset

<img width="1280" height="258" alt="image" src="https://github.com/user-attachments/assets/766c58f1-5264-469b-b641-bfe8787caefa" />

**An app that keeps Codex on the job.**

A tiny macOS menu-bar companion for the **Codex** desktop app. It watches your
5-hour / 1-week usage windows, detects conversations that were paused because
you hit your usage limit, and **automatically resumes them with “Continue” (or any
command) the moment your usage is back** — so you never have to babysit the
"upgrade / try again at HH:MM" wall again.

> Not an official OpenAI product. CodexReset is an independent, open-source
> utility that only talks to the local Codex app on your own machine.

---


<img width="2048" height="1218" alt="image" src="https://github.com/user-attachments/assets/c4ddef65-c347-40ff-8487-13db60605e76" />




## Why

When a Codex session hits its usage cap, Codex pauses the active conversation
and says something like:

> You've reached your usage limit. Upgrade your plan or top up to continue, or
> try again at 13:18.

Usage resets on a rolling **5-hour window**, and every paused conversation has
to be manually continued by switching to it and typing "Continue". If you run
several agents/projects at once, that's a lot of babysitting.

**CodexReset does it for you.**

## Features

- **Menu-bar status** — live 5h / 1w usage bars, next-reset countdown, plan
  type and credit balance at a glance.
- **Auto-resume** — when the 5h window resets, CodexReset automatically sends
  "Continue" to the conversations you've checked. Nothing is pre-selected: tick the
  paused conversations you care about (or hit "select all"), or add any other
  conversation from the full list.
- **Browse all conversations** — every project and its conversations are listed
  (grouped by project, archived and sub-agent threads filtered out). Check any
  conversation, even one that isn't paused yet, to have it resumed too.
- **Double-click to jump** — opens the conversation in Codex via its deep link.
- **Usage history timeline** — each 5h window reset is recorded automatically,
  so you can see the exact time usage recovers every day.
- **Detects pauses for you** — conversations stopped by
  `usageLimitExceeded` are found automatically, with their recovery time shown.
- **CLI mode** — `--query` prints usage, `--continue <thread_id>` resumes one
  thread from the terminal.

### How auto-resume works

Two channels, most reliable first:

1. **Local app-server (preferred)** — talks to Codex's bundled local
   app-server (`remote_control` or a spawned private instance) and starts a new
   turn with your command. No accessibility permissions needed.
2. **GUI fallback** — if the desktop app holds the current conversation, it
   deep-links into Codex, focuses the input box, pastes your command and sends
   it with **⌘Enter** (requires **Accessibility** permission).

## Requirements

- macOS 14+
- The [Codex desktop app](https://openai.com/codex/) (this is a companion, it
  doesn't bundle Codex itself)
- Xcode command line tools for building (`xcode-select --install`)

## Install & run

### Build

```bash
git clone https://github.com/boyso/codex-reset.git
cd codex-reset
swift build -c release
```

### Use as a menu-bar app (recommended)

```bash
./make_app.sh              # builds & installs /Applications/CodexReset.app
./install_launchagent.sh   # (optional) auto-start at login via LaunchAgent
```

Then click the menu-bar icon to open the panel. Optionally:

- Give **CodexReset** Accessibility permission (System Settings →
  Privacy & Security → Accessibility) so the GUI fallback channel can type into
  Codex. The panel shows a live "Accessibility" status so you know when it's
  granted.
- Enable **remote_control** (toggle in the panel, then restart the Codex app)
  to use the official local protocol channel — no accessibility permission
  needed, and it survives re-signing.

### CLI only

```bash
.build/release/CodexReset --query                    # usage + paused threads
.build/release/CodexReset --continue <thread_id>     # resume one thread now
```

## Keep Mac awake while a selected task is pending (opt-in)

In Settings (gear icon), turn on **Prevent sleep while waiting**.

- When auto-continue is enabled and a **checked** conversation's latest turn has failed with `usageLimitExceeded`, CodexReset temporarily prevents macOS **idle system sleep** while awaiting quota recovery.
- It also holds the activity while a checked conversation is executing a turn (including after an automatic resume), to avoid going to sleep midway through the task.
- As soon as no checked task is awaiting quota or running, or you deselect the chat, disable auto-continue, turn off the option, or quit the app, the activity is released. State is rechecked every 30 seconds.
- **Off by default.** This may drain the battery more quickly. It does not keep the display on, stop lid-close or manual sleep, or protect against battery depletion.

The setting does not change system-wide macOS sleep preferences; it uses a temporary per-process activity.

## Configuration

Both the menu-bar panel and Settings use a consistent high-contrast dark theme, even when macOS is set to Light Mode. Restart the app after rebuilding to apply the new appearance.


The app displays built-in UI copy, notifications, errors, and its default continuation command in English regardless of the macOS language. The previous Chinese default command is migrated to `Continue`; customized commands remain untouched.


| Setting | Where |
|---|---|
| Auto-resume on/off | panel toggle `Auto-continue after usage resets` |
| Prevent idle sleep while selected tasks are pending/running | Settings gear → `Prevent sleep while waiting` (off by default) |
| Command sent | panel `Command` field (default `Continue`) |
| Which conversations | checkbox list in the panel |
| `remote_control` | panel toggle (writes `config.toml`) |
| `CODEX_HOME` | env var overrides `~/.codex` (advanced) |

## Privacy

- CodexReset reads only **local** files (`~/.codex` state and history
  databases, read-only) and talks to Codex's local app-server over a local
  socket.
- No data leaves your machine. No account, no telemetry.

## Building the .app icon

`Resources/generate_icon.py` turns a transparent-background/irregular
`logo.png` into a proper `AppIcon.icns` (center-padded to a square canvas,
LANCZOS scaling). Replace `logo.png` and re-run `./make_app.sh`.

## Contributing / disclaimer

PRs and issues are welcome. This project was reverse-engineered from local
behavior and may break when Codex updates — please open an issue with the
error and version. Use at your own risk; automated "Continue" will consume usage in
the normal way within your plan.

## License

[MIT](LICENSE) © 2026 BOYSO
