# Railway Cloud Coding Workspace

A self-contained, browser-based cloud development environment that runs entirely
on [Railway](https://railway.com). It gives you **VS Code in the browser**
([code-server](https://github.com/coder/code-server)) with a real Linux
terminal, **[Claude Code](https://code.claude.com/docs)** (Anthropic's official
CLI), **[jcode](https://jcode.sh)**, the **GitHub CLI**, **git**, and common
build utilities — all backed by a persistent Railway volume so your files,
settings, extensions, and logins survive restarts and redeploys.

You clone your repositories, run terminal commands, use Claude Code or jcode,
commit, push, and open pull requests **from inside Railway**. Nothing runs on
your laptop.

> [!NOTE]
> **Two coding agents are available in this workspace:**
> - **Claude Code** — Anthropic's official CLI. It reads your repo's
>   `.claude/` agents, skills, and plugins natively. This is the one to use if
>   you already have a Claude Code workflow. Installed into `/data` on first
>   start and kept up to date by its own background updater.
> - **jcode** — a **third-party** coding-agent harness
>   ([`1jehuang/jcode`](https://github.com/1jehuang/jcode)), **not** an Anthropic
>   product, that can drive several providers (Claude, OpenAI, Gemini, local
>   models) and run agent "swarms." Review its source and data handling before
>   authenticating it with your Claude account. It does **not** read Claude
>   Code's `.claude/` configuration.

> [!IMPORTANT]
> This repository is **only the infrastructure** for the cloud workspace. It does
> **not** contain, build, or modify your production webapp. Deploy it as its own
> **separate** Railway service so it can never touch your production runtime or
> filesystem.

---

## Architecture

```text
Railway container
├── code-server            (browser VS Code, password-protected)
├── Claude Code            (Anthropic's official CLI; reads .claude/ configs)
├── jcode                  (third-party AI coding-agent harness)
├── GitHub CLI (gh)        (auth + PR workflow)
├── Git
├── development utilities  (curl, jq, unzip, build-essential, openssh-client…)
└── mounted volume at /data   (persists across restarts & redeploys)
    ├── home         → HOME               (dotfiles, git identity, Claude Code auth + install)
    ├── config       → XDG_CONFIG_HOME     (gh auth, jcode config, app settings)
    ├── share        → XDG_DATA_HOME       (application data)
    ├── state        → XDG_STATE_HOME      (tokens, logs, misc state)
    ├── cache        → XDG_CACHE_HOME      (caches)
    ├── code-server  → VS Code user data + installed extensions
    └── workspace    → your cloned repositories  (/data/workspace)
```

Your browser talks to code-server over a Railway-generated public domain. Every
edit, terminal command, Claude Code or jcode session, commit, push, and pull
request happens inside the Railway container.

---

## Files in this repository

| File             | Purpose                                                                 |
| ---------------- | ----------------------------------------------------------------------- |
| `Dockerfile`     | Builds the image: code-server base + git, gh, jcode, and dev utilities. |
| `start.sh`       | Entrypoint: prepares `/data`, verifies jcode + Claude Code, launches code-server. |
| `railway.json`   | Tells Railway to build from the Dockerfile and run **one** replica.     |
| `.dockerignore`  | Keeps the build context minimal and secret-free.                        |
| `.gitignore`     | Prevents committing `.env` files, keys, tokens, and local state.        |
| `README.md`      | This document.                                                          |

---

## How the container works

1. **Base image:** [`codercom/code-server`](https://hub.docker.com/r/codercom/code-server)
   (Debian 13). It ships a non-root user **`coder`** (uid 1000) with passwordless
   `sudo`, plus `git`, `curl`, `openssh-client`, and `dumb-init`.
2. **Build (`Dockerfile`):** as root, installs `ca-certificates`, `curl`, `git`,
   `jq`, `unzip`, `build-essential`, `openssh-client`, the **GitHub CLI** (from
   GitHub's official apt repo), and **jcode** (via `curl -fsSL https://jcode.sh/install | bash`).
   The jcode install path is **not assumed** — the build locates the binary
   wherever the installer places it and promotes it to `/usr/local/bin/jcode` so
   it is always on `PATH`. The image then switches back to the non-root `coder`
   user.
3. **Runtime environment:** `HOME` and all `XDG_*` directories point under
   `/data`, so every login and setting is written to the persistent volume — not
   into the ephemeral container layer.
4. **Startup (`start.sh`):** uses strict bash settings, creates the persistent
   directories, repairs volume ownership if Railway mounted a fresh (root-owned)
   volume, verifies **jcode** is present (and safely reinstalls it if not),
   installs **Claude Code** into the `/data` volume on first start if missing,
   **refuses to start without a password**, and finally `exec`s code-server in
   the foreground on `0.0.0.0:${PORT}`, opening `/data/workspace`.

The jcode **binary** lives in the image (always present); jcode **state and
auth** live under `/data` (persisted). A Railway volume mounted at `/data`
shadows anything written there at build time, which is why the binary is baked
into the image and only user state is routed to the volume.

**Claude Code** is handled differently on purpose: its native installer manages
a **self-updating** launcher under `~/.local` (`~/.local/share/claude/versions`),
so baking a fixed copy into the image would break background updates. Instead
`start.sh` installs it into the `/data` volume home on first start — there it
persists, auto-updates itself, and stores credentials at `/data/home/.claude`.

---

## Quick start

You will do steps 1–4 in the Railway dashboard, then steps 5–10 in the
code-server browser terminal.

### 1. Create the Railway service

1. Push this repository to GitHub (your own repo, e.g. `you/cloud-workspace`).
2. In Railway, open (or create) a **project** and click
   **New → GitHub Repo**, then select this repository.
3. Railway detects the `Dockerfile` (and `railway.json`) and builds the image.

**Keep it separate from your production webapp:**

- Deploy this as its **own service** (ideally its **own Railway project**, or at
  least a distinct service in the same project). Do **not** add it to the service
  that runs your webapp.
- Do **not** share the production database, production volume, or production
  environment variables with this workspace. Give it only what it needs
  (`PASSWORD`, and optionally `PORT`/`TZ`).
- This workspace only ever talks to your production app the normal way: by
  pushing branches to GitHub and opening pull requests. It never attaches to the
  production container or filesystem.

### 2. Add variables

In the workspace service → **Variables**, add:

```text
PASSWORD=<a strong, random password>
PORT=8080
TZ=America/New_York
```

| Variable   | Required | Purpose                                                                                     |
| ---------- | -------- | ------------------------------------------------------------------------------------------- |
| `PASSWORD` | **Yes**  | Password for the browser IDE. `start.sh` refuses to start without it. Use a long random value. |
| `PORT`     | No       | Port code-server binds to. Railway usually injects `PORT` automatically; setting `8080` makes it explicit. `start.sh` defaults to `8080` if unset. |
| `TZ`       | No       | Container timezone (e.g. `America/New_York`) for correct timestamps in logs and commits.    |

Generate a strong password, for example:

```bash
openssl rand -base64 24
```

> Never hardcode the password in the repo. It only ever lives as a Railway
> variable. (code-server also supports `HASHED_PASSWORD` if you prefer an
> argon2 hash instead of `PASSWORD`.)

### 3. Attach a volume

In the workspace service → **Settings → Volumes** (or **New → Volume**), attach a
volume with the **mount path**:

```text
/data
```

The volume preserves everything under `/data`:

- **`/data/home`** — your shell dotfiles, history, and **git identity**.
- **`/data/config`** — **GitHub CLI auth** (`gh`) and **jcode config**.
- **`/data/share`, `/data/state`, `/data/cache`** — application data, tokens, and caches.
- **`/data/code-server`** — **VS Code settings and installed extensions**.
- **`/data/workspace`** — your **cloned repositories**.

As long as the volume stays attached, all of the above survives restarts and
redeploys. (Redeploying rebuilds the *image*, but the *volume* is untouched.)

### 4. Generate a domain

In the workspace service → **Settings → Networking → Public Networking**, click
**Generate Domain**. Railway creates a public URL (e.g.
`https://your-workspace.up.railway.app`) and routes it to the container's
`PORT`.

Open that URL in your browser and log in with the value you set for `PASSWORD`.
You now have VS Code in the browser, opened to `/data/workspace`.

### 5. Verify the cloud environment

Open a terminal in code-server (**Terminal → New Terminal**, or `` Ctrl+` ``) and
confirm you are running inside Railway with all tools present:

```bash
hostname
pwd
git --version
gh --version
jcode --version
```

You should be in `/data/workspace`, and each tool should report a version.

### 6. Authenticate GitHub

Log in to GitHub from the cloud terminal:

```bash
gh auth login
```

Choose **GitHub.com → HTTPS → "Login with a web browser"** (or paste a Personal
Access Token). For the web-browser flow, `gh` prints a one-time code and a URL —
open the URL in your own browser, enter the code, and approve. Then verify:

```bash
gh auth status
```

Set your git identity (used for commits) — this persists under `/data/home`:

```bash
git config --global user.name  "YOUR NAME"
git config --global user.email "YOUR EMAIL"
```

> Tip: `gh auth login` can also configure git to use `gh` as its credential
> helper, so `git push` over HTTPS just works. Because `gh`'s config lives under
> `/data/config`, you stay logged in across restarts.

### 7. Authenticate jcode with Claude

First, **inspect the commands supported by the version you actually installed** —
flags can change between releases:

```bash
jcode --help
jcode login --help
```

jcode uses a provider login flow. For Claude:

```bash
jcode login --provider claude
```

Because the terminal runs on a remote server with **no local browser**, use the
**headless / no-browser** flow. On current versions the supported options are:

```bash
# Start login without opening a browser (alias: --headless):
jcode login --provider claude --no-browser

# Or explicitly print the auth URL to open on your own machine:
jcode login --provider claude --print-auth-url
```

Open the printed URL in the browser on your **own computer**, complete the Claude
OAuth sign-in, then hand the result back to jcode using whichever option
`jcode login --help` lists for your version — typically one of:

```bash
jcode login --provider claude --callback-url '<the full redirect URL you were sent to>'
# or
jcode login --provider claude --auth-code '<the code shown after sign-in>'
```

jcode stores its credentials under `/data` (via `HOME`/`XDG_CONFIG_HOME`), so you
stay logged in across restarts.

> Reminder: authenticating here connects **jcode** (a third-party harness) to your
> Claude account. Only do this if you trust the tool. See the warning at the top
> of this README.

### 7b. Authenticate Claude Code (recommended)

Claude Code is Anthropic's official CLI and — unlike jcode — reads your repo's
`.claude/` agents, skills, and plugins natively. Verify it and log in:

```bash
claude --version        # confirm it installed (start.sh installs it on first boot)
claude doctor           # optional: read-only install/health diagnostics
```

Then start it in a project and follow the login prompt:

```bash
cd /data/workspace/<your-repo>
claude
```

On first run Claude Code walks you through authentication. Because the terminal
has **no local browser**, pick the login option and open the printed URL on your
**own computer**, approve, and paste the code back when prompted. Claude Code
requires a **Pro, Max, Team, Enterprise, or Console** account (the free plan does
not include Claude Code). Credentials are stored at `/data/home/.claude`, so you
stay logged in across restarts.

> Prefer an API key instead of the subscription login? Set `ANTHROPIC_API_KEY`
> as a Railway variable and Claude Code will prompt once to approve it. (It is a
> secret — use a Railway variable, never commit it.)

### 8. Clone the real webapp repository

Clone the repo you actually want to work on **onto the Railway volume**:

```bash
cd /data/workspace
gh repo clone OWNER/REPOSITORY
cd REPOSITORY
```

This clone lives on the Railway volume at
`/data/workspace/REPOSITORY` — **on Railway, not on your computer**. It persists
across restarts as long as the volume stays attached.

### 9. Open and use the repository

- In code-server: **File → Open Folder →** `/data/workspace/REPOSITORY`
  (or run `code-server /data/workspace/REPOSITORY` / just start a new window).
- Open a terminal in that folder and start jcode from the project directory:

  ```bash
  cd /data/workspace/REPOSITORY
  jcode
  ```

Your VS Code settings and any extensions you install are saved under
`/data/code-server`, so your editor setup persists too.

### 10. Git and PR workflow

Work on a branch and open a pull request — **never push directly to `main`**:

```bash
# Start from an up-to-date main
git switch main
git pull --ff-only

# Create a feature branch
git switch -c feature/task-name
```

After making changes:

```bash
git status
git diff
git add <specific-files>            # stage intentionally, not "git add ."
git commit -m "Describe the change"
git push -u origin feature/task-name
gh pr create --draft --fill
```

> **Do not push directly to `main`.** Always use a feature branch and a pull
> request so changes are reviewed before they can affect production.

---

## 11. How this workspace relates to your Railway deployment

This workspace is a **development** service. It influences production **only**
through GitHub — never by touching the running production container:

```text
jcode workspace service
→ edits the cloud clone in /data/workspace
→ pushes a feature branch to GitHub
→ opens a pull request
→ your existing Railway webapp service creates a preview deploy (if configured)
→ the PR is reviewed and merged
→ your existing production webapp service deploys main
```

The workspace service **must never directly modify the running production
container**. It has no access to the production runtime or filesystem; it only
produces commits and pull requests on GitHub, which your *separate* production
service deploys through its own normal pipeline.

---

## 12. Cost and resource control

- This workspace is a **separate, billable Railway service**. It bills for
  compute while running and for the **persistent volume** storage it holds.
- Keep it at **one replica** (`railway.json` sets `numReplicas: 1`). You do not
  need horizontal scaling for a single-user IDE.
- **Stop or scale the service down when you are not using it.** In the Railway
  dashboard you can remove the service's replica / pause the service, then resume
  it later — the volume (and all your data) remains intact.
- Configure **usage alerts or spending limits** in Railway
  (**Account/Workspace → Usage**) so runaway usage can't surprise you.
- Heavy builds, large dependency installs, and multi-agent jcode workflows
  consume more CPU, memory, and disk. Watch volume growth (caches,
  `node_modules`, build artifacts) and clean up periodically:

  ```bash
  du -sh /data/* | sort -h
  ```

---

## 13. Security

- **Use a strong, random `PASSWORD`.** The IDE is internet-reachable via the
  public domain; a weak password means anyone can get a full shell.
  `start.sh` will not start without a password.
- **Never commit `.env` files, keys, or tokens.** They are ignored by
  `.gitignore`; keep secrets in **Railway variables** instead.
- **Never store credentials in the repository** — not GitHub tokens, not Claude
  credentials, not Railway or database credentials.
- **Avoid copying unrestricted production credentials into the workspace.** If
  you must access a service, use narrowly-scoped, revocable tokens.
- **Never expose the workspace without authentication.** Do not set
  `--auth none`, and do not remove the password.
- GitHub, Claude, and jcode logins live on the `/data` volume — **not** in git.
  Rotate them if you ever suspect exposure.

---

## What survives a restart or redeploy?

| Stored under `/data`                          | Persists? |
| --------------------------------------------- | --------- |
| Cloned repos (`/data/workspace`)              | ✅        |
| VS Code settings + extensions (`/data/code-server`) | ✅  |
| GitHub CLI auth (`/data/config/gh`)           | ✅        |
| jcode config + auth (under `/data`)           | ✅        |
| Claude Code install + auth (`/data/home/.local`, `/data/home/.claude`) | ✅ |
| Git identity + shell history (`/data/home`)   | ✅        |
| Anything **outside** `/data`                  | ❌ (rebuilt from the image) |

Because user state lives on the volume and the tools live in the image (Claude
Code installs itself into the volume and self-updates there), you can redeploy
freely: the image rebuilds, the volume is untouched.

---

## Troubleshooting

- **Locked out / "cannot log in":** confirm the `PASSWORD` variable is set on the
  service, then redeploy. Check the deploy logs for
  `Refusing to start an unauthenticated IDE`.
- **`jcode: command not found`:** the startup script reinstalls jcode if it is
  missing, but you can always reinstall manually in the terminal:
  `curl -fsSL https://jcode.sh/install | bash`, then reopen the terminal.
- **Files disappeared after a redeploy:** the volume is probably not attached at
  `/data`. The logs print a warning if `/data` is not a mounted volume. Attach a
  volume at `/data` (step 3).
- **git "detected dubious ownership":** already handled at startup, but if you hit
  it, run `git config --global --add safe.directory '*'`.
- **Permission denied writing to `/data`:** the startup script repairs ownership
  automatically using the `coder` user's passwordless `sudo`; check the logs for
  the ownership-repair line.

---

## Limitations & risks

- **jcode is third-party.** It is not Anthropic's official Claude Code client.
  Authenticating it connects an external tool to your provider account.
- **The IDE is internet-exposed.** Its only protection is the `PASSWORD`. Treat
  that password like an SSH key to a machine with all your repo access.
- **The workspace has whatever access you give it.** Once you run `gh auth login`
  and log in to jcode, this container can push to your repos and act as your
  Claude account. Scope tokens narrowly and revoke them when done.
- **Single replica / single user.** This is a personal workspace, not a
  multi-tenant service.
- **Volume = ongoing cost.** Storage bills even while the service is stopped.
  Delete the volume only if you no longer need any of the data on it.
