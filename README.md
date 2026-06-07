<img width="388" height="575" alt="image" src="https://github.com/user-attachments/assets/f785348e-1f60-4024-9ea2-dd90ed74f6c4" /># ClaudeUsage

A Claude-themed macOS menu-bar app that shows your **real Claude Max plan usage** —
the live 5-hour window and weekly limits (from the same endpoint Claude Code's
`/usage` uses) — with burn-rate "time-to-limit", a live 5-hour usage graph,
estimated spend, and green→amber→red severity colors. Pixel "Clawd" mascot +
Claude serif type.

## Build & run

```bash
./build.sh
```

Compiles an unsigned `.app` and launches it. Click the orange spark in your menu
bar. The first time, macOS prompts for Keychain access to read your Claude Code
credentials — click **Always Allow**.

## What it shows

- **Current** — live 5-hour window %, reset countdown, and a burn-rate line
  ("≈ 40m left at this pace").
- **Current 5-Hour Window graph** — real utilization climbing, with a dashed
  projection to where you'll land by reset and a 100% cap line.
- **Weekly** — live 7-day limit % + reset countdown.
- **5H Spend** — estimated API-equivalent $ of this window's tokens (not a real
  bill; Max is flat-rate).
- Menu-bar % turns amber/red as you near a cap; optional threshold notifications.

## How it works

- **Local activity**: parses `~/.claude/projects/**.jsonl` for token usage.
- **Live plan limits**: reads the OAuth token Claude Code stored in your macOS
  Keychain and calls `api.anthropic.com/api/oauth/usage`.

> This `/api/oauth/usage` endpoint is **undocumented** and may change with Claude
> Code updates. It's polled gently (90s) to avoid rate limits. Nothing leaves your
> machine except that authenticated request to Anthropic's own servers.

Your personal data (`limits.json`, `history.json`, `plan.json`) is gitignored.  


<img width="388" height="575" alt="image" src="https://github.com/user-attachments/assets/1f9260f8-ef9c-4b79-a976-772fbfb46a45" />

