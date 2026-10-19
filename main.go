package main

import (
	"bufio"
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const palenightColors = "dark," +
	"bg:#292D3E,fg:#BFC7D5,hl:#C792EA," +
	"fg+:#ffffff,bg+:#7e57c2,hl+:#FFCB6B,gutter:#292D3E," +
	"info:#929ac9,prompt:#82AAFF,pointer:#C792EA,marker:#C792EA," +
	"query:#ffffff,border:#676E95,separator:#676E95,label:#BFC7D5"

var (
	headRef = regexp.MustCompile(`^ref:\s*refs/heads/(.+)$`)
	gitdir  = regexp.MustCompile(`^gitdir:\s*(.+)$`)
	sha     = regexp.MustCompile(`^[0-9a-fA-F]{7,40}$`)
)

type project struct {
	mtime int64
	label string
	path  string
}

func main() {
	os.Setenv("PATH", "/opt/homebrew/bin:/usr/local/bin:"+os.Getenv("PATH"))

	// fzf reruns us on every keystroke to list the folder the query points at.
	if len(os.Args) == 4 && os.Args[1] == "--feed" {
		dir, prefix := browseTarget(os.Args[2], os.Args[3])
		if entries, err := projectsIn(dir); err == nil {
			fmt.Print(feedFor(entries, prefix))
		}
		return
	}

	listOnly, projectArg, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		usage()
		os.Exit(1)
	}

	if projectArg == "" {
		projectArg = os.Getenv("ZED_WORKTREE_ROOT")
		if projectArg == "" {
			projectArg, err = os.Getwd()
			if err != nil {
				fmt.Fprintf(os.Stderr, "zed-project-switcher: %s\n", err)
				os.Exit(1)
			}
		}
	}

	current, err := filepath.Abs(projectArg)
	if err != nil || !isDir(current) {
		fmt.Fprintf(os.Stderr, "zed-project-switcher: not a directory: %s\n", projectArg)
		os.Exit(1)
	}
	if resolved, err := filepath.EvalSymlinks(current); err == nil {
		current = resolved
	}

	projectsDir := filepath.Dir(current)
	if override := os.Getenv("ZED_PROJECT_SWITCHER_DIRECTORY"); override != "" {
		projectsDir, err = filepath.Abs(override)
		if err != nil || !isDir(projectsDir) {
			fmt.Fprintf(os.Stderr, "zed-project-switcher: ZED_PROJECT_SWITCHER_DIRECTORY is not a directory: %s\n", override)
			os.Exit(1)
		}
		if resolved, err := filepath.EvalSymlinks(projectsDir); err == nil {
			projectsDir = resolved
		}
	}

	entries, err := projectsIn(projectsDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "zed-project-switcher: cannot read %s: %s\n", projectsDir, err)
		os.Exit(1)
	}
	if len(entries) == 0 {
		fmt.Fprintf(os.Stderr, "zed-project-switcher: no project directories in %s\n", projectsDir)
		os.Exit(1)
	}

	if listOnly {
		for _, entry := range entries {
			fmt.Println(entry.label)
		}
		return
	}

	fzfPath, err := exec.LookPath("fzf")
	if err != nil {
		fmt.Fprintln(os.Stderr, "zed-project-switcher: fzf is required. Install it with: brew install fzf")
		os.Exit(1)
	}

	self, err := os.Executable()
	if err != nil {
		fmt.Fprintf(os.Stderr, "zed-project-switcher: %s\n", err)
		os.Exit(1)
	}
	reload := shellQuote(self) + " --feed " + shellQuote(projectsDir) + " {q}"
	title := " Switch Project · " + tildePath(projectsDir) + " "

	selected, cancelled := runFZF(fzfPath, feedFor(entries, ""), title, reload)
	if cancelled {
		return
	}

	parts := strings.SplitN(selected, "\t", 2)
	if len(parts) != 2 || parts[1] == "" {
		return
	}

	zed, err := findZed()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// Zed's new-window CLI mode never reuses a window for a project root,
	// so focus the window ourselves when the project is already open.
	flag := "-n"
	if isOpenInZed(parts[1]) {
		flag = "-e"
	}
	cmd := exec.Command(zed, flag, parts[1])
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		if exit, ok := err.(*exec.ExitError); ok {
			os.Exit(exit.ExitCode())
		}
		fmt.Fprintf(os.Stderr, "zed-project-switcher: %s\n", err)
		os.Exit(1)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `Usage: zed-project-switcher [--list] [project-path]

Scan the parent of project-path for directories, show each one as
"name / branch", and open the selection in Zed.

  --list         Print the sorted list and exit
  project-path   Current project. Defaults to $ZED_WORKTREE_ROOT, then the
                 working directory.

Set ZED_PROJECT_SWITCHER_DIRECTORY to scan a folder other than the project's parent.

In the picker, a query that starts with ~/, /, ./ or ../ lists that folder
instead, with ./ and ../ relative to the scanned folder. ~/code/web lists
~/code and filters it by "web".
`)
}

func parseArgs(args []string) (listOnly bool, projectArg string, err error) {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "-h" || arg == "--help":
			usage()
			os.Exit(0)
		case arg == "--list":
			listOnly = true
		case arg == "--":
			if i+1 < len(args) {
				if projectArg != "" {
					return false, "", fmt.Errorf("zed-project-switcher: unexpected argument: %s", args[i+1])
				}
				projectArg = args[i+1]
			}
			return listOnly, projectArg, nil
		case strings.HasPrefix(arg, "-"):
			return false, "", fmt.Errorf("zed-project-switcher: unknown option: %s", arg)
		default:
			if projectArg != "" {
				return false, "", fmt.Errorf("zed-project-switcher: unexpected argument: %s", arg)
			}
			projectArg = arg
		}
	}
	return listOnly, projectArg, nil
}

func projectsIn(directory string) ([]project, error) {
	children, err := os.ReadDir(directory)
	if err != nil {
		return nil, err
	}

	entries := make([]project, 0, len(children))
	for _, child := range children {
		name := child.Name()
		if name == "" || name[0] == '.' {
			continue
		}
		path := filepath.Join(directory, name)
		if !isDir(path) {
			continue
		}
		entries = append(entries, inspectProject(path, name))
	}

	sort.Slice(entries, func(i, j int) bool {
		if entries[i].mtime != entries[j].mtime {
			return entries[i].mtime > entries[j].mtime
		}
		return entries[i].label < entries[j].label
	})
	return entries, nil
}

func feedFor(entries []project, prefix string) string {
	var feed strings.Builder
	for _, entry := range entries {
		fmt.Fprintf(&feed, "%s%s\t%s\n", prefix, entry.label, entry.path)
	}
	return feed.String()
}

// browseTarget picks the folder to list for an fzf query. A query that starts
// like a path lists the folder up to its last slash, with ./ and ../ taken
// relative to base, and its rows keep that typed folder as a prefix so fzf
// still matches the whole query. Any other query lists base.
func browseTarget(base, query string) (dir, prefix string) {
	query = strings.TrimLeft(query, " ")
	switch query {
	case "~", ".", "..":
		query += "/"
	}
	isPath := false
	for _, start := range []string{"/", "~/", "./", "../"} {
		if strings.HasPrefix(query, start) {
			isPath = true
		}
	}
	if !isPath {
		return base, ""
	}

	prefix = query[:strings.LastIndex(query, "/")+1]
	switch {
	case strings.HasPrefix(prefix, "~/"):
		home, _ := os.UserHomeDir()
		dir = filepath.Join(home, prefix[2:])
	case filepath.IsAbs(prefix):
		dir = filepath.Clean(prefix)
	default:
		dir = filepath.Join(base, prefix)
	}
	if resolved, err := filepath.EvalSymlinks(dir); err == nil {
		dir = resolved
	}
	return matchCase(dir), prefix
}

// matchCase spells each part of an absolute path the way it is on disk, so a
// typed ~/code finds ~/Code on a case-insensitive volume and the path handed
// to Zed matches the one in its workspace database.
func matchCase(path string) string {
	fixed := "/"
	for _, part := range strings.Split(path, "/") {
		if part == "" {
			continue
		}
		spelled := part
		if children, err := os.ReadDir(fixed); err == nil {
			for _, child := range children {
				if child.Name() == part {
					spelled = part
					break
				}
				if strings.EqualFold(child.Name(), part) {
					spelled = child.Name()
				}
			}
		}
		fixed = filepath.Join(fixed, spelled)
	}
	return fixed
}

func tildePath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if path == home {
		return "~"
	}
	if strings.HasPrefix(path, home+"/") {
		return "~" + path[len(home):]
	}
	return path
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

func inspectProject(path, name string) project {
	gitPath := resolveGitDir(path)
	var branch string
	var mtime int64

	if gitPath != "" {
		headFile := filepath.Join(gitPath, "HEAD")
		if head, err := firstLine(headFile); err == nil {
			if info, err := os.Stat(headFile); err == nil {
				mtime = info.ModTime().UnixNano()
			}
			if match := headRef.FindStringSubmatch(head); match != nil {
				branch = strings.TrimSpace(match[1])
			} else if sha.MatchString(head) {
				if len(head) > 7 {
					branch = head[:7]
				} else {
					branch = head
				}
			}
		}
		if info, err := os.Stat(filepath.Join(gitPath, "index")); err == nil {
			if stamp := info.ModTime().UnixNano(); stamp > mtime {
				mtime = stamp
			}
		}
	}

	if mtime == 0 {
		if info, err := os.Stat(path); err == nil {
			mtime = info.ModTime().UnixNano()
		}
	}

	label := name
	if branch != "" {
		label = name + " / \uE0A0 " + branch
	}
	return project{mtime: mtime, label: label, path: path}
}

func resolveGitDir(project string) string {
	gitPath := filepath.Join(project, ".git")
	info, err := os.Lstat(gitPath)
	if err != nil {
		return ""
	}

	if info.Mode().IsRegular() {
		line, err := firstLine(gitPath)
		if err != nil {
			return ""
		}
		match := gitdir.FindStringSubmatch(line)
		if match == nil {
			return ""
		}
		target := strings.TrimSpace(match[1])
		if !filepath.IsAbs(target) {
			target = filepath.Join(project, target)
		}
		if isDir(target) {
			return target
		}
		return ""
	}

	if info.IsDir() || isDir(gitPath) {
		return gitPath
	}
	return ""
}

func firstLine(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	scanner := bufio.NewScanner(file)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return "", err
		}
		return "", fmt.Errorf("empty file")
	}
	return strings.TrimSpace(scanner.Text()), nil
}

func runFZF(fzfPath, feed, title, reload string) (selected string, cancelled bool) {
	env := os.Environ()
	filtered := make([]string, 0, len(env))
	for _, item := range env {
		if !strings.HasPrefix(item, "FZF_DEFAULT_OPTS=") {
			filtered = append(filtered, item)
		}
	}

	cmd := exec.Command(
		fzfPath,
		"--prompt", "> ",
		"--no-sort",
		"--reverse",
		"--margin", "16%,8%",
		"--border", "rounded",
		"--border-label", title,
		"--padding", "1,2",
		"--delimiter", "\t",
		"--nth", "1",
		"--with-nth", "1",
		"--no-bold",
		"--color", palenightColors,
		"--bind", "change:reload:"+reload,
	)
	cmd.Stdin = strings.NewReader(feed)
	cmd.Stderr = os.Stderr
	cmd.Env = filtered

	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return "", true
	}

	line := strings.TrimSpace(stdout.String())
	if line == "" {
		return "", true
	}
	if idx := strings.IndexByte(line, '\n'); idx >= 0 {
		line = line[:idx]
	}
	return line, false
}

// zedFlavor returns the app bundle name and release channel of the Zed that
// launched us. Zed sets the bundle ID of the app in every process it spawns,
// so a dev build gets its own CLI and its own workspace database.
func zedFlavor() (app, channel string) {
	switch os.Getenv("__CFBundleIdentifier") {
	case "dev.zed.Zed-Dev":
		return "Zed Dev.app", "dev"
	case "dev.zed.Zed-Preview":
		return "Zed Preview.app", "preview"
	}
	return "Zed.app", "stable"
}

func findZed() (string, error) {
	if override := os.Getenv("ZED_PROJECT_SWITCHER_ZED"); override != "" {
		return override, nil
	}
	app, channel := zedFlavor()
	if channel == "stable" {
		if found, err := exec.LookPath("zed"); err == nil {
			return found, nil
		}
	}
	home, _ := os.UserHomeDir()
	candidates := []string{
		filepath.Join("/Applications", app, "Contents/MacOS/cli"),
		filepath.Join(home, "Applications", app, "Contents/MacOS/cli"),
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && info.Mode()&0111 != 0 {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("zed-project-switcher: could not find the CLI for %s. In Zed, run \"zed: install cli\"", app)
}

// isOpenInZed reports whether a window in the running Zed session has path
// open as its project, going by Zed's workspace database. Any failure counts
// as not open, which falls back to opening a new window.
func isOpenInZed(path string) bool {
	sqlite, err := exec.LookPath("sqlite3")
	if err != nil {
		return false
	}
	home, _ := os.UserHomeDir()
	_, channel := zedFlavor()
	db := filepath.Join(home, "Library/Application Support/Zed/db/0-"+channel+"/db.sqlite")
	if _, err := os.Stat(db); err != nil {
		return false
	}
	out, err := exec.Command(sqlite, "-readonly", db, openWorkspaceQuery(path)).Output()
	return err == nil && strings.TrimSpace(string(out)) == "1"
}

// openWorkspaceQuery matches a workspace for path in the current session
// whose window is still in Zed's window stack.
func openWorkspaceQuery(path string) string {
	quoted := "'" + strings.ReplaceAll(path, "'", "''") + "'"
	return `SELECT 1 FROM workspaces w
JOIN kv_store s ON s.key = 'session_id' AND s.value = w.session_id
JOIN kv_store k ON k.key = 'session_window_stack'
WHERE w.paths = ` + quoted + ` AND w.remote_connection_id IS NULL
AND EXISTS (SELECT 1 FROM json_each(k.value) WHERE json_each.value = w.window_id)
LIMIT 1;`
}

func isDir(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}
