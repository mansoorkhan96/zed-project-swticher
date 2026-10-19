#!/usr/bin/env bash
# Same picker as the Go program, for a speed comparison.
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:${PATH:-}"

palenight_colors='dark,bg:#292D3E,fg:#BFC7D5,hl:#C792EA,fg+:#ffffff,bg+:#7e57c2,hl+:#FFCB6B,gutter:#292D3E,info:#929ac9,prompt:#82AAFF,pointer:#C792EA,marker:#C792EA,query:#ffffff,border:#676E95,separator:#676E95,label:#BFC7D5'
git_icon=$(printf '\xee\x82\xa0')

usage() {
  cat <<'EOF'
Usage: zed-project-switcher.sh [--list] [project-path]

Scan the parent of project-path for directories, show each one as
"name / branch", and open the selection in Zed.

  --list         Print the sorted list and exit
  project-path   Current project. Defaults to $ZED_WORKTREE_ROOT, then the
                 working directory.

Set ZED_PROJECT_SWITCHER_DIRECTORY to scan a folder other than the project's parent.

In the picker, a query that starts with ~/, /, ./ or ../ lists that folder
instead, with ./ and ../ relative to the scanned folder. ~/code/web lists
~/code and filters it by "web".
EOF
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_dir() {
  [[ -d "$1" ]]
}

# Fill sorted with "mtime<TAB>label<TAB>path" rows for the directories in
# $1, most recently updated first.
scan_projects() {
  local projects_dir=$1
  names=()
  proj_paths=()
  git_dirs=()

  for path in "${projects_dir%/}"/*; do
    [[ -d "$path" ]] || continue
    name=${path##*/}
    [[ "$name" == .* ]] && continue

    git_path="$path/.git"
    git_dir=""
    if [[ -f "$git_path" && ! -L "$git_path" ]]; then
      line=""
      IFS= read -r line < "$git_path" || true
      line=$(trim "$line")
      if [[ "$line" =~ ^gitdir:[[:space:]]*(.+)$ ]]; then
        target=$(trim "${BASH_REMATCH[1]}")
        if [[ "$target" != /* ]]; then
          target="$path/$target"
        fi
        if [[ -d "$target" ]]; then
          git_dir=$target
        fi
      fi
    elif [[ -d "$git_path" ]]; then
      git_dir=$git_path
    fi

    names+=("$name")
    proj_paths+=("$path")
    git_dirs+=("$git_dir")
  done

  sorted=()
  if [[ ${#names[@]} -eq 0 ]]; then
    return 0
  fi

  stat_files=()
  stat_counts=()
  for git_dir in "${git_dirs[@]}"; do
    count=0
    if [[ -n "$git_dir" ]]; then
      if [[ -e "$git_dir/HEAD" ]]; then
        stat_files+=("$git_dir/HEAD")
        count=$((count + 1))
      fi
      if [[ -e "$git_dir/index" ]]; then
        stat_files+=("$git_dir/index")
        count=$((count + 1))
      fi
    fi
    stat_counts+=("$count")
  done

  mtimes=()
  if [[ ${#stat_files[@]} -gt 0 ]]; then
    while IFS= read -r stamp; do
      mtimes+=("$stamp")
    done < <(stat -f '%m' "${stat_files[@]}")
  fi

  rows=()
  stamp_index=0
  for i in "${!names[@]}"; do
    name=${names[$i]}
    path=${proj_paths[$i]}
    git_dir=${git_dirs[$i]}
    branch=""
    newest=0
    count=${stat_counts[$i]}
    taken=0
    while [[ $taken -lt $count ]]; do
      stamp=${mtimes[$stamp_index]}
      stamp_index=$((stamp_index + 1))
      taken=$((taken + 1))
      if [[ $stamp -gt $newest ]]; then
        newest=$stamp
      fi
    done

    if [[ -n "$git_dir" && -f "$git_dir/HEAD" ]]; then
      head=""
      IFS= read -r head < "$git_dir/HEAD" || true
      head=$(trim "$head")
      if [[ "$head" =~ ^ref:[[:space:]]*refs/heads/(.+)$ ]]; then
        branch=$(trim "${BASH_REMATCH[1]}")
      elif [[ "$head" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        branch=${head:0:7}
      fi
    fi

    if [[ $newest -eq 0 ]]; then
      newest=$(stat -f '%m' "$path")
    fi

    if [[ -n "$branch" ]]; then
      label="$name / $git_icon $branch"
    else
      label=$name
    fi
    rows+=("$newest"$'\t'"$label"$'\t'"$path")
  done

  while IFS= read -r row; do
    sorted+=("$row")
  done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr -k2,2)
}

# Pick the folder to list for an fzf query. A query that starts like a path
# lists the folder up to its last slash, with ./ and ../ taken relative to
# base, and its rows keep that typed folder as a prefix so fzf still matches
# the whole query. Any other query lists base. /bin/pwd -P spells the folder
# the way it is on disk (bash's builtin keeps the typed case), so a typed
# ~/code finds ~/Code and Zed gets the path it has in its database.
browse_target() {
  local base=$1 query=$2
  query=${query#"${query%%[! ]*}"}
  case "$query" in
    '~'|.|..) query+=/ ;;
  esac
  browse_dir=$base
  browse_prefix=""
  case "$query" in
    /*|'~/'*|./*|../*) ;;
    *) return 0 ;;
  esac

  browse_prefix=${query%/*}/
  case "$browse_prefix" in
    '~/'*) browse_dir="$HOME/${browse_prefix#'~/'}" ;;
    /*) browse_dir=$browse_prefix ;;
    *) browse_dir="$base/$browse_prefix" ;;
  esac
  browse_dir=$(cd "$browse_dir" 2>/dev/null && /bin/pwd -P) || browse_dir=""
}

shopt -s nullglob

# fzf reruns us on every keystroke to list the folder the query points at.
if [[ $# -eq 3 && "$1" == --feed ]]; then
  browse_target "$2" "$3"
  [[ -n "$browse_dir" ]] || exit 0
  scan_projects "$browse_dir"
  for row in ${sorted[@]+"${sorted[@]}"}; do
    printf '%s%s\n' "$browse_prefix" "${row#*$'\t'}"
  done
  exit 0
fi

list_only=0
project_arg=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --list)
      list_only=1
      shift
      ;;
    --)
      shift
      if [[ $# -gt 0 ]]; then
        if [[ -n "$project_arg" ]]; then
          echo "zed-project-switcher: unexpected argument: $1" >&2
          usage >&2
          exit 1
        fi
        project_arg="$1"
      fi
      break
      ;;
    -*)
      echo "zed-project-switcher: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -n "$project_arg" ]]; then
        echo "zed-project-switcher: unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      project_arg="$1"
      shift
      ;;
  esac
done

if [[ -z "$project_arg" ]]; then
  project_arg="${ZED_WORKTREE_ROOT:-$PWD}"
fi

if [[ ! -d "$project_arg" ]]; then
  echo "zed-project-switcher: not a directory: $project_arg" >&2
  exit 1
fi

current=$(cd "$project_arg" && pwd -P)
if [[ -n "${ZED_PROJECT_SWITCHER_DIRECTORY:-}" ]]; then
  if [[ ! -d "$ZED_PROJECT_SWITCHER_DIRECTORY" ]]; then
    echo "zed-project-switcher: ZED_PROJECT_SWITCHER_DIRECTORY is not a directory: $ZED_PROJECT_SWITCHER_DIRECTORY" >&2
    exit 1
  fi
  projects_dir=$(cd "$ZED_PROJECT_SWITCHER_DIRECTORY" && pwd -P)
else
  projects_dir=$(dirname "$current")
fi

scan_projects "$projects_dir"
if [[ ${#sorted[@]} -eq 0 ]]; then
  echo "zed-project-switcher: no project directories in $projects_dir" >&2
  exit 1
fi


if [[ $list_only -eq 1 ]]; then
  for row in "${sorted[@]}"; do
    rest=${row#*$'\t'}
    printf '%s\n' "${rest%%$'\t'*}"
  done
  exit 0
fi

if ! command -v fzf >/dev/null 2>&1; then
  echo "zed-project-switcher: fzf is required. Install it with: brew install fzf" >&2
  exit 1
fi

self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/$(basename "${BASH_SOURCE[0]}")"
reload="$(printf '%q' "$self") --feed $(printf '%q' "$projects_dir") {q}"
title_dir=$projects_dir
if [[ "$title_dir" == "$HOME" || "$title_dir" == "$HOME"/* ]]; then
  title_dir="~${title_dir#"$HOME"}"
fi

feed=""
for row in "${sorted[@]}"; do
  rest=${row#*$'\t'}
  feed+="$rest"$'\n'
done

selected=$(
  printf '%s' "$feed" | env -u FZF_DEFAULT_OPTS fzf \
    --prompt '> ' \
    --no-sort \
    --reverse \
    --margin '16%,8%' \
    --border rounded \
    --border-label " Switch Project · $title_dir " \
    --padding '1,2' \
    --delimiter $'\t' \
    --nth 1 \
    --with-nth 1 \
    --no-bold \
    --color "$palenight_colors" \
    --bind "change:reload:$reload"
) || exit 0

[[ -n "$selected" ]] || exit 0
selected_path=${selected#*$'\t'}

# Open the project in the Zed that launched us. Zed sets the bundle ID of
# the app in every process it spawns, so a dev build gets its own CLI and
# its own workspace database.
case "${__CFBundleIdentifier:-}" in
  dev.zed.Zed-Dev)
    zed_app="Zed Dev.app"
    zed_channel=dev
    ;;
  dev.zed.Zed-Preview)
    zed_app="Zed Preview.app"
    zed_channel=preview
    ;;
  *)
    zed_app="Zed.app"
    zed_channel=stable
    ;;
esac

zed_bin=${ZED_PROJECT_SWITCHER_ZED:-}
if [[ -z "$zed_bin" ]]; then
  if [[ "$zed_channel" == stable ]] && command -v zed >/dev/null 2>&1; then
    zed_bin=$(command -v zed)
  elif [[ -x "/Applications/$zed_app/Contents/MacOS/cli" ]]; then
    zed_bin="/Applications/$zed_app/Contents/MacOS/cli"
  elif [[ -x "$HOME/Applications/$zed_app/Contents/MacOS/cli" ]]; then
    zed_bin="$HOME/Applications/$zed_app/Contents/MacOS/cli"
  else
    echo "zed-project-switcher: could not find the CLI for $zed_app. In Zed, run \"zed: install cli\"." >&2
    exit 1
  fi
fi

# Zed's new-window CLI mode never reuses a window for a project root, so
# focus the window ourselves when the project is already open.
is_open_in_zed() {
  local db="$HOME/Library/Application Support/Zed/db/0-$zed_channel/db.sqlite"
  command -v sqlite3 >/dev/null 2>&1 || return 1
  [[ -f "$db" ]] || return 1
  local q="'"
  local quoted="$q${1//$q/$q$q}$q"
  local found
  found=$(sqlite3 -readonly "$db" "SELECT 1 FROM workspaces w
JOIN kv_store s ON s.key = 'session_id' AND s.value = w.session_id
JOIN kv_store k ON k.key = 'session_window_stack'
WHERE w.paths = $quoted AND w.remote_connection_id IS NULL
AND EXISTS (SELECT 1 FROM json_each(k.value) WHERE json_each.value = w.window_id)
LIMIT 1;" 2>/dev/null) || return 1
  [[ "$found" == 1 ]]
}

open_flag=-n
if is_open_in_zed "$selected_path"; then
  open_flag=-e
fi
"$zed_bin" "$open_flag" "$selected_path"
