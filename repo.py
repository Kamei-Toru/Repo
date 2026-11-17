#!/usr/bin/env python3
# Version: 1.8a
"""Prepare GitHub repositories. All subprocess arguments are passed without a shell."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

os.environ["GH_HOST"] = "github.com"

SCRIPT_VERSION = "1.8a"

HELP = """repo - Prepare GitHub repositories for local development.
Settings: ~/Repo/rep.conf (created automatically when missing).

Usage: repo [NAME ...]

Examples:
  repo                 Prompt for a repository name.
  repo alpha beta      Prepare both; enter alpha via shell integration.

Arguments:
  NAME ...             Repository names; prompt if omitted or invalid.
                       Skip arguments starting with - (except help/version).

Options:
  -h, --help           Show this help.
  -v, --version        Show the script version.

Exit status:
  0                    Success (including help).
  nonzero              Failure or cancellation.
"""


def run(*args, cwd=None, check=True):
    p = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE)
    if check and p.returncode:
        raise RuntimeError(p.stderr.strip() or p.stdout.strip() or f"Command failed: {args[0]}")
    return p


CONFIG = {}
TERMINAL_FAILED = False


def load_config():
    manager = Path(os.environ.get("R_HOME", str(Path.home() / "Repo"))) / "repo_conf.zsh"
    if not manager.is_file():
        raise RuntimeError(f"Missing configuration manager: {manager}. Run repo_install.zsh.")
    data = run("zsh", str(manager), "--env").stdout
    return dict(line.split("=", 1) for line in data.splitlines() if line)


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
    if CONFIG["USE_GHQ"] == "true" and shutil.which("ghq"):
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


class DirtyWorktreeError(RuntimeError):
    """Keep the validated local destination available when synchronization stops."""
    def __init__(self, path):
        self.path = path.resolve()
        super().__init__(f"Working tree has changes; synchronization skipped: {path}")


def sync(path, remote):
    if git(path, "status", "--porcelain").stdout:
        raise DirtyWorktreeError(path)
    git(path, "fetch", remote, "--prune")
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


def open_web(full):
    global TERMINAL_FAILED
    if CONFIG["OPEN_WEB"] != "true":
        return
    restore = CONFIG["RETURN_TERMINAL"] == "true" and os.environ.get("R_DEFER_FOCUS") != "1"
    helper = Path(os.environ.get("R_HOME", str(Path.home() / "Repo"))) / "repo_term.zsh"
    terminal_app = os.environ.get("R_RETURN_APP", "")
    if restore and not terminal_app:
        capture = run("zsh", str(helper), "capture", check=False)
        terminal_app = capture.stdout.strip() if capture.returncode == 0 else ""
    browser = run("gh", "repo", "view", full, "--web", check=False)
    if browser.returncode:
        say(f"Could not open browser: https://github.com/{full}")
    if restore:
        if not terminal_app:
            say("Could not identify the invoking terminal; focus return was not attempted.")
            TERMINAL_FAILED = True
            return
        caller_tty = os.environ.get("R_CALLER_TTY", "")
        if not caller_tty:
            try:
                caller_tty = os.ttyname(0)
            except OSError:
                pass
        result = run("zsh", str(helper), "restore", terminal_app, caller_tty,
                     os.environ.get("R_FOCUS_DEBUG", CONFIG["FOCUS_DEBUG"]), check=False)
        if result.stderr.strip():
            say(result.stderr.strip())
        TERMINAL_FAILED = TERMINAL_FAILED or result.returncode != 0


def validate_remotes(path, full):
    # Git can fetch from its first URL and push to separately configured URLs.
    for remote in git(path, "remote").stdout.splitlines():
        for field in ("url", "pushurl"):
            result = git(path, "config", "--get-all", f"remote.{remote}.{field}", check=False)
            if result.returncode == 1 and field == "pushurl":
                continue
            if result.returncode:
                raise RuntimeError(f"Cannot read remote {field} for {remote}: {path}")
            for url in result.stdout.splitlines():
                if remote_id(url) != full.lower():
                    raise RuntimeError(f"Conflicting remote {field} for {remote}: {path}")


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
            validate_remotes(path, full)
        elif not new and any(path.iterdir()):
            raise RuntimeError(f"Existing remote and nonempty unlinked directory: {path}")
    if new:
        run("gh", "repo", "create", full, "--" + CONFIG["VISIBILITY"])
    open_web(full)
    if not path.exists() or (not is_root(path) and not any(path.iterdir())):
        run("gh", "repo", "clone", full, str(path))
    else:
        if not is_root(path):
            git(path, "init", "-b", CONFIG["DEFAULT_BRANCH"])
        if remote not in git(path, "remote").stdout.splitlines():
            git(path, "remote", "add", remote, f"https://github.com/{full}.git")
        if new and CONFIG["IMPORT_EXISTING"] == "true":
            git(path, "add", "--all")
            diff = git(path, "diff", "--cached", "--quiet", check=False)
            if diff.returncode not in (0, 1):
                raise RuntimeError(diff.stderr.strip())
            if diff.returncode == 1:
                git(path, "commit", "-m", CONFIG["COMMIT_MESSAGE"])
            if git(path, "rev-parse", "--verify", "HEAD", check=False).returncode == 0:
                git(path, "push", "--set-upstream", remote, "HEAD")
        elif not new and CONFIG["SYNC_EXISTING"] == "true":
            sync(path, remote)
    say(f"Ready: {path}")
    return path.resolve()


def main():
    global CONFIG
    args = sys.argv[1:]
    if any(flag in args for flag in ("-v", "--version")):
        print(f"repo.py {SCRIPT_VERSION}")
        return 0
    if "-h" in args or "--help" in args or "—help" in args:
        print(HELP)
        return 0
    if args:
        args = [arg for arg in args if not arg.startswith("-")]
        if not args:
            return 0
    CONFIG = load_config()
    names = [read_name(s) for s in args] if args else [read_name()]
    for dependency in ("git", "gh"):
        if not shutil.which(dependency):
            raise RuntimeError(f"Missing dependency: {dependency}")
    run("gh", "auth", "status", "--hostname", "github.com")
    owner = run("gh", "api", "user", "--jq", ".login").stdout.strip()
    root = Path(os.environ.get("R_PROJECTS", CONFIG["PROJECTS_DIR"])).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    first, failed = None, False
    for i, name in enumerate(names):
        try:
            path = prepare(root, owner, name)
            if i == 0:
                first = path
        except RuntimeError as error:
            if i == 0 and isinstance(error, DirtyWorktreeError):
                first = error.path
            failed = True
            say(f"Error [{name}]: {error}")
    if first:
        print(first)
    return 1 if failed or TERMINAL_FAILED else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as error:
        say(f"Error: {error}")
        sys.exit(1)
    except (KeyboardInterrupt, EOFError):
        say("Cancelled.")
        sys.exit(130)
