# Repo

Prepare GitHub repositories, open their remote pages, and enter the first local
project from zsh. The zsh, Perl, and Python workflows share a validated
configuration manager and a terminal helper.

```zsh
repo my-project
repo frontend backend
rf
```

## Installation

Requirements: zsh (including its standard `zsh/system` module), Git, GitHub CLI,
iconv, and the runtime you use (Perl or Python 3). macOS includes iconv.
The installer requires Python 3. Fuzzy navigation uses fzf and, by default, ghq.

On macOS with Homebrew:

```zsh
brew install git gh ghq fzf python perl
gh auth login --hostname github.com
gh auth setup-git --hostname github.com
```

Configure your Git name and email if needed. Extract the update **outside** the
existing repository, then run from the extracted `Repo` directory:

```zsh
zsh install.zsh
source ~/.zshrc
repo --version
```

Expected shell version: `Repo shell 20261115.6`.

The installer updates named files individually in `~/Projects/Repo` and creates
matching links in `~/Repo`. It keeps `.git`, unrelated files, and existing
`rep.conf` values. Both a `~/Repo` directory link and individual file links are
supported. Previous changed project files are backed up under `~/.repo-backups`.
The installer validates saved configuration before replacing any files. Each
file is replaced atomically. On handled errors or interrupts, installer-owned
writes are restored if no other process has changed them. A newly created,
valid configuration is retained. Backups remain available for inspection.
Changed zsh configuration is backed up as `~/.zshrc.YYYYMMDD`, then `.1`, `.2`,
and so on, without overwriting existing backups.

The startup arrangement is:

- `~/.zshrc` links to `~/Projects/dotfiles/.zshrc`.
- That file sets `R_HOME="$HOME/Repo"` and sources `~/Repo/shell.zsh`.
- Runtime scripts and configuration are accessed through `~/Repo` links.

## Commands

| Command | Action |
| --- | --- |
| `repo [NAME ...]` | Prepare repositories and enter the first local project |
| `rz`, `rp`, `ry` | Select zsh, Perl, or Python for that invocation |
| `rf` | Choose a local repository with fuzzy search |
| `conf [settings]` | Create or update configuration |
| `repo -h`, `conf -h` | Display concise English help |
| `repo --version` | Display the shell integration version |

Direct runtime commands also work: `zsh ~/Repo/repo.zsh NAME`,
`perl ~/Repo/repo.pl NAME`, and `python3 ~/Repo/repo.py NAME`. Only the zsh shell
functions can change the calling shell's directory.

## Configuration

The physical file is `~/Projects/Repo/rep.conf`. All runtimes use the
`~/Repo/rep.conf` link through the validating `~/Repo/conf.zsh` manager. The
manager creates a missing configuration and project directory automatically.
A missing physical config is recreated from defaults before `repo` or `rf`
continues. An invalid config is reported; it is never silently reset.

```zsh
conf
conf --dir "$HOME/Work projects" --visibility private
conf ENGINE=python OPEN_WEB=false --show
conf --show
conf --check
conf --reset
```

Without settings, `conf` creates defaults when missing and retains saved
values when present. Unspecified keys use saved values or their defaults.
`--reset` explicitly starts from defaults. Concurrent reads and updates use an
OS-managed advisory lock, avoiding lost settings during simultaneous updates.
Lock metadata lives under `~/.repo-locks`; OS locks are released when the
process exits. Existing settings are preserved by
installation. The supplied `rep.conf` is a default example; it is not copied
over a customized configuration.

### Format

Use UTF-8 text with one literal `KEY=VALUE` per line. Blank lines and lines
starting with `#` are allowed. Do not surround values with shell quotes. Spaces
and `=` inside values are retained. Only a leading `~` or `~/` in `PROJECTS_DIR`
is expanded; shell variables, substitutions, and commands are not evaluated.
Unknown keys, duplicate file keys, invalid UTF-8, invalid values, and control
characters are rejected. `--check` validates without creating files or
directories. Conflicting output modes are rejected.

```text
PROJECTS_DIR=~/Projects
VISIBILITY=private
ENGINE=zsh
OPEN_WEB=true
RETURN_TERMINAL=true
FOCUS_DEBUG=false
SYNC_EXISTING=true
IMPORT_EXISTING=true
USE_GHQ=true
COMMIT_MESSAGE=Import existing files
DEFAULT_BRANCH=main
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `PROJECTS_DIR` | `~/Projects` | Root for new local repositories; created if missing |
| `VISIBILITY` | `private` | `private` or `public` for newly created remotes |
| `ENGINE` | `zsh` | Default `repo` runtime: `zsh`, `perl`, or `python` |
| `OPEN_WEB` | `true` | Open prepared or selected repositories in the browser |
| `RETURN_TERMINAL` | `true` | Return to the terminal after browser opening on macOS |
| `FOCUS_DEBUG` | `false` | Print successful terminal-restoration diagnostics |
| `SYNC_EXISTING` | `true` | Fetch and fast-forward existing local repositories |
| `IMPORT_EXISTING` | `true` | Add, commit, and push local files when creating a remote |
| `USE_GHQ` | `true` | Include ghq repositories in discovery and fuzzy navigation |
| `COMMIT_MESSAGE` | `Import existing files` | Commit message for a new remote's local import |
| `DEFAULT_BRANCH` | `main` | Initial branch when initializing a plain local directory |

`VISIBILITY` never changes existing GitHub repositories. `DEFAULT_BRANCH` does
not rename existing local or GitHub branches. With `IMPORT_EXISTING=false`,
files are retained and linked without an automatic commit or push. With
`SYNC_EXISTING=false`, existing local content is left in place without fetching
or merging. Changing `PROJECTS_DIR` does not move existing repositories.

Legacy environment overrides `R_PROJECTS`, `R_ENGINE`, and `R_FOCUS_DEBUG`
remain available. They take precedence for that invocation. When creating a
new config, their current values seed the corresponding defaults. For example:

```zsh
R_ENGINE=perl repo my-project
R_FOCUS_DEBUG=1 repo my-project
```

## Repository behavior

Names refer to repositories owned by the authenticated GitHub.com user, not
URLs or `owner/name`. Missing or invalid names prompt for input. New remotes
are private by default. Existing linked checkouts under the configured root,
the current directory, or ghq are reused; missing checkouts are cloned.

Existing repositories synchronize by fast-forward only. A changed worktree is
detected before fetch, so it can still be entered when network access is
unavailable. All configured fetch URLs and explicit push URLs must identify
the intended GitHub repository; a mismatch is rejected before creating a remote
or importing files. Uncommitted changes
stop synchronization and remain untouched, while the shell still enters the
first validated local repository. Conflicting remotes and nonempty unlinked
directories require manual reconciliation. Existing remotes are not replaced,
and pushes are not forced. Successful earlier operations are not rolled back
if a later repository fails. A nonzero exit status reports a failure or skipped
synchronization even if directory switching succeeds.

Prepare `.gitignore` before importing existing files. The default import uses
`git add --all`, so every nonignored file and deletion is staged.

`rf` reads the same configuration, enters the selected directory, and opens its
remote if `OPEN_WEB=true`. Successful terminal restoration is quiet unless
`FOCUS_DEBUG=true`. Unverified window visibility remains a warning, and real
activation-verification failures remain visible. Cross-desktop behavior still
depends on macOS Mission Control, Automation, and Accessibility settings.

## Verification

```zsh
python3 test_config.py
zsh -n conf.zsh
zsh -n term.zsh
zsh -n shell.zsh
zsh -n repo.zsh
perl -c repo.pl
python3 -m py_compile repo.py
```

`test_local.py` invokes the same suite for compatibility.

Tests use real local Git repositories and mocked GitHub/browser/focus commands.
They do not create real GitHub repositories, publish files, or switch desktops.
Actual GUI focus behavior must be checked on the target Mac.

## Shared terminal helper and source review

`term.zsh` contains the single terminal capture/restore implementation used by
all runtimes and shell functions. It is installed physically in
`~/Projects/Repo` and called through `~/Repo/term.zsh`. Successful restoration
remains silent by default; `ACTIVE_ONLY` remains a visibility warning. Direct
runtime commands and shell functions return nonzero when activation
verification fails while retaining any available local destination.

See [REVIEW.md](REVIEW.md) for the review findings, fixes, and regression tests.
