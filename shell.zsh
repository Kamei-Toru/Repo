# Repo shell integration. Runtime scripts are invoked through ~/Repo links.
# Version: 1.6
# Source this file from ~/.zshrc.
# This script was generated using GitHub
typeset -g REPO_SHELL_VERSION=1.6
typeset -g R_HOME=${R_HOME:-$HOME/Repo}
_repo_load_config() {
  emulate -L zsh
  local manager="$R_HOME/conf.zsh" settings key val
  [[ -f $manager ]] || { print -ru2 -- "Missing configuration manager: $manager. Run install.zsh."; return 1; }
  settings=$(R_HOME="$R_HOME" zsh "$manager" --env) || return $?
  typeset -gA REPO_CONFIG
  REPO_CONFIG=()
  while IFS='=' read -r key val; do
    [[ -n $key ]] && REPO_CONFIG[$key]=$val
  done <<< "$settings"
}
conf() { R_HOME="$R_HOME" zsh "$R_HOME/conf.zsh" "$@"; }
_repo_capture() {
  local helper="$R_HOME/term.zsh"
  [[ -f $helper ]] || { print -ru2 -- "Missing terminal helper: $helper. Run install.zsh."; return 1; }
  zsh "$helper" capture
}
_repo_restore() {
  local helper="$R_HOME/term.zsh" debug=${R_FOCUS_DEBUG:-${REPO_CONFIG[FOCUS_DEBUG]:-false}}
  [[ -f $helper ]] || { print -ru2 -- "Missing terminal helper: $helper. Run install.zsh."; return 1; }
  zsh "$helper" restore "$1" "${2:-}" "$debug"
}

_r_call() {
  emulate -L zsh
  local -x R_HOME=${R_HOME:-$HOME/Repo}
  local destination rc=0 focus_rc=0
  local -a command_line
  if [[ ${1:-} == --version ]]; then
    print -r -- "Repo shell $REPO_SHELL_VERSION"
    return 0
  fi
  if ! (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    _repo_load_config || return $?
  fi
  case ${R_ENGINE:-${REPO_CONFIG[ENGINE]:-zsh}} in
    zsh) command_line=(zsh "$R_HOME/repo.zsh") ;;
    perl) command_line=(perl "$R_HOME/repo.pl") ;;
    python) command_line=(python3 "$R_HOME/repo.py") ;;
    *) print -ru2 'R_ENGINE must be zsh, perl, or python.'; return 2 ;;
  esac
  if (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    "${command_line[@]}" "$@"
    return $?
  fi
  local -x R_RETURN_APP R_CALLER_TTY=${TTY:-} R_DEFER_FOCUS=1
  R_RETURN_APP=''
  if [[ ${REPO_CONFIG[OPEN_WEB]} == true && ${REPO_CONFIG[RETURN_TERMINAL]} == true ]]; then
    R_RETURN_APP=$(_repo_capture) || R_RETURN_APP=''
  fi
  destination=$("${command_line[@]}" "$@") || rc=$?
  if [[ -n $destination && -d $destination ]]; then
    builtin cd -- "$destination" || rc=$?
  fi
  # Restore the original terminal only after all Git work and the final cd.
  if [[ -n $R_RETURN_APP ]]; then
    _repo_restore "$R_RETURN_APP" "$R_CALLER_TTY" || focus_rc=$?
  elif [[ ${REPO_CONFIG[OPEN_WEB]} == true && ${REPO_CONFIG[RETURN_TERMINAL]} == true ]]; then
    print -ru2 'Could not identify the invoking terminal; focus return was not attempted.'
    focus_rc=1
  fi
  (( rc )) && return $rc
  return $focus_rc
}
repo() { _r_call "$@"; }
rz() { local R_ENGINE=zsh; _r_call "$@"; }
rp() { local R_ENGINE=perl; _r_call "$@"; }
ry() { local R_ENGINE=python; _r_call "$@"; }
rf() {
  emulate -L zsh
  local -x R_HOME=${R_HOME:-$HOME/Repo}
  setopt localoptions pipefail
  _repo_load_config || return $?
  (( $+commands[fzf] )) || { print -ru2 'Missing dependency: fzf'; return 1; }
  if [[ ${REPO_CONFIG[USE_GHQ]} == true ]]; then
    (( $+commands[ghq] )) || { print -ru2 'Missing dependency: ghq'; return 1; }
  fi
  if [[ ${REPO_CONFIG[OPEN_WEB]} == true ]]; then
    (( $+commands[gh] )) || { print -ru2 'Missing dependency: gh'; return 1; }
  fi
  local -a repositories
  local root=${R_PROJECTS:-${REPO_CONFIG[PROJECTS_DIR]}} marker selected listed
  if [[ ${REPO_CONFIG[USE_GHQ]} == true ]]; then
    listed=$(ghq list --full-path) || return 1
    [[ -n $listed ]] && repositories+=("${(@f)listed}")
  fi
  if [[ -d $root ]]; then
    while IFS= read -r -d '' marker; do
      repositories+=("${marker:h}")
    done < <(find "$root" \( -name .git -print0 -prune \) -o \( -name node_modules -prune \))
  fi
  (( ${#repositories} )) || { print -ru2 'No local repositories found.'; return 1; }
  selected=$(printf '%s\0' "${(@u)repositories}" | fzf --read0 --print0 --prompt='Repository> ' | tr -d '\0') || return $?
  [[ -n $selected ]] || return 1
  builtin cd -- "$selected" || return $?
  [[ ${REPO_CONFIG[OPEN_WEB]} == true ]] || return 0
  local terminal_app='' web_status=0 focus_status=0 caller_tty=${TTY:-}
  if [[ ${REPO_CONFIG[RETURN_TERMINAL]} == true ]]; then
    terminal_app=$(_repo_capture) || terminal_app=''
  fi
  gh repo view --web >&2 || web_status=$?
  if [[ ${REPO_CONFIG[RETURN_TERMINAL]} == true ]]; then
    if [[ -n $terminal_app ]]; then
      _repo_restore "$terminal_app" "$caller_tty" || focus_status=$?
    else
      print -ru2 'Could not identify the invoking terminal; focus return was not attempted.'
      focus_status=1
    fi
  fi
  (( web_status )) && return $web_status
  return $focus_status
}
