#!/bin/zsh
# Version: 1.8b
REPO_SCRIPT_VERSION=1.8b
if (( ${argv[(Ie)-v]} || ${argv[(Ie)--version]} )); then
  print -r -- "repo_term.zsh $REPO_SCRIPT_VERSION"
  exit 0
fi
# Shared terminal activation and verification; called through ~/Repo/repo_term.zsh.
emulate -LR zsh
setopt typesetsilent
REPO_SHELL_VERSION=1.8b

_term_capture() {
  emulate -L zsh
  (( $+commands[osascript] )) || return 1
  local capture_script='POSIX path of (path to frontmost application)'
  case ${TERM_PROGRAM:-} in
    Apple_Terminal) capture_script='POSIX path of (path to application id "com.apple.Terminal")' ;;
    iTerm.app) capture_script='POSIX path of (path to application id "com.googlecode.iterm2")' ;;
  esac
  osascript -e "$capture_script" 2>/dev/null
}

_term_restore() {
  emulate -L zsh
  local focus_script focus_result debug=${3:-false}
  focus_script=$(cat <<'APPLESCRIPT'
on run argv
    set terminalPath to item 1 of argv
    set callerTTY to item 2 of argv
    set terminalID to id of application terminalPath
    delay 0.8
    set stableChecks to 0
    set windowKind to "ACTIVE_ONLY"
    set windowDetail to ""
    repeat 8 times
        set windowKind to "ACTIVE_ONLY"
        set windowDetail to ""
        tell application terminalPath to activate
        if terminalID is "com.apple.Terminal" then
            try
                tell application "Terminal"
                    set targetWindow to missing value
                    set targetTab to missing value
                    if callerTTY is not "" then
                        -- Resolve numeric IDs, not references into "every window".
                        -- Keep lookup errors separate from the front-window fallback.
                        try
                            set windowIDs to get id of every window
                            repeat with candidateID in windowIDs
                                set windowIDValue to contents of candidateID
                                try
                                    set tabCount to count of tabs of window id windowIDValue
                                    repeat with tabIndex from 1 to tabCount
                                        set tabTTY to get tty of tab tabIndex of window id windowIDValue
                                        if tabTTY is callerTTY then
                                            set matchedWindow to get window id windowIDValue
                                            set matchedTab to get tab tabIndex of window id windowIDValue
                                            set targetWindow to matchedWindow
                                            set targetTab to matchedTab
                                            exit repeat
                                        end if
                                    end repeat
                                on error lookupMessage number lookupNumber
                                    -- A window or tab can disappear during enumeration.
                                    set windowDetail to lookupMessage & " (" & lookupNumber & ")"
                                end try
                                if targetWindow is not missing value then exit repeat
                            end repeat
                        on error lookupMessage number lookupNumber
                            set windowDetail to lookupMessage & " (" & lookupNumber & ")"
                        end try
                    end if
                    -- script/tmux can use a different TTY from Terminal's tab.
                    if targetWindow is missing value then
                        if exists front window then
                            set targetWindow to get front window
                        end if
                    end if
                    if targetWindow is not missing value then
                        if targetTab is not missing value then set selected of targetTab to true
                        set miniaturized of targetWindow to false
                        set index of targetWindow to 1
                        activate
                        if (miniaturized of targetWindow is false) and ((id of front window) is (id of targetWindow)) then
                            if targetTab is missing value then
                                set windowKind to "FRONT"
                            else
                                set windowKind to "TTY"
                            end if
                        end if
                    end if
                end tell
            on error messageText number errorNumber
                set windowDetail to messageText & " (" & errorNumber & ")"
            end try
        else
            try
                tell application "System Events"
                    set terminalProcess to first application process whose bundle identifier is terminalID
                    tell terminalProcess
                        set frontmost to true
                        if exists window 1 then
                            tell window 1
                                if value of attribute "AXMinimized" then set value of attribute "AXMinimized" to false
                                perform action "AXRaise"
                            end tell
                            set windowKind to "FRONT"
                        end if
                    end tell
                end tell
            on error messageText number errorNumber
                set windowDetail to messageText & " (" & errorNumber & ")"
            end try
        end if
        delay 0.4
        -- Use the application's native property, not the System Events process list.
        tell application terminalPath to set appIsFrontmost to frontmost
        if appIsFrontmost then
            set stableChecks to stableChecks + 1
            if stableChecks >= 3 then
                if windowKind is "ACTIVE_ONLY" and windowDetail is not "" then log windowDetail
                return windowKind
            end if
        else
            set stableChecks to 0
        end if
    end repeat
    error "Terminal activation could not be confirmed for " & terminalID & " (TTY: " & callerTTY & ", window result: " & windowKind & "). " & windowDetail
end run
APPLESCRIPT
)
  if focus_result=$(osascript -e "$focus_script" "$1" "${2:-}"); then
    case $focus_result in
      TTY)
        if [[ $debug == 1 || $debug == true ]]; then
          print -ru2 -- "Terminal restored to the original TTY (Repo $REPO_SHELL_VERSION)."
        fi
        ;;
      FRONT)
        if [[ $debug == 1 || $debug == true ]]; then
          print -ru2 -- "Terminal restored using its front window; exact TTY was not matched (Repo $REPO_SHELL_VERSION)."
        fi
        ;;
      ACTIVE_ONLY)
        print -ru2 -- "Warning: Terminal is active, but its window visibility could not be verified (Repo $REPO_SHELL_VERSION)."
        ;;
      *)
        print -ru2 -- "Unexpected terminal verification result (Repo $REPO_SHELL_VERSION): $focus_result"
        return 1
        ;;
    esac
    return 0
  else
    print -ru2 -- "Could not verify terminal activation; the window may already be visible (Repo $REPO_SHELL_VERSION)."
    [[ -n $focus_result ]] && print -ru2 -- "$focus_result"
    return 1
  fi
}

case ${1:-} in
  -h|--help|—help)
    print 'term - Shared macOS terminal helper for Repo.'
    print 'Usage: repo_term.zsh capture | restore APP_PATH TTY [true|false|1|0]'
    print 'Options: -h, --help, -v, --version'
    print 'Exit status: 0 success; 1 unavailable/unverified; 2 invalid arguments.'
    exit 0 ;;
  capture)
    (( $# == 1 )) || { print -ru2 'capture takes no arguments.'; exit 2; }
    _term_capture ;;
  restore)
    shift
    (( $# >= 2 && $# <= 3 )) || { print -ru2 'restore requires APP_PATH and TTY.'; exit 2; }
    [[ $1 == /* ]] || { print -ru2 'APP_PATH must be absolute.'; exit 2; }
    [[ ${3:-false} == true || ${3:-false} == false || ${3:-false} == 1 || ${3:-false} == 0 ]] || { print -ru2 'DEBUG must be true, false, 1, or 0.'; exit 2; }
    (( $+commands[osascript] )) || { print -ru2 'macOS osascript is unavailable.'; exit 1; }
    _term_restore "$@" ;;
  *) print -ru2 'Usage: repo_term.zsh capture | restore APP_PATH TTY [DEBUG]'; exit 2 ;;
esac
