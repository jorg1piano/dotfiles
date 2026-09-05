#!/usr/bin/env bash
# Find local Git worktrees belonging to repositories with the given remote.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: find-worktrees.sh SEARCH_FOLDER REMOTE_URL

Search the folder recursively for Git repositories, then print
their existing worktree paths once per line, excluding main and master branches.
Any configured remote may match. HTTPS and SSH URLs are treated equivalently.
Registered worktrees outside the search folder are included too.
No network access is needed. No matches produces no output.

Example:
  ./scripts/find-worktrees.sh ~/code https://github.com/jorg1piano/chordprog2-flutter.git
  ./scripts/find-worktrees.sh . git@github.com:jorg1piano/chordprog2-flutter.git
EOF
}

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    usage
    exit 0
fi
if [[ $# -ne 2 || -z ${1:-} || -z ${2:-} ]]; then
    usage >&2
    exit 2
fi

normalize_remote() {
    local url=$1
    case "$url" in
        *://*)
            url=${url#*://}
            url=${url#*@}
            ;;
        *@*:*)
            url=${url#*@}
            url=${url/:/\/}
            ;;
    esac
    url=${url%/}
    printf '%s\n' "${url%.git}"
}

target=$(normalize_remote "$2")
set -- "$1"

for folder in "$@"; do
    if [[ ! -d $folder ]]; then
        printf 'Search folder does not exist: %s\n' "$folder" >&2
        exit 2
    fi
done

find_matches() {
    local folder marker repo remote url matches field path excluded
    for folder in "$@"; do
        # Absolute roots also protect find from folder names starting with '-'.
        folder=$(cd "$folder" && pwd -P)
        while IFS= read -r -d '' marker; do
            repo=${marker%/.git}
            matches=false
            while IFS= read -r remote; do
                while IFS= read -r url; do
                    if [[ $(normalize_remote "$url") == "$target" ]]; then
                        matches=true
                        break
                    fi
                done < <(git -C "$repo" remote get-url --all "$remote" 2>/dev/null)
                if [[ $matches == true ]]; then
                    break
                fi
            done < <(git -C "$repo" remote 2>/dev/null)

            if [[ $matches == true ]]; then
                path=
                excluded=false
                while IFS= read -r -d '' field; do
                    case "$field" in
                        'worktree '*)
                            path=${field#worktree }
                            ;;
                        'branch refs/heads/main'|'branch refs/heads/master')
                            excluded=true
                            ;;
                        '')
                            if [[ $excluded == false && -n $path && -d $path ]]; then
                                printf '%s\n' "$path"
                            fi
                            path=
                            excluded=false
                            ;;
                    esac
                done < <(git -C "$repo" worktree list --porcelain -z)
            fi
        done < <(find "$folder" -name .git -prune -print0)
    done
}

find_matches "$@" | LC_ALL=C sort -u
