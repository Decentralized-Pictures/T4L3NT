#! /bin/sh

# See `update_unit_test.sh` for documentation.

set -e

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"
src_dir="$(dirname "$script_dir")"

tmp=$(mktemp)

csplit --quiet --prefix="$tmp" "$src_dir/.gitlab-ci.yml" /##BEGIN_INTEGRATION_PYTHON##/+1
mv "$tmp"00 "$tmp"
rm "$tmp"0*

for test in $(find tests_python/tests/ -name 'test_*.py' | LC_COLLATE=C sort); do
    case "$test" in
      */multibranch/*)
        # skip multibranch tests for now
        ;;
      *)
        testname=${test##*/test_}
        testname=${testname%%.py}
        cat >> $tmp <<EOF
integration:$testname:
  <<: *integration_python_definition
  script:
    - poetry run pytest ${test#tests_python/} -s --log-dir=tmp
  stage: test

EOF
    esac
done

cat >> $tmp <<EOF
integration:examples_forge_transfer:
  <<: *integration_python_definition
  script:
    - PYTHONPATH=\$PYTHONPATH:./ poetry run python examples/forge_transfer.py
  stage: test

integration:examples_example:
  <<: *integration_python_definition
  script:
    - PYTHONPATH=\$PYTHONPATH:./ poetry run python examples/example.py
  stage: test

integration:examples_test_example:
  <<: *integration_python_definition
  script:
    - PYTHONPATH=./ poetry run pytest examples/test_example.py
  stage: test
EOF

csplit --quiet --prefix="$tmp" "$src_dir/.gitlab-ci.yml" %##END_INTEGRATION_PYTHON##%
cat "$tmp"00 >> "$tmp"
rm "$tmp"0*

mv $tmp "$src_dir/.gitlab-ci.yml"
