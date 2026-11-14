# Repo

Prepare GitHub repositories and start working from your terminal. Create or reuse
repositories, open them in your browser, and move into the first project's local
directory with one command.

```zsh
repo my-project
repo frontend backend
```

## Features

- Three independent implementations: zsh, Perl, and Python.
- Interactive name entry and validation.
- Multiple repositories in a single command.
- Private GitHub repository creation and local cloning.
- Import of existing local files with add, commit, and push.
- Reuse of linked local repositories and fast-forward synchronization.
- Automatic directory switching through zsh functions.
- Fuzzy repository navigation with ghq and fzf.

## Requirements

Git and the GitHub CLI (`gh`) are required. Install the runtime for the
implementation you want to use:

| Implementation | Runtime | Command after shell setup |
| --- | --- | --- |
| `repo.zsh` | zsh | `repo` or `rz` |
| `repo.pl` | Perl with core modules | `rp` |
| `repo.py` | Python 3 with the standard library | `ry` |

The shell integration requires zsh. The `rf` command additionally requires ghq
and fzf. If ghq is installed, repository preparation also uses its repository
list and reports errors if that command fails.

## Installation

### 1. Install dependencies

On macOS with Homebrew, install the tools you need. This example installs all
three runtimes and the optional navigation tools:

```zsh
brew install git gh ghq fzf python perl
```

### 2. Authenticate with GitHub

```zsh
gh auth login --hostname github.com
gh auth setup-git --hostname github.com
```

If your Git identity is not already configured, set your name and email:

```zsh
git config --global user.name 'Your Name'
git config --global user.email 'you@example.com'
```

### 3. Place the project files

Place the following files directly in `~/Projects/Repo`:

| File | Purpose |
| --- | --- |
| `README.md` | Setup and usage documentation |
| `repo.zsh` | Independent zsh implementation |
| `repo.pl` | Independent Perl implementation |
| `repo.py` | Independent Python implementation |
| `shell.zsh` | Shell commands and directory switching |
| `test_local.py` | Local integration tests |

### 4. Enable shell commands

Add this line once to your zsh configuration:

```zsh
source "$HOME/Projects/Repo/shell.zsh"
```

For a dotfiles setup where `~/.zshrc` points to
`~/Projects/dotfiles/.zshrc`, add the line to that target file and keep the
existing symlink.

Reload your configuration and check the help:

```zsh
source ~/.zshrc
repo -h
```

## Usage

| Command | Action |
| --- | --- |
| `repo` | Prompt for a repository name and prepare it |
| `repo alpha` | Prepare `alpha` and enter its local directory |
| `repo alpha beta` | Prepare both repositories and enter `alpha` |
| `repo -h` or `repo --help` | Display help |
| `rz alpha` | Use the zsh implementation |
| `rp alpha` | Use the Perl implementation |
| `ry alpha` | Use the Python implementation |
| `rf` | Select a local repository with fuzzy search and enter it |

Repository names refer to the authenticated GitHub.com user's repositories.
Use names such as `my-project`, rather than URLs or `owner/name` values.
Organization repositories and GitHub Enterprise are outside the current scope.

Names must contain 1-100 ASCII letters, digits, dots, underscores, or hyphens.
The names `.` and `..`, and names ending in `.git`, are rejected. Missing or
invalid names prompt for input until a valid name is provided or input ends.

### Direct execution

Each implementation can run independently:

```zsh
zsh ~/Projects/Repo/repo.zsh alpha beta
perl ~/Projects/Repo/repo.pl alpha beta
python3 ~/Projects/Repo/repo.py alpha beta
```

A child process cannot change the calling shell's directory. Use the shell
commands above when you want automatic `cd`.

## Repository preparation

### Existing GitHub repositories

Repo searches for a linked local repository in the current directory,
recursively under `~/Projects`, and in the output of `ghq list --full-path`.
It prefers `~/Projects/NAME` when that directory is already linked. Repositories
outside these locations must be discoverable through ghq or the current directory.

If no linked repository is found, Repo clones to `~/Projects/NAME`. Existing
linked repositories are fetched, and the current branch is updated with a
fast-forward merge when the working tree is clean and the matching remote
branch exists. Local commits ahead of the remote are reported and retained.

### New GitHub repositories

Repo creates a **private** GitHub repository. If a local directory already
contains files, Repo initializes Git when necessary, adds the remote, stages
nonignored files and deletions, commits staged changes, and pushes the current
branch with an upstream. Existing history is retained.

Prepare your `.gitignore` before importing files: `git add --all` includes all
nonignored files. New empty directories are cloned without an artificial commit.

Repo attempts to open each prepared repository in the browser. If browser
launching fails, it prints the repository URL and continues.

### Conflicts and failures

- Different repository remotes, symbolic-link destinations, and directories
  nested in another worktree are rejected.
- Uncommitted changes, detached HEAD, missing matching remote branches, and
  divergent histories require manual resolution.
- A nonempty plain directory cannot be automatically combined with an existing
  remote repository; reconcile its contents manually.
- Only an explicit HTTP 404 from the lookup is treated as repository absence.
  Other lookup failures are reported.
- Processing continues after a repository fails, and the overall exit status
  is nonzero if any repository failed.
- The shell enters the first argument's repository only if that argument
  succeeded, including when a later argument fails.

Completed operations are not rolled back after a later failure. Repositories,
commits, or remote links already created remain in place. Review the reported
error and the repository state before retrying. Pushes are never forced and
existing remotes are never replaced automatically.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `R_ENGINE` | `zsh` | Implementation used by `repo`: `zsh`, `perl`, or `python` |
| `R_PROJECTS` | `~/Projects` | Local repository root |
| `R_HOME` | Directory containing `shell.zsh` | Directory containing the three scripts |

For example, select Python in your zsh configuration:

```zsh
export R_ENGINE=python
source "$HOME/Projects/Repo/shell.zsh"
```

`rf` combines ghq's repository list with repositories found under `R_PROJECTS`.
This includes the flat `~/Projects/NAME` layout without changing ghq's usual
`HOST/OWNER/NAME` layout or its global configuration.

## Output and exit status

Direct execution prints the first argument's absolute local directory to
standard output when that argument succeeds. Operational messages and errors
go to standard error; help goes to standard output. The shell integration reads
the returned path without evaluating it as shell code.

Exit status is zero when all requested repositories are prepared successfully,
and nonzero when input, setup, or any repository operation fails.

## Development

Run the checks from the project directory:

```zsh
cd ~/Projects/Repo
python3 test_local.py
zsh -n repo.zsh
zsh -n shell.zsh
perl -c repo.pl
python3 -m py_compile repo.py
```

Integration tests use real Git, temporary local repositories, and a fake `gh`
command. They do not create repositories on GitHub or launch a browser. Real
GitHub authentication, permissions, and browser integration must be verified
separately in the target environment.

## References

- [GitHub CLI: create a repository](https://cli.github.com/manual/gh_repo_create)
- [GitHub CLI: clone a repository](https://cli.github.com/manual/gh_repo_clone)
- [GitHub CLI: view a repository](https://cli.github.com/manual/gh_repo_view)
- [ghq](https://github.com/x-motemen/ghq)
