# Zed Project Switcher

A project picker for Zed. It lists every directory next to the project you have open, shows the current git branch, and opens the one you pick in a new window.

Press `cmd+;` and you get a searchable list like:

```
web-app / main
api-server / feature/login
docs-site / 2.x
```

Typing matches the directory name or the branch. The list starts out sorted by the most recently updated project. Choosing one runs `zed -n` on that folder.

Zed extensions cannot add a command palette action or a native file-finder modal, so this is a small command plus a Zed task. The picker is `fzf` in a centered terminal.

## Install

`fzf` is required:

```sh
brew install fzf
```

The script uses `zed` from your PATH when it is there. Otherwise it uses `/Applications/Zed.app/Contents/MacOS/cli`. To put `zed` on your PATH, open the command palette in Zed and run `zed: install cli`.

### 1. Task

Open your global tasks file with `zed: open tasks` and add this object to the array:

```json
{
  "label": "Switch Project",
  "command": "/Users/alex/Code/zed-project-switcher/bin/zed-project-switcher",
  "args": ["$ZED_WORKTREE_ROOT"],
  "use_new_terminal": true,
  "allow_concurrent_runs": true,
  "hide": "on_success",
  "show_summary": false,
  "show_command": false
}
```

If `tasks.json` is empty, wrap it in `[ ]`.

### 2. Shortcut

Open your keymap with `zed: open keymap` and add:

```json
{
  "context": "Workspace",
  "bindings": {
    "cmd-;": [
      "task::Spawn",
      {
        "task_name": "Switch Project",
        "reveal_target": "center"
      }
    ]
  }
}
```

On Linux and Windows, bind `ctrl-;` instead of `cmd-;`.

If you already have a `"context": "Workspace"` block, put the `cmd-;` binding inside that block's `"bindings"` object.

## Use

Open any project inside your projects folder, then press `cmd+;`.

From a shell, the same picker is:

```sh
/Users/alex/Code/zed-project-switcher/bin/zed-project-switcher /Users/alex/Code/switch-project
```

Print the list without opening the picker:

```sh
/Users/alex/Code/zed-project-switcher/bin/zed-project-switcher --list /Users/alex/Code/switch-project
```

To scan a different folder than the parent of the current project, set `ZED_PROJECT_SWITCHER_DIRECTORY` in the task's environment:

```json
"env": { "ZED_PROJECT_SWITCHER_DIRECTORY": "/Users/alex/Code" }
```

Directories whose names start with `.` are skipped. A folder with no git branch is listed by name only. A detached HEAD shows the first 7 characters of the commit.
