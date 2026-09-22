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
"name / branch", and open the selection in a new Zed window.

  --list         Print the sorted list and exit
  project-path   Current project. Defaults to $ZED_WORKTREE_ROOT, then the
                 working directory.

Set ZED_PROJECT_SWITCHER_DIRECTORY to scan a folder other than the project's parent.
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

names=()
proj_paths=()
git_dirs=()

shopt -s nullglob
for path in "$projects_dir"/*; do
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

if [[ ${#names[@]} -eq 0 ]]; then
  echo "zed-project-switcher: no project directories in $projects_dir" >&2
  exit 1
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

sorted=()
while IFS= read -r row; do
  sorted+=("$row")
done < <(printf '%s\n' "${rows[@]}" | sort -t $'\t' -k1,1nr -k2,2)

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
    --margin '16%,20%' \
    --border rounded \
    --border-label ' Switch Project ' \
    --padding '1,2' \
    --delimiter $'\t' \
    --nth 1 \
    --with-nth 1 \
    --no-bold \
    --color "$palenight_colors"
) || exit 0

[[ -n "$selected" ]] || exit 0
selected_path=${selected#*$'\t'}

zed_bin=${ZED_PROJECT_SWITCHER_ZED:-}
if [[ -z "$zed_bin" ]]; then
  if command -v zed >/dev/null 2>&1; then
    zed_bin=$(command -v zed)
  elif [[ -x /Applications/Zed.app/Contents/MacOS/cli ]]; then
    zed_bin=/Applications/Zed.app/Contents/MacOS/cli
  elif [[ -x "$HOME/Applications/Zed.app/Contents/MacOS/cli" ]]; then
    zed_bin="$HOME/Applications/Zed.app/Contents/MacOS/cli"
  else
    echo 'zed-project-switcher: could not find the zed CLI. In Zed, run "zed: install cli".' >&2
    exit 1
  fi
fi

"$zed_bin" -n "$selected_path"
