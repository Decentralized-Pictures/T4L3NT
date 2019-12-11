#!/bin/sh

usage () {
    cat >&2 <<EOF
usage: $0 [<action>] [FILES]

Where <action> can be:

* update.ocamlformat: update all the \`.ocamlformat\` files and
  git-commit (requires clean repo).
* check.dune: check formatting while assuming running under Dune's
  rule (\`dune build @runtest_lint\`).
* check.ci: check formatting using git (for GitLabCI's verbose run).
* format: format all the files, see also \`make fmt\`.
* help: display this and return 0.

If the first argument is a file, action 'check.dune' is assumed.

If no files are provided all .ml, .mli, mlt files are formatted/checked.
EOF
}

## Testing for dependencies
type ocamlformat > /dev/null 2>&-
if [ $? -ne 0 ]; then
  echo "ocamlformat is required but could not be found. Aborting."
  exit 1
fi
type find > /dev/null 2>&-
if [ $? -ne 0 ]; then
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

source_directories="src docs/doc_gen"

update_all_dot_ocamlformats () {
    interesting_directories=$(find $source_directories \( -name "*.ml" -o -name "*.mli"  \) -type f | sed 's:/[^/]*$::' | sort -u)
    if git diff --name-only HEAD --exit-code
    then
        say "Repository clean :thumbsup:"
    else
        say "Repository not clean, which is required by this script."
        exit 2
    fi
    for d in $interesting_directories ; do
        ofmt=$d/.ocamlformat
        say "Dealing with $ofmt"
        case "$d" in
            src/proto_demo_noops/lib_protocol )
                make_dot_ocamlformat "$ofmt"
                ;;
            src/proto_*/lib_protocol )
                say "This a protocol"
                make_dot_ocamlformat "$ofmt"
                ( cd "$d" ; ls -1 *.mli *.ml > .ocamlformat-ignore ; )
                git add "$d/.ocamlformat-ignore"
                ;;
            * )
                make_dot_ocamlformat "$ofmt"
                ;;
        esac
        git add "$ofmt"
    done
    git commit -m 'Update .ocamlformat files'
}

check_with_dune () {
    for f in $* ; do
        case "$PWD" in
            */src/proto_demo_noops/lib_protocol$ )
                make_dot_ocamlformat .ocamlformat
                ocamlformat --check $f
                ;;
            */src/proto_*/lib_protocol$ )
                say "This a protocol file, ignoring"
                ;;
            * )
                make_dot_ocamlformat .ocamlformat
                ocamlformat --check $f
                ;;
        esac
    done
}


if [ -f "$1" ] ; then
    action=check.dune
    files="$@"
else
    action="$1"
    shift
    files="$@"
    if [ "$files" = "" ]; then
        files=$(find $source_directories \( -name "*.ml" -o -name "*.mli"  -o -name "*.mlt" \) -type f -print)
    fi
fi

case "$action" in
    "update.ocamlformat" )
        update_all_dot_ocamlformats ;;
    "check.dune" )
        check_with_dune $files ;;
    "check.ci" )
        say "Formatting for CI-test $files"
        ocamlformat --inplace $files
        git diff --exit-code ;;
    "format" )
        say "Formatting $files"
        ocamlformat --inplace $files ;;
    "help" | "-help" | "--help" | "-h" )
        usage ;;
    * )
        say "Error no action (arg 1 = '$action') provided"
        usage
        exit 2
        ;;
esac


