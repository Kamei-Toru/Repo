# Source review: 1.8a

The review examined configuration parsing and updates, installation, Git URL
validation, directory navigation on failure, and consistency across the three
runtime implementations. Changes retain the established defaults and command
names. Comments, help, messages, and documentation remain in English.

## Findings and fixes

| Priority | Finding | Change | Regression coverage |
| --- | --- | --- | --- |
| High | A saved-config error was detected after project files had already been replaced | Read-only `conf --check` preflight before installation writes | Invalid config leaves installed files and links untouched |
| High | A matching fetch URL could hide a different push URL or another configured fetch URL | Validate all fetch and explicit push URLs before remote creation/import; do not print raw URL credentials in these diagnostics | All runtimes reject conflicting and empty URL settings without creating a remote or committing files |
| Medium | Two concurrent config writers could overwrite each other's changes | Stable advisory lock plus atomic replacement; no stale lock-directory ownership scheme | Four simultaneous changes are all retained |
| Medium | Mid-install failure could leave mixed file versions | Atomic per-file writes, previous-file backups, and rollback for handled failures and interrupts | Provisioning failure and termination restore original files and preserve `.git`; invalid startup text is rejected early and concurrent startup edits are retained |
| Medium | Fetch failure could prevent navigation to an already known dirty worktree | Detect local changes before fetching | A deliberately failing fetch command is never called for dirty worktrees; every runtime returns the local path |
| Medium | Terminal code was duplicated across four files and direct runtimes handled failure differently | One `repo_term.zsh` helper, shared result policy, and consistent nonzero focus-failure status | Quiet success, debug output, visibility warnings, failed activation, and available directory output |
| Low | Unknown installer options were ignored; conflicting config modes and malformed text were not fully rejected | Reject unknown options, conflicting modes, invalid UTF-8, control characters, and physical-config symlinks | Rejected inputs preserve configuration and cause no GitHub calls |

## Verification

The suite contains 31 isolated tests with additional per-runtime subtests. It
uses real local Git repositories and mocked GitHub, browser, and activation
commands. It checks defaults, directory creation, private/public remotes,
literal values, config recovery, both link layouts, startup-backup numbering,
concurrency, installer preflight/rollback, remote safety, dirty navigation, and
terminal results. It does not publish to GitHub or manipulate the desktop.

Run `python3 test_repo_config.py` from this directory. `test_repo_local.py` is a compatible
entry point for the same suite. zsh, Perl, and Python syntax checks also apply.

Actual focus switching across macOS Spaces remains a target-machine check.
The helper distinguishes activation from window visibility and does not claim
that application activation alone proves a visible desktop switch. Rollback
preserves externally modified files and reports them instead of overwriting
concurrent changes. Newly created valid configuration data is retained.

## Version 1.8a follow-up review

- All nine executable scripts have an English `Version: 1.8a` comment and a
  side-effect-free `--version` path; the sourced shell file does not exit its
  caller when the caller supplies that argument.
- The three renamed helper paths are used by all runtime implementations,
  installation manifests, tests, and documentation.
- The installer migrates only recognized Repo source lines, preserving source
  lines and helper links owned by other projects.
- `~/Projects/Dotfiles/.zshrc` is the physical startup configuration. Identity
  checks accept an equivalent case spelling or directory alias and reject an
  unrelated target. Backup contents are read from that physical file.
- Tests verify zero-based-name backup preservation, suffixes beginning at `.1`,
  selection of `.2` when both earlier names exist, and repeat-install idempotence.
- The full suite includes 31 tests plus per-script and per-runtime subtests.
  Real GUI switching across Spaces remains outside the automated test scope.

The Version 1.8a identity review also rejects a separate hard-linked startup
file: an inode match alone is insufficient for a file that will be replaced
atomically. Accepted aliases must identify the same directory entry.

## Version 1.8a rename review

Verified that the three renamed files are used consistently by the installer,
all repository runtimes, shell functions, and the compatibility test entry
point. All nine scripts retain side-effect-free `--version` handling and
version comments set to `1.8a`. No configuration keys or repository behavior
were changed for this filename-only update.

## Version 1.8a review

Reviewed argument filtering before configuration and terminal focus side effects
in all repository runtimes and shell wrappers. Help and version take precedence.
Checked the configuration visibility shortcut conflict: `-v` now reports the
version; `--visibility` remains available. Added integration coverage for skipped
arguments, first-destination selection, and side-effect-free short versions.

## Version 1.8a option review

Removed the em-dash version alias from all nine scripts and shell functions.
Version output accepts only `-v` and `--version`. Added regression coverage
confirming that an em-dash argument does not select version output.
