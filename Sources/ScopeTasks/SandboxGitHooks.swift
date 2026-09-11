import Foundation

/// Git hooks for the threads of a task, so an agent working in a sandbox cannot commit into the user's checkout
/// or another task's sandbox, nor push onto the repository's default branch.
///
/// They are pointed at through the thread's environment — `core.hooksPath` passed as `GIT_CONFIG_KEY_<n>` /
/// `GIT_CONFIG_VALUE_<n>` — never written into a repository: nothing to undo when the task closes, and git run
/// anywhere else (the user's own terminal, the editor, Scope's own Delta actions) never sees them. It holds for
/// every driver, since it is git that runs them.
///
/// Pointing `core.hooksPath` elsewhere hides the repository's own hooks, so every hook here hands over to the
/// repository's hook of the same name (husky's `.husky/_`, lefthook's or pre-commit's `.git/hooks`), read from
/// the config files alone so this override does not answer for them.
///
/// They are a guardrail, not a lock: `git commit --no-verify` or `git push --no-verify` walks past them.
public enum SandboxGitHooks {
    /// `<home>/githooks`
    public static func directory(home: URL) -> URL {
        home.appending(path: "githooks", directoryHint: .isDirectory)
    }

    static let dispatcherName = "scope-dispatch"

    /// The hooks installed, each a symlink to the dispatcher. `reference-transaction` and `post-index-change` are
    /// left out: they fire on nearly every git command (a `git status` writes the index), and a shell per call
    /// would slow the agent's git down for the rare repository that uses them.
    public static let hookNames = [
        "applypatch-msg", "pre-applypatch", "post-applypatch", "pre-commit", "pre-merge-commit",
        "prepare-commit-msg", "commit-msg", "post-commit", "pre-rebase", "post-checkout", "post-merge",
        "pre-push", "post-rewrite", "push-to-checkout", "pre-auto-gc", "sendemail-validate",
    ]

    /// Writes the dispatcher and its symlinks under `<home>/githooks` (idempotent: an unchanged file is left alone)
    /// and returns the directory.
    @discardableResult
    public static func install(home: URL) throws -> URL {
        let fileManager = FileManager.default
        let directory = directory(home: home)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let dispatcher = directory.appending(path: dispatcherName, directoryHint: .notDirectory)
        if (try? String(contentsOf: dispatcher, encoding: .utf8)) != script {
            try script.write(to: dispatcher, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dispatcher.path)
        for name in hookNames {
            let link = directory.appending(path: name, directoryHint: .notDirectory)
            if (try? fileManager.destinationOfSymbolicLink(atPath: link.path)) == dispatcherName { continue }
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(atPath: link.path, withDestinationPath: dispatcherName)
        }
        return directory
    }

    /// `environment` with `core.hooksPath=<hooksPath>` appended to its `GIT_CONFIG_*` entries (after any the user
    /// already set). Unchanged when the entry is already there.
    public static func environment(adding hooksPath: String, to environment: [String: String]) -> [String: String] {
        let count = environment["GIT_CONFIG_COUNT"].flatMap(Int.init) ?? 0
        for index in 0..<count where environment["GIT_CONFIG_KEY_\(index)"]?.lowercased() == "core.hookspath"
            && environment["GIT_CONFIG_VALUE_\(index)"] == hooksPath {
            return environment
        }
        var result = environment
        result["GIT_CONFIG_KEY_\(count)"] = "core.hooksPath"
        result["GIT_CONFIG_VALUE_\(count)"] = hooksPath
        result["GIT_CONFIG_COUNT"] = String(count + 1)
        return result
    }

    /// The dispatcher: POSIX sh, run by git with the hook's own arguments and stdin.
    static let script = #"""
    #!/bin/sh
    # Scope's git hooks for the threads of a task (SandboxGitHooks.swift in Scope). Scope checks pre-commit
    # and pre-push, then every hook hands over to the repository's own hook of the same name.
    hook=$(basename "$0")
    here=$(cd "$(dirname "$0")" && pwd -P)

    # The repository's own hooks directory, read from the config files only: GIT_CONFIG_* (this override)
    # is not a file, so it does not answer here.
    own_hooks_dir() {
        dir=$(git config --worktree --get core.hooksPath 2>/dev/null \
            || git config --local --get core.hooksPath 2>/dev/null \
            || git config --global --get core.hooksPath 2>/dev/null \
            || git config --system --get core.hooksPath 2>/dev/null)
        if [ -z "$dir" ]; then
            dir="$(git rev-parse --path-format=absolute --git-common-dir)/hooks"
        fi
        case "$dir" in
            /*) ;;
            "~/"*) dir="$HOME/${dir#\~/}" ;;
            *) dir="$(git rev-parse --show-toplevel)/$dir" ;;
        esac
        printf '%s\n' "$dir"
    }

    # A probe of another checkout must not inherit the GIT_DIR / GIT_INDEX_FILE git exports to the hook.
    probe() { env -u GIT_DIR -u GIT_INDEX_FILE -u GIT_WORK_TREE -u GIT_PREFIX git "$@"; }

    task_root() {
        [ -n "$SCOPE_TASK_ROOT" ] && [ -d "$SCOPE_TASK_ROOT" ] && (cd "$SCOPE_TASK_ROOT" && pwd -P)
    }

    # Refuses a commit in a checkout of one of the task's repositories that is not the task's own sandbox:
    # the user's base checkout, or another task's worktree. Unrelated repositories are left alone.
    check_commit() {
        root=$(task_root) || return 0
        top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
        top=$(cd "$top" && pwd -P)
        case "$top/" in "$root"/*) return 0 ;; esac
        common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
        for sandbox in "$root" "$root"/*; do
            [ -e "$sandbox/.git" ] || continue
            other=$(probe -C "$sandbox" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || continue
            if [ "$other" = "$common" ]; then
                echo "scope: refusing to commit in $top, a checkout this task must not touch." >&2
                echo "scope: this task works on that repository in $sandbox; commit there instead." >&2
                exit 1
            fi
        done
    }

    # Refuses a push from the task's sandbox onto the remote's default branch: the work goes through the
    # task's own branch and a pull request.
    check_push() {
        root=$(task_root) || return 0
        top=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
        top=$(cd "$top" && pwd -P)
        case "$top/" in "$root"/*) ;; *) return 0 ;; esac
        default=$(git symbolic-ref --quiet --short "refs/remotes/$1/HEAD" 2>/dev/null)
        default=${default#"$1"/}
        while read -r local_ref local_sha remote_ref remote_sha; do
            case "$remote_ref" in
                "refs/heads/$default" | refs/heads/main | refs/heads/master)
                    [ -n "$default" ] && [ "$remote_ref" != "refs/heads/$default" ] && continue
                    echo "scope: refusing to push to ${remote_ref#refs/heads/} on $1 from a task sandbox." >&2
                    echo "scope: push the task's branch and open a pull request instead." >&2
                    exit 1 ;;
            esac
        done <<EOF
    $input
    EOF
    }

    case "$hook" in
        pre-commit) check_commit ;;
        pre-push)
            input=$(cat)
            check_push "$@" ;;
    esac

    own=$(own_hooks_dir)
    if [ -x "$own/$hook" ] && [ "$(cd "$own" 2>/dev/null && pwd -P)" != "$here" ]; then
        if [ "$hook" = pre-push ]; then
            printf '%s\n' "$input" | "$own/$hook" "$@"
            exit $?
        fi
        exec "$own/$hook" "$@"
    fi
    exit 0

    """#
}
