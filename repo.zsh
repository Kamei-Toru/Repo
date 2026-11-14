#!/bin/zsh
# Prepare GitHub repositories; source shell.zsh to change the caller's directory.
emulate -LR zsh
setopt pipefail typesetsilent
export GH_HOST=github.com
_r_main() {
  if (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    cat <<'HELP'
Usage: repo.zsh [--] [NAME ...]
Prepare private GitHub repositories for the authenticated user.
Prompt for missing/invalid names; open each repository in the browser.
Reuse linked repositories under Projects, ghq roots, or the current directory.
Otherwise clone to ~/Projects/NAME. Import existing files into new remotes.
Existing remotes: fetch and fast-forward only with a clean working tree.
Use shell.zsh to change the caller's directory. R_PROJECTS overrides ~/Projects.
Names: 1-100 ASCII letters, digits, dots, underscores, hyphens; not ., .., or names ending in .git.
Dependencies: git, gh, zsh. Optional fuzzy navigation: ghq and fzf.
-h, --help  Show this help.
HELP
    return 0
  fi
  [[ $1 == -- ]] && shift
  local root=${R_PROJECTS:-$HOME/Projects} owner name first='' failed=0 i=0
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
      print -ru2 -- "Error [$name]: repository preparation failed."
      failed=1
    fi
  done
  [[ -n $first ]] && print -r -- "$first"
  return $failed
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
_r_prepare() {
  local root=$1 name=$3 full="$2/$3" dest="$1/$3" remote=origin new=0 lookup
  local candidate r url top branch target dirty ahead
  local -a paths remotes refs
  lookup=$(gh api "repos/$full" --jq .full_name 2>&1)
  if (( $? )); then
    [[ $lookup == *'(HTTP 404)'* ]] || { print -ru2 -- "$lookup"; return 1; }
    new=1
  else
    full=$lookup
  fi
  paths=("$PWD")
  if (( $+commands[ghq] )); then
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
      remotes=("${(@f)$(_r_git "$dest" remote)}")
      for r in "${remotes[@]}"; do
        [[ -n $r ]] || continue
        url=$(_r_git "$dest" config --get "remote.$r.url") || return 1
        [[ $(_r_id "$url") == ${(L)full} ]] || { print -ru2 -- "Conflicting remote $r: $url"; return 1; }
      done
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
    gh repo create "$full" --private >&2 || return 1
  fi
  gh repo view "$full" --web >&2 || print -ru2 -- "Open https://github.com/$full"
  if [[ ! -e $dest ]] || { ! _r_isroot "$dest" && [[ -z $(command ls -A -- "$dest") ]]; }; then
    gh repo clone "$full" "$dest" >&2 || return 1
  else
    if ! _r_isroot "$dest"; then
      _r_git "$dest" init -b main >&2 || return 1
    fi
    if ! _r_git "$dest" config --get "remote.$remote.url" &>/dev/null; then
      _r_git "$dest" remote add "$remote" "https://github.com/$full.git" || return 1
    fi
    if (( new )); then
      _r_git "$dest" add --all || return 1
      _r_git "$dest" diff --cached --quiet
      local diff_status=$?
      if (( diff_status == 1 )); then
        _r_git "$dest" commit -m 'Import existing files' >&2 || return 1
      elif (( diff_status != 0 )); then
        return 1
      fi
      if _r_git "$dest" rev-parse --verify HEAD &>/dev/null; then
        _r_git "$dest" push --set-upstream "$remote" HEAD >&2 || return 1
      fi
    else
      _r_git "$dest" fetch "$remote" --prune >&2 || return 1
      dirty=$(_r_git "$dest" status --porcelain) || return 1
      [[ -z $dirty ]] || { print -ru2 -- "Working tree has changes: $dest"; return 1; }
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
}
_r_main "$@"
