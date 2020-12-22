#! /usr/bin/env bash

usage () {
    cat >&2 <<EOF
usage: $0 [<action>] [FILES] [--ignore FILES]

Where <action> can be:

* --update-ocamlformat: update all the \`.ocamlformat\` files and
  git-commit (requires clean repo).
* --check-ocamlformat: check the above does nothing.
* --check-dune: check formatting while assuming running under Dune's
  rule (\`dune build @runtest_lint\`).
* --check-ci: check formatting using git (for GitLab CI's verbose run).
* --check-gitlab-ci-yml: check .gitlab-ci.yml has been updated.
* --check-scripts: check the .sh files
* --format: format all the files, see also \`make fmt\`.
* --help: display this and return 0.

If no action is given, \`--check-dune\` is assumed.

If no files are provided all .ml, .mli, mlt files are formatted/checked.
EOF
}

## Testing for dependencies
if ! type ocamlformat > /dev/null 2>&-; then
  echo "ocamlformat is required but could not be found. Aborting."
  exit 1
fi
if ! type find > /dev/null 2>&-; then
  echo "find is required but could not be found. Aborting."
  exit 1
fi


set -e

say () {
    echo "$*" >&2
}


make_dot_ocamlformat () {
    local path="$1"
    cat > "$path" <<EOF
version=0.10
wrap-fun-args=false
let-binding-spacing=compact
field-space=loose
break-separators=after-and-docked
sequence-style=separator
doc-comments=before
margin=80
module-item-spacing=sparse
parens-tuple=always
parens-tuple-patterns=always
break-string-literals=newlines-and-wrap
EOF
}

declare -a source_directories

source_directories=(src docs/doc_gen tezt)

update_all_dot_ocamlformats () {
    if git diff --name-only HEAD --exit-code
    then
        say "Repository clean :thumbsup:"
    else
        say "Repository not clean, which is required by this script."
        exit 2
    fi
    interesting_directories=$(find "${source_directories[@]}" \( -name "*.ml" -o -name "*.mli"  \) -type f | sed 's:/[^/]*$::' | LC_COLLATE=C sort -u)
    for d in $interesting_directories ; do
        ofmt=$d/.ocamlformat
        case "$d" in
            src/proto_alpha/lib_protocol | \
            src/proto_demo_noops/lib_protocol )
                make_dot_ocamlformat "$ofmt"
                ;;
            src/proto_00{0..6}_*/lib_protocol )
                make_dot_ocamlformat "$ofmt"
                ( cd "$d" ; ls -1 *.mli *.ml | LC_COLLATE=C sort > .ocamlformat-ignore ; )
                git add "$d/.ocamlformat-ignore"
                ;;
            * )
                make_dot_ocamlformat "$ofmt"
                ;;
        esac
        git add "$ofmt"
    done
}

check_with_dune () {
    for f in "$@" ; do
        case "$PWD" in
            */src/proto_alpha/lib_protocol$ | \
            */src/proto_demo_noops/lib_protocol$ )
                make_dot_ocamlformat .ocamlformat
                ocamlformat --check "$f"
                ;;
            */src/proto_*/lib_protocol$ )
                say "This a protocol file, ignoring"
                ;;
            * )
                make_dot_ocamlformat .ocamlformat
                ocamlformat --check "$f"
                ;;
        esac
    done
}

check_scripts () {
    scripts=$(find "${source_directories[@]}" tests_python/ scripts/ -name "*.sh" -type f -print)
    exit_code=0
    tab="$(printf '%b' '\t')"
    for f in $scripts ; do
        if grep -q "$tab" "$f"; then
            say "$f has tab character(s)"
            exit_code=1
        fi
    done
    exit $exit_code
}

format_inplace () {
    ocamlformat --inplace "$@"
}

update_gitlab_ci_yml () {
    # Check that a rule is not defined twice, which would result in the first
    # one being ignored. Gitlab linter doesn't warn for it
    repeated=$(grep '^[^ #]' .gitlab-ci.yml | sort | uniq --repeated)
    if [ -n "$repeated" ]; then
        echo ".gitlab-ci.yml contains repeated rules:"
        echo "$repeated"
        exit 1
    fi
    # Update generated test sections
    for script in scripts/update_*_test.sh; do
        echo "Running $script..."
        $script
    done
}

if [ $# -eq 0 ] || [[ "$1" != --* ]]; then
    action="--check-dune"
else
    action="$1"
    shift
fi

check_clean=false
commit=
on_files=false

case "$action" in
    "--update-ocamlformat" )
        action=update_all_dot_ocamlformats
        commit="Update .ocamlformat files" ;;
    "--check-ocamlformat" )
        action=update_all_dot_ocamlformats
        check_clean=true ;;
    "--check-dune" )
        on_files=true
        action=check_with_dune ;;
    "--check-ci" )
        on_files=true
        action=format_inplace
        check_clean=true ;;
    "--check-gitlab-ci-yml" )
        action=update_gitlab_ci_yml
        check_clean=true ;;
    "--check-scripts" )
        action=check_scripts ;;
    "--format" )
        on_files=true
        action=format_inplace ;;
    "help" | "-help" | "--help" | "-h" )
        usage
        exit 0 ;;
    * )
        say "Error no action (arg 1 = '$action') provided"
        usage
        exit 2 ;;
esac

if $on_files; then
    declare -a input_files files ignored_files
    input_files=()
    while [ $# -gt 0 ]; do
        if [ "$1" = "--ignore" ]; then
            shift
            break
        fi
        input_files+=("$1")
        shift
    done

    if [ ${#input_files[@]} -eq 0 ]; then
        mapfile -t input_files <<< "$(find "${source_directories[@]}" \( -name "*.ml" -o -name "*.mli" -o -name "*.mlt" \) -type f -print)"
    fi

    ignored_files=("$@")

    # $input_files may contain `*.pp.ml{i}` files which can't be linted. They
    # are filtered by the following loop.
    #
    # Note: another option would be to filter them before calling the script
    # but it was more convenient to do it here.
    files=()
    for file in "${input_files[@]}"; do
        if [[ "$file" == *.pp.ml?(i) ]]; then continue; fi
        for ignored_file in "${ignored_files[@]}"; do
            if [[ "$file" =~ ^(.*/)?"$ignored_file"$ ]] ; then continue 2; fi
        done
        files+=("$file")
    done
    $action "${files[@]}"
else
    if [ $# -gt 0 ]; then usage; exit 1; fi
    $action
fi

if [ -n "$commit" ]; then
    git commit -m "$commit"
fi

if $check_clean; then
    git diff --name-only HEAD --exit-code
fi
