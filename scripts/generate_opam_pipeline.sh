#!/usr/bin/env bash

set -eu

script_dir="$(cd "$(dirname "$0")" && echo "$(pwd -P)/")"

#shellcheck disable=SC1090
. "$script_dir"opam-pin.sh

#shellcheck disable=SC2154
PACKAGES=$(echo "$packages" | tr '\n' ' ')

TZ_OPAM_FILES_MODIFIED="${TZ_OPAM_FILES_MODIFIED:-false}"
TZ_PIPELINE_KIND="${TZ_PIPELINE_KIND:-NOT_SCHEDULE}"
TZ_SCHEDULE_KIND="${TZ_SCHEDULE_KIND:-NOT_SCHEDULE}"

{
cat <<EOF
include: ".gitlab/ci/templates.yml"

stages:
  - packaging

opam:placeholder_job:
  stage: "packaging"
  script: "echo This is placeholder job to make sure that the child pipeline is not empty"
  rules:
    - when: always
EOF
} > opam-ci.yml

for PKG in $PACKAGES; do
{
  cat <<EOF

opam:$PKG:
  extends:
    - .default_settings_template
    - .image_template__runtime_build_test_dependencies_template
    - .rules_template__opam_child_pipeline_tests
  stage: packaging
  variables:
    TZ_OPAM_FILES_MODIFIED: "$TZ_OPAM_FILES_MODIFIED"
    TZ_PIPELINE_KIND: "$TZ_PIPELINE_KIND"
    TZ_SCHEDULE_KIND: "$TZ_SCHEDULE_KIND"
  script:
    - ./scripts/opam-pin.sh
    - opam depext --yes $PKG
    - opam install --yes $PKG
    - opam reinstall --yes --with-test $PKG
EOF
} >> opam-ci.yml
done
