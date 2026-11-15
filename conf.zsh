#!/bin/zsh
# Parse literal configuration data. Never source or evaluate rep.conf.
emulate -LR zsh
setopt pipefail typesetsilent

_conf_main() {
  if (( ${argv[(Ie)-h]} || ${argv[(Ie)--help]} || ${argv[(Ie)—help]} )); then
    cat <<'HELP'
conf - Configure Repo and create its local project directory.
Usage: conf.zsh [KEY=VALUE ...] [options]
Arguments:
  KEY=VALUE             Update a setting; retain other saved/default values.
Options:
  -d, --dir PATH        Local repository root.
  -v, --visibility MODE New remote visibility: private or public.
  --show                Show effective settings.
  --check               Validate only; create no files or directories.
  --reset               Start from defaults instead of saved settings.
  -h, --help            Show this help.
Examples:
  conf.zsh
  conf.zsh --dir "$HOME/Work" --visibility private
  conf.zsh OPEN_WEB=false ENGINE=python --show
Exit status:
  0 Success or help.  1 File/lock error.  2 Invalid argument or setting.
HELP
    return 0
  fi
  local real="$HOME/Projects/Repo/rep.conf" link="${R_HOME:-$HOME/Repo}/rep.conf"
  local mode=save reset=0 arg key val line target checked_branch cfg_source
  local tmp='' created=0 lock_dir="$HOME/.repo-locks" lock_file lock_fd
  local -a keys=(PROJECTS_DIR VISIBILITY ENGINE OPEN_WEB RETURN_TERMINAL FOCUS_DEBUG SYNC_EXISTING IMPORT_EXISTING USE_GHQ COMMIT_MESSAGE DEFAULT_BRANCH)
  local -A cfg updates seen
  cfg=(PROJECTS_DIR "${R_PROJECTS:-$HOME/Projects}" VISIBILITY private
       ENGINE "${R_ENGINE:-zsh}" OPEN_WEB true RETURN_TERMINAL true FOCUS_DEBUG false
       SYNC_EXISTING true IMPORT_EXISTING true USE_GHQ true
       COMMIT_MESSAGE 'Import existing files' DEFAULT_BRANCH main)
  [[ ${R_FOCUS_DEBUG:-0} == 1 ]] && cfg[FOCUS_DEBUG]=true
  while (( $# )); do
    arg=$1; shift
    case $arg in
      --env|--show|--check)
        val=${arg#--}
        [[ $mode == save || $mode == $val ]] || { print -ru2 'Choose only one of --show, --check, and --env.'; return 2; }
        mode=$val ;;
      --reset) reset=1 ;;
      -d|--dir|-v|--visibility)
        (( $# )) || { print -ru2 -- "Missing value for $arg"; return 2; }
        key=PROJECTS_DIR; [[ $arg == -v || $arg == --visibility ]] && key=VISIBILITY
        updates[$key]=$1; shift ;;
      *=*)
        key=${arg%%=*}
        (( ${keys[(Ie)$key]} )) || { print -ru2 -- "Unknown setting: $key"; return 2; }
        updates[$key]=${arg#*=} ;;
      *) print -ru2 -- "Unknown argument: $arg"; return 2 ;;
    esac
  done
  (( $+commands[git] )) || { print -ru2 'Missing dependency: git'; return 1; }
  # Lock a separate stable file: atomic config replacement must not change the lock.
  # The OS releases this advisory lock even if the process is interrupted.
  if [[ $mode != check ]]; then
    [[ ! -L $lock_dir ]] || { print -ru2 -- "Unexpected lock directory link: $lock_dir"; return 1; }
    (umask 077; mkdir -p -- "$lock_dir") || return 1
    lock_file="$lock_dir/conf.lock"
    [[ ! -L $lock_file && ( ! -e $lock_file || -f $lock_file ) ]] || { print -ru2 -- "Invalid lock file: $lock_file"; return 1; }
    if [[ ! -e $lock_file ]]; then
      (umask 077; setopt noclobber; : > "$lock_file") 2>/dev/null || [[ -f $lock_file && ! -L $lock_file ]] || return 1
    fi
    zmodload zsh/system || { print -ru2 'Missing zsh/system locking module.'; return 1; }
    zsystem flock -t 10 -f lock_fd "$lock_file" || { print -ru2 'Configuration is busy; retry after the other command finishes.'; return 1; }
  fi
  [[ ! -L $real ]] || { print -ru2 -- "Physical configuration must not be a symbolic link: $real"; return 1; }
  [[ ! -e $real || -f $real ]] || { print -ru2 -- "Config is not a regular file: $real"; return 1; }
  real="${real:h:A}/${real:t}"
  if [[ -L $link ]]; then
    target=$(readlink "$link") || return 1
    [[ $target == /* ]] || target="${link:h}/$target"
    target=${target:a}; target="${target:h:A}/${target:t}"
    [[ $target == $real ]] || { print -ru2 -- "Unexpected config link: $link -> $target"; return 1; }
  elif [[ ${link:h:A} != ${real:h:A} && -e $link ]]; then
    print -ru2 -- "Config must be a symbolic link: $link"; return 1
  fi
  if [[ $mode != check ]]; then
    mkdir -p -- "${real:h}" "${link:h}" || return 1
    if [[ ${link:h:A} != ${real:h:A} && ! -L $link ]]; then
      ln -s -- "$real" "$link" || return 1
    fi
  fi
  cfg_source=$link
  # Preflight validation may inspect the real file before a link has been installed.
  [[ $mode == check && ! -e $link ]] && cfg_source=$real
  if [[ -f $real && $reset == 0 ]]; then
    [[ -r $cfg_source ]] || { print -ru2 -- "Cannot read configuration: $cfg_source"; return 1; }
    (( $+commands[iconv] )) || { print -ru2 'Missing UTF-8 validator: iconv'; return 1; }
    iconv -f UTF-8 -t UTF-8 "$cfg_source" >/dev/null 2>&1 || { print -ru2 'Configuration must be valid UTF-8 text.'; return 2; }
    while IFS= read -r line || [[ -n $line ]]; do
      line=${line%$'\r'}
      [[ -z ${line//[[:space:]]/} || $line == \#* ]] && continue
      [[ $line == *=* ]] || { print -ru2 -- "Invalid config line: $line"; return 2; }
      key=${line%%=*}; val=${line#*=}
      (( ${keys[(Ie)$key]} )) || { print -ru2 -- "Unknown setting: $key"; return 2; }
      [[ -z ${seen[$key]-} ]] || { print -ru2 -- "Duplicate setting: $key"; return 2; }
      seen[$key]=1; cfg[$key]=$val
    done < "$cfg_source" || return 1
  fi
  for key in "${(@k)updates}"; do cfg[$key]=${updates[$key]}; done
  for key in "${keys[@]}"; do
    val=${cfg[$key]}
    [[ $val != *[[:cntrl:]]* ]] || { print -ru2 -- "Control character in $key"; return 2; }
    case $key in
      PROJECTS_DIR)
        [[ $val == '~' ]] && val=$HOME
        [[ $val == '~/'* ]] && val="$HOME/${val#\~/}"
        [[ $val == /* && -n $val ]] || { print -ru2 'PROJECTS_DIR must be absolute or start with ~/.'; return 2; }
        cfg[$key]=${val:a} ;;
      VISIBILITY) [[ $val == private || $val == public ]] || { print -ru2 'VISIBILITY must be private or public.'; return 2; } ;;
      ENGINE) [[ $val == zsh || $val == perl || $val == python ]] || { print -ru2 'ENGINE must be zsh, perl, or python.'; return 2; } ;;
      OPEN_WEB|RETURN_TERMINAL|FOCUS_DEBUG|SYNC_EXISTING|IMPORT_EXISTING|USE_GHQ)
        [[ $val == true || $val == false ]] || { print -ru2 -- "$key must be true or false."; return 2; } ;;
      COMMIT_MESSAGE) [[ -n $val ]] || { print -ru2 'COMMIT_MESSAGE must not be empty.'; return 2; } ;;
      DEFAULT_BRANCH)
        checked_branch=$(git check-ref-format --branch "$val" 2>/dev/null) || { print -ru2 'DEFAULT_BRANCH is not a valid Git branch name.'; return 2; }
        [[ $checked_branch == $val ]] || { print -ru2 'DEFAULT_BRANCH must be a literal branch name.'; return 2; } ;;
    esac
  done
  [[ $mode == check ]] && return 0
  mkdir -p -- "${cfg[PROJECTS_DIR]}" || { print -ru2 -- "Cannot create project directory: ${cfg[PROJECTS_DIR]}"; return 1; }
  {
    if [[ $mode == save || ! -f $real || $reset == 1 || ${#updates} -gt 0 ]]; then
      tmp=$(mktemp "${real:h}/.rep.conf.XXXXXXXX") || return 1
      {
        print -r -- '# Repo configuration. Literal KEY=VALUE data; no shell evaluation.'
        for key in "${keys[@]}"; do print -r -- "$key=${cfg[$key]}"; done
      } > "$tmp" || return 1
      chmod 600 "$tmp" || return 1
      if [[ ! -f $real ]] || ! cmp -s "$tmp" "$real"; then
        [[ -f $real ]] || created=1
        mv -f -- "$tmp" "$real" || return 1
      fi
    fi
  } always {
    if [[ -n $tmp && -f $tmp ]]; then command rm -f -- "$tmp"; fi
  }
  if [[ $mode == env || $mode == show ]]; then
    for key in "${keys[@]}"; do print -r -- "$key=${cfg[$key]}"; done
  else
    print -r -- "Saved configuration: $link"
    print -r -- "Local repository root: ${cfg[PROJECTS_DIR]}"
  fi
  (( created )) && print -ru2 -- "Created default configuration: $real"
  return 0
}
_conf_main "$@"
