#!/bin/sh

## Sourceable file with common variables for other scripts related to release

# shellcheck disable=SC2034
architectures='x86_64 arm64'

current_dir=$(cd "$(dirname "${0}")" && pwd)
scripts_dir=$(dirname "$current_dir")
src_dir=$(dirname "$scripts_dir")
script_inputs_dir="$src_dir/script-inputs"

binaries="$(cat "$script_inputs_dir/binaries-for-release")"

### Compute GitLab release names

# Remove the 'v' in front
# X.Y or X.Y-rcZ
gitlab_release_no_v=$(echo "${CI_COMMIT_TAG}" | sed -e 's/^v//g')

# Replace '.' with '-'
# X-Y or X-Y-rcZ
# shellcheck disable=SC2034
gitlab_release_no_dot=$(echo "${gitlab_release_no_v}" | sed -e 's/\./-/g')

# X
gitlab_release_major_version=$(echo "${CI_COMMIT_TAG}" | sed -nE 's/^v([0-9]+)\.([0-9]+)(-rc[0-9]+)?$/\1/p')
# Y
gitlab_release_minor_version=$(echo "${CI_COMMIT_TAG}" | sed -nE 's/^v([0-9]+)\.([0-9]+)(-rc[0-9]+)?$/\2/p')
# Z
gitlab_release_rc_version=$(echo "${CI_COMMIT_TAG}" | sed -nE 's/^v([0-9]+)\.([0-9]+)(-rc)?([0-9]+)?$/\4/p')

# Is this a release candidate?
if [ -n "${gitlab_release_rc_version}" ]
then
  # Yes, release name: X.Y~rcZ
  # shellcheck disable=SC2034
  gitlab_release_name="${gitlab_release_major_version}.${gitlab_release_minor_version}~rc${gitlab_release_rc_version}"
  opam_release_tag="${gitlab_release_major_version}.${gitlab_release_minor_version}~rc${gitlab_release_rc_version}"
else
  # No, release name: Release X.Y
  # shellcheck disable=SC2034
  gitlab_release_name="Release ${gitlab_release_major_version}.${gitlab_release_minor_version}"
  opam_release_tag="${gitlab_release_major_version}.${gitlab_release_minor_version}"
fi

### Compute GitLab generic package names

gitlab_package_name="${CI_PROJECT_NAME}-${gitlab_release_no_v}"

# X.Y or X.Y-rcZ
gitlab_package_version="${gitlab_release_no_v}"
