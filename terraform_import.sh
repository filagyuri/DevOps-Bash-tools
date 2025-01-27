#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2022-02-25 18:14:24 +0000 (Fri, 25 Feb 2022)
#
#  https://github.com/HariSekhon/bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help steer this or other code I publish
#
#  https://www.linkedin.com/in/HariSekhon
#

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(dirname "${BASH_SOURCE[0]}")"

# shellcheck disable=SC1090
. "$srcdir/lib/utils.sh"

# shellcheck disable=SC2034,SC2154
usage_description="
Finds all given resource references in ./*.tf code not in Terraform state and imports them assuming the same resource name as Terraform ID in the code

Will do nothing if the resource_type you specify doesn't match anything in the local code eg. 'github_repo' won't match, it must be the terraform type 'github_repository'

This is a general case importer that will only cover basic use cases such as GitHub repos where the names usually match the terraform IDs
(except for things like '.github' repo which is not a valid terraform identifier. Those must still be imported manually)


Requires Terraform to be installed and configured
"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="<resource_type> [<dir>]"

help_usage "$@"

min_args 1 "$@"

resource_type="$1"
dir="${2:-.}"

cd "$dir"

timestamp "getting terraform state"
terraform_state_list="$(terraform state list)"
echo >&2

timestamp "getting '$resource_type' from $PWD/*.tf code"
grep -E "^[[:space:]]*resource[[:space:]]+\"$resource_type\"" ./*.tf |
awk '{gsub("\"", "", $3); print $3}' |
while read -r resource; do
    echo >&2
    if grep -q "$resource_type.$resource$" <<< "$terraform_state_list"; then
        echo "'$resource_type.$resource' already in terraform state, skipping..." >&2
        continue
    fi
    cmd="terraform import $resource_type.$resource $resource"
    timestamp "$cmd"
    $cmd
done
