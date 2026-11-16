#!/bin/zsh
# Prepare GitHub repositories; source shell.zsh to change the caller's directory.
# Version: 1.6
# This script was generated using GitHub.
emulate -LR zsh
setopt pipefail typesetsilent
export GH_HOST=github.com
_r_main() {
  if (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    cat <<'HELP'
repo - Prepare GitHub repositories for local development.
Settings: ~/Repo/rep.conf (created automatically when missing).

Usage: repo [NAME ...]

Examples:
  repo                 Prompt for a repository name.
  repo alpha beta      Prepare both; enter alpha via shell integration.

Arguments:
  NAME ...             Repository names; prompt if omitted or invalid.

Options:
  -h, --help           Show this help.

Exit status:
  0                    Success (including help).
  nonzero              Failure or cancellation.
HELP
    return 0
  fi
  _r_load_config || return $?
  [[ $1 == -- ]] && shift
  local root=${R_PROJECTS:-${_r_cfg[PROJECTS_DIR]}} owner name first='' failed=0 i=0
  local -a names
  (( $# )) || set -- ''
  for name in "$@"; do
    while [[ ! $name =~ '^[A-Za-z0-9_.-]{1,100}$' || $name == . || $name == .. || ${(L)name} == *.git ]]; do
      [[ -n $name ]] && print -ru2 -- "Invalid repository name: ${(qq)name}"
      print -nu2 -- 'Repository name: '
      IFS= read -r name || { print -ru2 'Input ended.'; return 1; }
    done
    names+=("$name")
  done
  (( $+commands[git] && $+commands[gh] )) || { print -ru2 'Missing dependency: git or gh'; return 1; }
  gh auth status --hostname github.com >&2 || return 1
  owner=$(gh api user --jq .login) || return 1
  mkdir -p -- "$root" || return 1
  root=${root:A}
  for name in "${names[@]}"; do
    (( i++ ))
    local result
    if result=$(_r_prepare "$root" "$owner" "$name"); then
      (( i == 1 )) && first=$result
    else
      # A dirty worktree still returns its validated destination for shell cd.
      (( i == 1 )) && [[ -n $result ]] && first=$result
      print -ru2 -- "Error [$name]: repository preparation failed."
      failed=1
    fi
  done
  [[ -n $first ]] && print -r -- "$first"
  return $failed
}
_r_load_config() {
  local manager="${R_HOME:-$HOME/Repo}/conf.zsh" settings key val
  [[ -f $manager ]] || { print -ru2 -- "Missing configuration manager: $manager. Run install.zsh."; return 1; }
  settings=$(zsh "$manager" --env) || return $?
  typeset -gA _r_cfg
  _r_cfg=()
  while IFS='=' read -r key val; do
    [[ -n $key ]] && _r_cfg[$key]=$val
  done <<< "$settings"
}
_r_git() { command git -C "$1" "${@:2}"; }
_r_isroot() {
  local top
  top=$(_r_git "$1" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ ${top:A} == ${1:A} ]]
}
_r_id() {
  local url=$1
  case $url in
    https://github.com/*|http://github.com/*) url=${url#*://github.com/} ;;
    ssh://git@github.com/*) url=${url#ssh://git@github.com/} ;;
    git@github.com:*) url=${url#git@github.com:} ;;
    *) return 1 ;;
  esac
  url=${url%/}; url=${url%.git}
  print -r -- "${(L)url}"
}
_r_web() {
  [[ ${_r_cfg[OPEN_WEB]} == true ]] || return 0
  local helper="${R_HOME:-$HOME/Repo}/term.zsh" terminal_app=${R_RETURN_APP:-} web_status=0 restore=0
  if [[ ${_r_cfg[RETURN_TERMINAL]} == true && ${R_DEFER_FOCUS:-0} != 1 ]]; then
    restore=1
    if [[ -z $terminal_app ]]; then
      terminal_app=$(zsh "$helper" capture) || terminal_app=''
    fi
  fi
  gh repo view "$@" --web >&2 || web_status=$?
  if (( restore )); then
    if [[ -n $terminal_app ]]; then
      zsh "$helper" restore "$terminal_app" "${R_CALLER_TTY:-${TTY:-}}" "${R_FOCUS_DEBUG:-${_r_cfg[FOCUS_DEBUG]}}" || _r_focus_failed=1
    else
      print -ru2 'Could not identify the invoking terminal; focus return was not attempted.'
      _r_focus_failed=1
    fi
  fi
  return $web_status
}
_r_validate_remotes() {
  local repo_dir=$1 full=$2 remote field urls url config_code
  for remote in "${(@f)$(_r_git "$repo_dir" remote)}"; do
    [[ -n $remote ]] || continue
    for field in url pushurl; do
      urls=$(_r_git "$repo_dir" config --get-all "remote.$remote.$field")
      config_code=$?
      (( config_code == 1 )) && [[ $field == pushurl ]] && continue
      (( config_code == 0 )) || { print -ru2 -- "Cannot read remote $field for $remote: $repo_dir"; return 1; }
      for url in "${(@f)urls}"; do
        [[ $(_r_id "$url") == ${(L)full} ]] || { print -ru2 -- "Conflicting remote $field for $remote: $repo_dir"; return 1; }
      done
    done
  done
  return 0
}
_r_prepare() {
  local root=$1 name=$3 full="$2/$3" dest="$1/$3" remote=origin new=0 lookup
  local candidate r url branch target dirty ahead _r_focus_failed=0
  local -a paths remotes
  lookup=$(gh api "repos/$full" --jq .full_name 2>&1)
  if (( $? )); then
    [[ $lookup == *'(HTTP 404)'* ]] || { print -ru2 -- "$lookup"; return 1; }
    new=1
  else
    full=$lookup
  fi
  paths=("$PWD")
  if [[ ${_r_cfg[USE_GHQ]} == true ]] && (( $+commands[ghq] )); then
    lookup=$(ghq list --full-path) || return 1
    paths+=("${(@f)lookup}")
  fi
  # Include linked worktrees; do not descend into Git metadata or dependency trees.
  while IFS= read -r -d '' candidate; do
    paths+=("${candidate:h}")
  done < <(find "$root" \( -name .git -print0 -prune \) -o \( -name node_modules -prune \))
  for candidate in "$dest" "${paths[@]}"; do
    [[ -d $candidate ]] && _r_isroot "$candidate" || continue
    remotes=("${(@f)$(_r_git "$candidate" remote)}")
    for r in "${remotes[@]}"; do
      [[ -n $r ]] || continue
      url=$(_r_git "$candidate" config --get "remote.$r.url") || return 1
      if [[ $(_r_id "$url") == ${(L)full} ]]; then
        dest=$candidate; remote=$r; break 2
      fi
    done
  done
  [[ ! -L $dest ]] || { print -ru2 -- "Symbolic-link destination: $dest"; return 1; }
  if [[ -e $dest ]]; then
    [[ -d $dest ]] || return 1
    if _r_isroot "$dest"; then
      _r_validate_remotes "$dest" "$full" || return 1
    else
      if _r_git "$dest" rev-parse --show-toplevel &>/dev/null; then
        print -ru2 -- "Destination is inside another repository: $dest"; return 1
      fi
      if (( ! new )) && [[ -n $(command ls -A -- "$dest") ]]; then
        print -ru2 -- "Nonempty unlinked directory: $dest"; return 1
      fi
    fi
  fi
  if (( new )); then
    gh repo create "$full" "--${_r_cfg[VISIBILITY]}" >&2 || return 1
  fi
  _r_web "$full" || print -ru2 -- "Open https://github.com/$full"
  if [[ ! -e $dest ]] || { ! _r_isroot "$dest" && [[ -z $(command ls -A -- "$dest") ]]; }; then
    gh repo clone "$full" "$dest" >&2 || return 1
  else
    if ! _r_isroot "$dest"; then
      _r_git "$dest" init -b "${_r_cfg[DEFAULT_BRANCH]}" >&2 || return 1
    fi
    if ! _r_git "$dest" config --get "remote.$remote.url" &>/dev/null; then
      _r_git "$dest" remote add "$remote" "https://github.com/$full.git" || return 1
    fi
    if (( new )) && [[ ${_r_cfg[IMPORT_EXISTING]} == true ]]; then
      _r_git "$dest" add --all || return 1
      _r_git "$dest" diff --cached --quiet
      local diff_status=$?
      if (( diff_status == 1 )); then
        _r_git "$dest" commit -m "${_r_cfg[COMMIT_MESSAGE]}" >&2 || return 1
      elif (( diff_status != 0 )); then
        return 1
      fi
      if _r_git "$dest" rev-parse --verify HEAD &>/dev/null; then
        _r_git "$dest" push --set-upstream "$remote" HEAD >&2 || return 1
      fi
    elif (( ! new )) && [[ ${_r_cfg[SYNC_EXISTING]} == true ]]; then
      dirty=$(_r_git "$dest" status --porcelain) || return 1
      if [[ -n $dirty ]]; then
        print -ru2 -- "Working tree has changes; synchronization skipped: $dest"
        print -r -- "${dest:A}"
        return 1
      fi
      _r_git "$dest" fetch "$remote" --prune >&2 || return 1
      branch=$(_r_git "$dest" symbolic-ref --quiet --short HEAD) || return 1
      lookup=$(_r_git "$dest" for-each-ref '--format=%(refname)' "refs/remotes/$remote/") || return 1
      if [[ -n $lookup ]]; then
        target="refs/remotes/$remote/$branch"
        _r_git "$dest" show-ref --verify --quiet "$target" || { print -ru2 -- "No matching remote branch: $branch"; return 1; }
        if _r_git "$dest" rev-parse --verify HEAD &>/dev/null; then
          _r_git "$dest" merge --ff-only "$target" >&2 || return 1
        else
          _r_git "$dest" checkout -B "$branch" "$target" >&2 || return 1
        fi
        _r_git "$dest" branch "--set-upstream-to=$remote/$branch" "$branch" >&2 || return 1
        ahead=$(_r_git "$dest" rev-list --count "$target..HEAD") || return 1
        (( ahead )) && print -ru2 -- "Local commits ahead ($ahead); push manually: $dest"
      fi
    fi
  fi
  print -ru2 -- "Ready: $dest"
  print -r -- "${dest:A}"
  return $_r_focus_failed
}
_r_main "$@"
