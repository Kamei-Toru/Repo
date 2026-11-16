#!/bin/zsh
# Install an explicitly named file set; preserve Git metadata and user settings.
# Version: 1.6
# This script was generated using GitHub.
emulate -LR zsh
if [[ ${1:-} == -h || ${1:-} == --help || ${1:-} == —help ]]; then
  print 'Usage: zsh install.zsh'
  print 'Validate configuration, back up changed files, then install Repo and links.'
  print 'Exit status: 0 success or help; 1 installation error; 2 invalid argument; 130 cancelled.'
  exit 0
fi
(( $# == 0 )) || { print -ru2 -- "Unknown argument: $1"; exit 2; }
python3 - "${0:A:h}" <<'PY'
from datetime import datetime
from pathlib import Path
import fcntl
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

VERSION = '1.6'
FILES = ('README.md', 'REVIEW.md', 'repo.zsh', 'repo.pl', 'repo.py', 'shell.zsh',
         'conf.zsh', 'term.zsh', 'install.zsh', 'test_local.py', 'test_config.py')
source = Path(sys.argv[1])
home = Path.home()
actual = home / 'Projects/Repo'
public = home / 'Repo'
startup = home / 'Projects/dotfiles/.zshrc'
root_startup = home / '.zshrc'
written = []
made_links = []
lock_handle = None


def interrupt_install(signum, frame):
    raise KeyboardInterrupt


for handled_signal in (signal.SIGTERM, signal.SIGHUP):
    signal.signal(handled_signal, interrupt_install)


def atomic_write(path, data, mode):
    """Replace one physical file; never replace its containing directory."""
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), mode)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def record_write(path, data, mode):
    previous = path.read_bytes() if path.is_file() else None
    previous_mode = stat.S_IMODE(path.stat().st_mode) if previous is not None else mode
    if previous == data and previous_mode == mode:
        return
    atomic_write(path, data, mode)
    written.append((path, previous, previous_mode, data))


def backup_startup():
    base = home / ('.zshrc.' + datetime.now().strftime('%Y%m%d'))
    number = 0
    while True:
        backup = base if not number else base.with_name(base.name + f'.{number}')
        try:
            output = backup.open('xb')
        except FileExistsError:
            number += 1
            continue
        with output, startup.open('rb') as original:
            shutil.copyfileobj(original, output)
        shutil.copystat(startup, backup)
        return backup


def validate_config(mode):
    manager = source / 'conf.zsh' if mode == '--check' else public / 'conf.zsh'
    result = subprocess.run(['zsh', str(manager), mode], text=True,
                            capture_output=True, env=dict(os.environ, R_HOME=str(public)))
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or 'Configuration validation failed.')
    if mode != '--check' and result.stderr:
        print(result.stderr.rstrip(), file=sys.stderr)


def rollback():
    complete = True
    # Only undo installer-owned writes that have not subsequently been changed.
    for link, target in reversed(made_links):
        try:
            if link.is_symlink() and link.resolve() == target.resolve():
                link.unlink()
        except OSError as error:
            complete = False
            print(f'Could not remove new link {link}: {error}', file=sys.stderr)
    for path, previous, mode, installed in reversed(written):
        try:
            if path.is_symlink() or not path.is_file() or path.read_bytes() != installed:
                complete = False
                print(f'Rollback skipped externally changed file: {path}', file=sys.stderr)
            elif previous is None:
                path.unlink()
            else:
                atomic_write(path, previous, mode)
        except OSError as error:
            complete = False
            print(f'Could not restore {path}: {error}', file=sys.stderr)
    return complete


try:
    # Snapshot sources first, including when installing from the actual directory.
    payload = {}
    for name in FILES:
        path = source / name
        if not path.is_file():
            raise RuntimeError(f'Missing installation source: {name}')
        payload[name] = path.read_bytes()
    if actual.exists() and not actual.is_dir():
        raise RuntimeError(f'Not a directory: {actual}')
    if public.is_symlink() and public.resolve() != actual.resolve():
        raise RuntimeError(f'Unexpected directory link: {public}')
    if public.exists() and not public.is_dir():
        raise RuntimeError(f'Not a directory: {public}')
    for name in (*FILES, 'rep.conf'):
        link, target = public / name, actual / name
        if link.is_symlink() and link.resolve() != target.resolve():
            raise RuntimeError(f'Unexpected file link: {link}')
        if link.exists() and not link.is_symlink() and public.resolve() != actual.resolve():
            raise RuntimeError(f'Expected a symbolic link: {link}')
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise RuntimeError(f'Expected a physical target file: {target}')
    if startup.is_symlink() or (startup.exists() and not startup.is_file()):
        raise RuntimeError(f'Expected a physical zsh configuration: {startup}')
    if root_startup.is_symlink() and root_startup.resolve() != startup.resolve():
        raise RuntimeError(f'Unexpected zsh startup link: {root_startup}')
    if root_startup.exists() and not root_startup.is_symlink():
        raise RuntimeError(f'Expected the dotfiles symlink: {root_startup}')
    # Invalid saved settings must be detected before changing installed files.
    validate_config('--check')
    lock_dir = home / '.repo-locks'
    if lock_dir.is_symlink():
        raise RuntimeError(f'Unexpected lock directory link: {lock_dir}')
    lock_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    lock_path = lock_dir / 'install.lock'
    if lock_path.is_symlink() or (lock_path.exists() and not lock_path.is_file()):
        raise RuntimeError(f'Invalid installation lock: {lock_path}')
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    lock_handle = os.fdopen(descriptor, 'r+')
    deadline = time.monotonic() + 10
    while True:
        try:
            fcntl.lockf(lock_handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise RuntimeError('Another installation is running; retry later.')
            time.sleep(0.05)
    # Recheck after waiting; another installation may have changed the config.
    validate_config('--check')
    startup_original = startup.read_text(encoding='utf-8') if startup.is_file() else ''
    actual.mkdir(parents=True, exist_ok=True)
    public.mkdir(parents=True, exist_ok=True)
    backup_dir = home / '.repo-backups' / str(time.time_ns())
    for name, data in payload.items():
        target = actual / name
        mode = 0o755 if name.endswith(('.zsh', '.py', '.pl')) else 0o644
        if target.is_file() and (target.read_bytes() != data or stat.S_IMODE(target.stat().st_mode) != mode):
            backup_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(target, backup_dir / name)
    for name, data in payload.items():
        mode = 0o755 if name.endswith(('.zsh', '.py', '.pl')) else 0o644
        record_write(actual / name, data, mode)
        link = public / name
        if public.resolve() != actual.resolve() and not link.is_symlink():
            link.symlink_to(actual / name)
            made_links.append((link, actual / name))
    # Keep a newly created valid configuration even if a later startup update fails.
    validate_config('--env')
    original = startup_original
    old = 'source "$HOME/Projects/Repo/shell.zsh"'
    new = 'source "$HOME/Repo/shell.zsh"'
    assignment = 'R_HOME="$HOME/Repo"'
    result, found = [], False
    for line in original.splitlines(keepends=True):
        if line.strip() in (old, new):
            found = True
            if not result or result[-1].strip() != assignment:
                result.append(assignment + '\n')
            result.append(new + '\n')
        else:
            result.append(line)
    if not found:
        if result and not result[-1].endswith('\n'):
            result.append('\n')
        result.extend((assignment + '\n', new + '\n'))
    updated = ''.join(result)
    if updated != original:
        current = startup.read_text(encoding='utf-8') if startup.is_file() else ''
        if current != startup_original:
            raise RuntimeError('The zsh configuration changed during installation; retry after reviewing it.')
        startup.parent.mkdir(parents=True, exist_ok=True)
        if startup.is_file():
            print(f'Startup backup: {backup_startup()}')
        mode = stat.S_IMODE(startup.stat().st_mode) if startup.is_file() else 0o644
        record_write(startup, updated.encode(), mode)
    if not root_startup.is_symlink():
        root_startup.symlink_to(startup)
        made_links.append((root_startup, startup))
    print(f'Installed files in: {actual}')
    print(f'Configuration link: {public / "rep.conf"}')
    if backup_dir.is_dir():
        print(f'Previous project files: {backup_dir}')
    print('Reload: source ~/.zshrc')
    print(f'Verify: repo --version (expected: Repo shell {VERSION})')
except (Exception, KeyboardInterrupt) as error:
    restored = rollback()
    if not restored:
        print('Rollback is incomplete; inspect the reported files and project backups.', file=sys.stderr)
    if isinstance(error, KeyboardInterrupt):
        print('Installation cancelled.', file=sys.stderr)
        sys.exit(130)
    print(f'Error: {error}', file=sys.stderr)
    sys.exit(1)
finally:
    if lock_handle is not None:
        lock_handle.close()
PY
