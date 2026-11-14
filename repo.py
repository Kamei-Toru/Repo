#!/usr/bin/env python3
"""Prepare GitHub repositories. All subprocess arguments are passed without a shell."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

os.environ["GH_HOST"] = "github.com"

HELP = """Usage: repo.py [--] [NAME ...]
Prepare repositories on github.com for the authenticated GitHub user.
Prompt for missing or invalid names. Create new repositories as private.
Reuse linked repositories found under ~/Projects, the current directory,
and ghq roots; otherwise use ~/Projects/NAME. Open every repository on the web.
New remotes: stage, commit, and push existing local files (respect .gitignore).
Existing remotes: fetch; fast-forward only when the working tree is clean.
No force pushes, automatic merges, remote replacement, or unrelated history merges.
-h, --help  Show this help. Use the supplied zsh functions to change shell directory.
Dependencies: git, gh, Python 3. Optional: ghq and fzf for the rf shell function.
Environment: R_PROJECTS (default ~/Projects). Names: ASCII letters, digits, . _ -,
1-100 characters, excluding ., .., and names ending in .git. Repository names, not owner/name, are accepted.
"""


def run(*args, cwd=None, check=True):
    p = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"Command failed: {args[0]}")
    return p


def say(message):
    print(message, file=sys.stderr)


def valid(name):
    return bool(re.fullmatch(r"[A-Za-z0-9_.-]{1,100}", name)) and name not in (".", "..") and not name.lower().endswith(".git")


def read_name(value=""):
    while not valid(value):
        if value:
            say(f"Invalid repository name: {value!r}")
        print("Repository name: ", end="", file=sys.stderr, flush=True)
        value = sys.stdin.readline()
        if not value:
            raise RuntimeError("Input ended before a valid repository name was provided.")
        value = value.rstrip("\r\n")
    return value


def remote_id(url):
    match = re.fullmatch(r"(?:https?://github\.com/|ssh://git@github\.com/|git@github\.com:)([^/]+/[^/]+?)(?:\.git)?/?", url)
    return match.group(1).lower() if match else None


def git(path, *args, check=True):
    return run("git", "-C", str(path), *args, check=check)


def is_root(path):
    p = git(path, "rev-parse", "--show-toplevel", check=False)
    return p.returncode == 0 and Path(p.stdout.strip()).resolve() == path.resolve()


def candidates(root):
    found = {Path.cwd().resolve()}
    if shutil.which("ghq"):
        p = run("ghq", "list", "--full-path", check=False)
        if p.returncode:
            raise RuntimeError(p.stderr.strip() or "ghq list failed.")
        found.update(Path(s) for s in p.stdout.splitlines())
    # Discover worktrees and ordinary repositories without entering their contents.
    for base, dirs, files in os.walk(root):
        if ".git" in dirs or ".git" in files:
            found.add(Path(base))
            dirs[:] = []
        else:
            dirs[:] = [s for s in dirs if s not in ("node_modules", ".cache", ".Trash")]
    return sorted(found)


def choose_path(root, name, full):
    dest = root / name
    linked = []
    for path in [dest, *candidates(root)]:
        if not path.is_dir() or not is_root(path):
            continue
        for remote in git(path, "remote").stdout.splitlines():
            if remote_id(git(path, "config", "--get", f"remote.{remote}.url").stdout.strip()) == full.lower():
                linked.append((path, remote))
                break
    if linked:
        return next((x for x in linked if x[0].resolve() == dest.resolve()), linked[0])
    return dest, "origin"


def sync(path, remote):
    git(path, "fetch", remote, "--prune")
    if git(path, "status", "--porcelain").stdout:
        raise RuntimeError(f"Working tree has changes; synchronize manually: {path}")
    branch = git(path, "symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    if branch.returncode:
        raise RuntimeError(f"Detached HEAD; select a branch: {path}")
    branch = branch.stdout.strip()
    refs = git(path, "for-each-ref", "--format=%(refname)", f"refs/remotes/{remote}/").stdout.splitlines()
    if not refs:
        return
    target = f"refs/remotes/{remote}/{branch}"
    if target not in refs:
        raise RuntimeError(f"No matching remote branch for {branch}; synchronize manually: {path}")
    if git(path, "rev-parse", "--verify", "HEAD", check=False).returncode:
        git(path, "checkout", "-B", branch, target)
    else:
        git(path, "merge", "--ff-only", target)
    git(path, "branch", f"--set-upstream-to={remote}/{branch}", branch)
    ahead = git(path, "rev-list", "--count", f"{target}..HEAD").stdout.strip()
    if ahead != "0":
        say(f"Local commits are ahead of the remote ({ahead}); push them manually: {path}")


def prepare(root, owner, name):
    full = f"{owner}/{name}"
    p = run("gh", "api", f"repos/{full}", "--jq", ".full_name", check=False)
    new = p.returncode != 0
    if new and "(HTTP 404)" not in p.stderr:
        raise RuntimeError(p.stderr.strip() or "GitHub lookup failed.")
    if not new:
        full = p.stdout.strip()
    path, remote = choose_path(root, name, full)
    if path.is_symlink():
        raise RuntimeError(f"Refusing a symbolic-link destination: {path}")
    if path.exists():
        if not path.is_dir():
            raise RuntimeError(f"Destination is not a directory: {path}")
        if not is_root(path):
            # Never initialize a nested directory within another worktree.
            parent_repo = git(path, "rev-parse", "--show-toplevel", check=False)
            if parent_repo.returncode == 0:
                raise RuntimeError(f"Destination is inside another repository: {path}")
        if is_root(path):
            for r in git(path, "remote").stdout.splitlines():
                url = git(path, "config", "--get", f"remote.{r}.url").stdout.strip()
                if remote_id(url) != full.lower():
                    raise RuntimeError(f"Conflicting remote {r} at {path}: {url}")
        elif not new and any(path.iterdir()):
            raise RuntimeError(f"Existing remote and nonempty unlinked directory: {path}")
    if new:
        run("gh", "repo", "create", full, "--private")
    browser = run("gh", "repo", "view", full, "--web", check=False)
    if browser.returncode:
        say(f"Could not open browser: https://github.com/{full}")
    if not path.exists() or (not is_root(path) and not any(path.iterdir())):
        run("gh", "repo", "clone", full, str(path))
    else:
        if not is_root(path):
            git(path, "init", "-b", "main")
        if remote not in git(path, "remote").stdout.splitlines():
            git(path, "remote", "add", remote, f"https://github.com/{full}.git")
        if new:
            git(path, "add", "--all")
            diff = git(path, "diff", "--cached", "--quiet", check=False)
            if diff.returncode not in (0, 1):
                raise RuntimeError(diff.stderr.strip())
            if diff.returncode == 1:
                git(path, "commit", "-m", "Import existing files")
            if git(path, "rev-parse", "--verify", "HEAD", check=False).returncode == 0:
                git(path, "push", "--set-upstream", remote, "HEAD")
        else:
            sync(path, remote)
    say(f"Ready: {path}")
    return path.resolve()


def main():
    args = sys.argv[1:]
    if "-h" in args or "--help" in args or "—help" in args:
        print(HELP)
        return 0
    if args[:1] == ["--"]:
        args.pop(0)
    names = [read_name(s) for s in args] if args else [read_name()]
    for dependency in ("git", "gh"):
        if not shutil.which(dependency):
            raise RuntimeError(f"Missing dependency: {dependency}")
    run("gh", "auth", "status", "--hostname", "github.com")
    owner = run("gh", "api", "user", "--jq", ".login").stdout.strip()
    root = Path(os.environ.get("R_PROJECTS", "~/Projects")).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    first, failed = None, False
    for i, name in enumerate(names):
        try:
            path = prepare(root, owner, name)
            if i == 0:
                first = path
        except RuntimeError as error:
            failed = True
            say(f"Error [{name}]: {error}")
    if first:
        print(first)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        say(f"Error: {error}")
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        say("Cancelled.")
        sys.exit(130)
