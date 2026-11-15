# Source review: 20261115.6

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
| Medium | Terminal code was duplicated across four files and direct runtimes handled failure differently | One `term.zsh` helper, shared result policy, and consistent nonzero focus-failure status | Quiet success, debug output, visibility warnings, failed activation, and available directory output |
| Low | Unknown installer options were ignored; conflicting config modes and malformed text were not fully rejected | Reject unknown options, conflicting modes, invalid UTF-8, control characters, and physical-config symlinks | Rejected inputs preserve configuration and cause no GitHub calls |

## Verification

The suite contains 25 isolated tests with additional per-runtime subtests. It
uses real local Git repositories and mocked GitHub, browser, and activation
commands. It checks defaults, directory creation, private/public remotes,
literal values, config recovery, both link layouts, startup-backup numbering,
concurrency, installer preflight/rollback, remote safety, dirty navigation, and
terminal results. It does not publish to GitHub or manipulate the desktop.

Run `python3 test_config.py` from this directory. `test_local.py` is a compatible
entry point for the same suite. zsh, Perl, and Python syntax checks also apply.

Actual focus switching across macOS Spaces remains a target-machine check.
The helper distinguishes activation from window visibility and does not claim
that application activation alone proves a visible desktop switch. Rollback
preserves externally modified files and reports them instead of overwriting
concurrent changes. Newly created valid configuration data is retained.
