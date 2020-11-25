#!/usr/bin/env bash
#  vim:ts=4:sts=4:sw=4:et
#
#  Author: Hari Sekhon
#  Date: 2020-11-24 17:09:11 +0000 (Tue, 24 Nov 2020)
#
#  https://github.com/harisekhon/bash-tools
#
#  License: see accompanying Hari Sekhon LICENSE file
#
#  If you're using my code you're welcome to connect with me on LinkedIn and optionally send me feedback to help improve or steer this or other code I publish
#
#  https://www.linkedin.com/in/harisekhon
#

# Start a quick local TeamCity CI cluster

set -euo pipefail
[ -n "${DEBUG:-}" ] && set -x
srcdir="$(dirname "$0")"

# shellcheck disable=SC1090
. "$srcdir/lib/utils.sh"

# shellcheck disable=SC1090
. "$srcdir/.bash.d/network.sh"

# shellcheck disable=SC2034,SC2154
usage_description="
Boots TeamCity CI cluster with server and agent(s) in Docker, and builds the current repo

- boots TeamCity server and agent in Docker
- authorizes the agent(s) to begin building
- opens the TeamCity web UI to proceed and accept EULA (on Mac only)
- waits for the setup and EULA pages
- creates an administator-level user (\$TEAMCITY_USER, / \$TEAMCITY_PASSWORD - defaults to admin / admin)
  - opens the TeamCity web UI login page (on Mac only)

    ${0##*/} [up]

    ${0##*/} down
"

# used by usage() in lib/utils.sh
# shellcheck disable=SC2034
usage_args="[up|down]"

help_usage "$@"

server="http://${TEAMCITY_HOST:-localhost}:${TEAMCITY_PORT:-8111}"
url="$server"
api="$server/app/rest"

config="$srcdir/setup/teamcity-docker-compose.yml"

if ! type docker-compose &>/dev/null; then
    "$srcdir/install_docker_compose.sh"
fi

action="${1:-up}"
shift || :

opts=""
if [ "$action" = up ]; then
    opts="-d"
fi

timestamp "Booting TeamCity cluster:"
docker-compose -f "$config" "$action" $opts "$@"
echo >&2
if [ "$action" = down ]; then
    exit 0
fi

# fails due to 302 redirect to http://localhost:8111/setupAdmin.html
# / and /setupAdmin.html and /login.html
#when_url_content "$server/login.html" '(?i:teamcity)'
#when_ports_available 60 "${TEAMCITY_HOST:-localhost}" "${TEAMCITY_PORT:-8111}"
when_url_content 60 "$server" '.*'
echo >&2

timestamp "Open TeamCity Server URL in web browser to continue, click proceed, accept EULA etc.."
echo >&2
timestamp "TeamCity Server URL:  $url"
echo >&2
if is_mac; then
    timestamp "detected running on Mac, opening TeamCity Server URL for you automatically"
    echo >&2
    open "$url"
fi

max_secs=300

SECONDS=0
timestamp "waiting for up to $max_secs seconds for user to click proceed through First Start and database setup pages"
while curl -sSL "$url" | \
      grep -qi -e 'first.*start' \
               -e 'database.*setup' \
               -e 'TeamCity Maintenance' \
               -e 'Setting up'; do
    timestamp "waiting for you to click proceed through First Start & setup pages and then preliminary initialization to finish"
    if [ $SECONDS -gt $max_secs ]; then
        die "Did not progress past First Start and setup pages within $max_secs seconds"
    fi
    sleep 3
done
echo >&2

# second run would break here as this wouldn't come again, must use .* search
# just to check we are not getting a temporary 404 or something that happens before the EULA comes up
#when_url_content 60 "$url" "license.*agreement"
when_url_content 60 "$url" ".*"
echo >&2

SECONDS=0
timestamp "waiting for up to $max_secs seconds for user to accept EULA"
# curl gives an error when grep cuts its long EULA agreement short:
# (23) Failed writing body
while { curl -sSL "$url" 2>/dev/null || : ; } |
      grep -qi 'license.*agreement'; do
    timestamp "waiting for you to accept the license agreement"
    if [ $SECONDS -gt $max_secs ]; then
        die "Did not accept EULA within $max_secs seconds"
    fi
    sleep 3
done
echo >&2

SECONDS=0
timestamp "waiting for up to $max_secs seconds for TeamCity to finish initializing"
# too transitory to be idempotent
#while ! curl -sS "$url" | grep -q 'TeamCity is starting'; do
# although hard to miss this log as not a fast scroll, might break idempotence for re-running later if logs are cycled out of buffer
#while ! docker-compose -f "$config" logs --tail 50 teamcity-server | grep -q 'TeamCity initialized'; do
while ! docker-compose -f "$config" logs teamcity-server |
      grep -q -e 'Super user authentication token'; do
              #-e 'TeamCity initialized' # happens just before but checking for the super user token achieves both and protects against race condition
    tstamp 'waiting for TeamCity server to finish initializing'
    if [ $SECONDS -gt $max_secs ]; then
        die "TeamCity server failed to initialize within $max_secs seconds (perhaps you didn't trigger the UI to continue initialization?)"
    fi
    sleep 3
done
echo

superuser_token="$(docker-compose -f "$config" logs teamcity-server | grep -E -m1 -o 'Super user authentication token: [[:alnum:]]+' | tail -n1 | awk '{print $5}' || :)"

if [ -z "$superuser_token" ]; then
    timestamp "ERROR: Super user token not found in docker logs (maybe premature or late ie. logs were already cycled out of buffer?)"
    exit 1
fi

timestamp "TeamCity superuser token: $superuser_token"
timestamp "(this must be used with a blank username using basic auth if usingt the API)"
echo >&2

# can't use this with teamcity_api.sh because superuser token can only be used with a blank username, not as a bearer token
#export TEAMCITY_TOKEN="$superuser_token"

teamcity_user="${TEAMCITY_USER:-admin}"
teamcity_password="${TEAMCITY_PASSWORD:-admin}"

user_already_exists=0
timestamp "Checking teamcity user '$teamcity_user' exists"
if curl -sSL --fail -H 'Accept: application/json' -u ":$superuser_token" "$api/users" | jq -r '.user[].username' | grep -Fxq "$teamcity_user"; then
    timestamp "teamcity user '$teamcity_user' user already detected, skipping creation"
    user_already_exists=1
else
    timestamp "Creating teamcity user '$teamcity_user':"
    # can't use curl_auth.sh as there is no way to pass blank username through it, must end up using -u switch
    curl -L --fail \
         -u ":$superuser_token" \
         -H 'Accept: application/json' \
         -H "Content-Type: application/json" \
         -d "{ \"username\": \"$teamcity_user\", \"password\": \"$teamcity_password\"}" \
         "$api/users/"
         # Note: Unnecessary use of -X or --request, POST is already inferred.
         #-X POST \
    # no newline returned if error eg.
    #       Details: jetbrains.buildServer.server.rest.errors.BadRequestException: Cannot create user as user with the same username already exists, caused by: jetbrains.buildServer.users.DuplicateUserAccountException: The specified username 'admin' is already in use by some other user.
    #       Invalid request. Please check the request URL and data are correct.
    echo >&2
    echo >&2
fi

timestamp "Setting teamcity user '$teamcity_user' as system administrator:"
curl -sSL --fail -X PUT \
     -u ":$superuser_token" \
     -H 'Accept: application/json' \
     "$api/users/username:$teamcity_user/roles/SYSTEM_ADMIN/g/" > /dev/null
# no newline returned
echo >&2

api_token="$(curl -sSL \
                  -u ":$superuser_token" \
                  -H 'Accept: application/json' \
                  "$api/users/$teamcity_user/tokens" | \
             jq -r '.token[]' || :)"
if [ -n "$api_token" ]; then
    timestamp "Teamcity user '$teamcity_user' already has an API token, skipping token creation"
else
    timestamp "Creating API token for user '$teamcity_user'"
    api_token="$(curl -sSL -u ":$superuser_token" -H 'Accept: application/json' -X POST "$api/users/$teamcity_user/tokens/mytoken" --fail | jq -r '.value')"
    timestamp "here is your user API token, export this and then you can easily use teamcity_api.sh:"
    echo >&2
    echo "export TEAMCITY_URL=$server"
    export TEAMCITY_URL="$server"
    echo "export TEAMCITY_TOKEN=$api_token"
    export TEAMCITY_TOKEN="$api_token"
    echo >&2
fi

if [ "$user_already_exists" = 0 ]; then
    timestamp "Login here with username '$teamcity_user' and password: \$TEAMCITY_PASSWORD (default: admin):"
    echo >&2
    login_url="$server/login.html"
    timestamp "TeamCity Login page:  $login_url"
    echo >&2
    if is_mac; then
        timestamp "detected running on Mac, opening TeamCity Server URL for you automatically"
        echo >&2
        open "$login_url"
    fi
    echo >&2
    echo >&2
fi

# using our new teamcity API token, let's agents waiting to be authorized
unauthorized_agents="$("$srcdir/teamcity_api.sh" /agents?locator=authorized:false --fail | jq -r '.agent[].name')"

expected_agents="$(docker-compose -f "$config" config | awk '/AGENT_NAME:/ {print $2}')"

for agent in $unauthorized_agents; do
    if grep -Fxq "$agent" <<< "$expected_agents"; then
        timestamp "authorizing expected agent '$agent'"
        # needs -H 'Accept: text/plain' to override the default -H 'Accept: application/json' from teamcity_api.sh
        # otherwise gets 403 error and then even switching to -H 'Accept: text/plain' still breaks due to cookie jar behaviour,
        # so teamcity_api.sh now uses a unique cookie jar per script run and clears the cookie jar first
        teamcity_api.sh /agents/agent1/authorized -X PUT -d true -H 'Accept: text/plain' -H 'Content-Type: text/plain'
    else
        timestamp "WARNING: unauthorized agent '$agent' was not expected, not automatically authorizing"
    fi
done

# TODO: load pipeline