# Source this file from ~/Projects/dotfiles/.zshrc.
# R_HOME may override the directory containing the scripts.
# R_ENGINE selects zsh (default), perl, or python.
# Child processes cannot change the parent shell's current directory.
typeset -g R_HOME=${R_HOME:-${${(%):-%N}:A:h}}
_r_call() {
  emulate -L zsh
  local destination rc=0
  local -a command_line
  case ${R_ENGINE:-zsh} in
    zsh) command_line=(zsh "$R_HOME/repo.zsh") ;;
    perl) command_line=(perl "$R_HOME/repo.pl") ;;
    python) command_line=(python3 "$R_HOME/repo.py") ;;
    *) print -ru2 'R_ENGINE must be zsh, perl, or python.'; return 2 ;;
  esac
  if (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    "${command_line[@]}" "$@"
    return $?
  fi
  destination=$("${command_line[@]}" "$@") || rc=$?
  # Still enter the first repository when a later repository fails.
  if [[ -n $destination && -d $destination ]]; then
    builtin cd -- "$destination" || return $?
  fi
  return $rc
}
repo() { _r_call "$@"; }
rz() { local R_ENGINE=zsh; _r_call "$@"; }
rp() { local R_ENGINE=perl; _r_call "$@"; }
ry() { local R_ENGINE=python; _r_call "$@"; }
rf() {
  emulate -L zsh
  setopt localoptions pipefail
  (( $+commands[ghq] && $+commands[fzf] )) || {
    print -ru2 'Missing dependency: ghq or fzf'; return 1
  }
  local -a repositories
  local root=${R_PROJECTS:-$HOME/Projects} marker selected listed
  listed=$(ghq list --full-path) || return 1
  [[ -n $listed ]] && repositories+=("${(@f)listed}")
  # Flat ~/Projects repositories are outside ghq's usual host/owner/repo layout.
  # Add them explicitly while retaining repositories reported by ghq.
  if [[ -d $root ]]; then
    while IFS= read -r -d '' marker; do
      repositories+=("${marker:h}")
    done < <(find "$root" \( -name .git -print0 -prune \) -o \( -name node_modules -prune \))
  fi
  (( ${#repositories} )) || { print -ru2 'No local repositories found.'; return 1; }
  selected=$(printf '%s\0' "${(@u)repositories}" | fzf --read0 --print0 --prompt='Repository> ' | tr -d '\0') || return $?
  [[ -n $selected ]] && builtin cd -- "$selected"
}
