#!/bin/bash

##########################################################
# freshDock is a BASH script designed to automatically   #
# update Docker containers and cleanup after itself      #
# when docker-compose.yml is used to define the          #
# configuration. Currently, it only supports             #
# notifications via Gotify but it is entirely possible   #
# to change one cURL command to send to another API.     #
# If you use docker-compose and your needs are simple,   #
# then freshDock might be perfect for you!               #
#                                                        #
#             -----------------------------              #
#                                                        #
#   freshDock is distributed under Apache License 2.0.   #
#                                                        #
#       Copyright (c) 2022 - Present amanshallow.        #
##########################################################

# List of commands that must be present on PATH.
readonly DEPENDENCIES=(
    "wc"
    "jq"
    "curl"
    "grep"
    "tee"
    "docker"
    "docker-compose"
)

# Directory where the script is running from.
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

# Log file.
readonly LOG="$SCRIPT_DIR/freshDock.log"

# Gotify client token.
# readonly GOTIFY_TOKEN=""

# Gotify domain name (gotify.example.com).
# readonly GOTIFY_DOMAIN=""

# Message shown when Docker throttles.
readonly FAIL_MESSAGE="Docker API is throttling. Try again later."

# Does some pre-checks before running the script to ensure
# appropriate dependencies and other things are installed.
pre_checks() {
    # Check if root user.
    if [ "$(id -u)" != 0 ]; then
        echo "freshDock must be run as root."
        exit 1
    fi

    # Make sure Bash version is above 4.
    # Required for associate arrays used for lookup map.
    if [ "${BASH_VERSION:0:1}" -lt 4 ]; then
        echo "freshDock requires Bash 4 or greater."
        exit 1
    fi

    # Check for dependencies.
    for dependency in "${DEPENDENCIES[@]}"; do
        if ! command -v "$dependency" &>/dev/null; then
            echo "$dependency is required but not installed."
            exit 1
        fi
    done
}

# Prepare the log.
prepare_log() {
    # Create the log if it doesn't exist.
    touch "$LOG"

    # Reset the log once its greater than 30K bytes.
    if [ "$(wc -c <"$LOG")" -gt 30000 ]; then
        echo >"$LOG"
    fi

    {
        printf "\n------------------------\n"
        printf "[ Time     ]: %s\n" "$(date)"
    } >>"$LOG"
}

# Gets the auth token from Docker repository.
get_auth_token() {
    local endpoint token
    endpoint="https://auth.docker.io/token?scope=repository:$image:pull&service=registry.docker.io"

    # Get auth token.
    token=$(curl -fsSL -X GET --retry 3 --retry-max-time 15 "$endpoint" | jq -r '.token')

    [ -z "$token" ] && return 1

    # Return token back to caller.
    echo "$token"
}

: '
Fetches the remote digest and returns true if digests
do not match aka an update is needed.
'
is_update_needed() {
    local remote_digest endpoint local_digest image
    image="$img" # Avoid changing caller's value.

    # Get the local image hash.
    local_digest=${imgToHash[$image]}

    # Official images require 'library/' prepended to them.
    [[ "$image" != *"/"* ]] && image="library/$image"

    # If tag is missing, use latest instead.
    [ -z "$tag" ] && tag="latest"

    endpoint="https://registry.hub.docker.com/v2/$image/manifests/$tag"
    token=$(get_auth_token 2>>"$LOG")

    response=$(curl -fsSL -X GET --retry 3 --retry-max-time 15 \
        -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
        -H "Authorization: Bearer $token" \
        -w "\n%{http_code}" "$endpoint")

    http_code=$(tail -n1 <<<"$response")

    # Docker API implements throttling. Check and notify.
    if [ "$http_code" == 429 ]; then
        notify "$FAIL_MESSAGE" 5 2>>"$LOG"
        printf "%s\n" "$FAIL_MESSAGE" | tee -a "$LOG"
        exit 1
    fi

    remote_digest=$(sed '$ d' <<<"$response" | jq -r '.config.digest')

    # If remote digest is null, curl failed for other reasons.
    [ -z "$remote_digest" ] && return 1

    # A different digest indicates an update is needed.
    [ "$remote_digest" != "$local_digest" ]
}

: '
Send a notification via Gotify.
Expects two arguments: message and priority.
'
notify() {
    # Skip notification if constants not set.
    if [ -z "$GOTIFY_DOMAIN" ] || [ -z "$GOTIFY_TOKEN" ]; then
        echo "Skipping notification. Set constants if using Gotify." | tee -a "$LOG"
        return
    fi

    # Full Gotify endpoint to send notifications.
    local endpoint="https://$GOTIFY_DOMAIN/message?token=$GOTIFY_TOKEN"

    # Send the notification.
    curl -fsSL -X POST --connect-timeout 5 --retry 5 -o /dev/null "$endpoint" \
        -F "title=freshDock" \
        -F "message=$1" \
        -F "priority=$2"
}

: '
Builds two lookup maps. One for image name --> docker-compose.yml directory,
and another for image name --> image digest. Returns an array of image 
names as well. Relies on "docker inspect" and "jq" for the heavy lifting.
'
build_image_id_map() {
    local img imageAndID compose_path
    local -n imgToPath_ref="$1"
    local -n images_ref="$2"
    local -n imgToHash_ref="$3"

    # Get all the running container IDs and image names.
    imageAndID=$(/usr/bin/docker ps --no-trunc | awk '{print $1,$2}' | grep -v "CONTAINER ID")

    # Must set IFS prior to for loop to get entire line.
    IFS=$'\n'

    # Build the lookup maps and an array with image names.
    for imgTag in $imageAndID; do
        # Parse the container's ID.
        id=$(echo "$imgTag" | awk '{print $1}')

        # Parse the container's image name.
        img=$(echo "$imgTag" | awk '{print $2}' | awk -F: '{print $1}')

        # Find the docker-compose path.
        compose_path=$(/usr/bin/docker inspect "$id" | jq -r '.[] | .Config.Labels | ."com.docker.compose.project.working_dir"')

        # Find the current image digest.
        imageHash=$(/usr/bin/docker inspect "$id" | jq -r '.[] | .Image')

        # Assign the docker-compose path for the image name. Shellcheck false flag.
        # shellcheck disable=SC2034
        imgToPath_ref[$img]="$compose_path"

        # Assign the image hash for the image name. Shellcheck false flag.
        # shellcheck disable=SC2034
        imgToHash_ref[$img]="$imageHash"

        # Append the full image name with tag.
        images_ref+=("$(echo "$imgTag" | awk '{print $2}')")
    done

    # Unset Internal Field Separator.
    unset IFS
}

# Updates the images and rebuild containers if necessary.
update() {
    local imgTag updated
    declare -a images
    declare -A imgToPath imgToHash

    # Retrieve the lookup map and image array.
    build_image_id_map imgToPath images imgToHash 2>>"$LOG"

    # Iterate over all images and perform updates if necessary.
    for imgTag in "${images[@]}"; do
        local img tag

        # Split the string to get image and optionally a tag.
        img=$(echo "$imgTag" | awk -F: '{print $1}')
        tag=$(echo "$imgTag" | awk -F: '{print $2}')

        printf "[ Checking ]: [ %s ]\n" "$img" | tee -a "$LOG"

        if is_update_needed; then
            printf "[ Info     ]: Updated image available.\n" | tee -a "$LOG"

            # Change to docker-compose.yml directory.
            cd "${imgToPath[$img]}" 2>>"$LOG" || exit 1

            # Update the containers with docker-compose and send a notification with Gotify.
            if /usr/local/bin/docker-compose pull && /usr/local/bin/docker-compose up -d; then
                updated=true
                notify "[ $img ] was updated to latest!" 2 2>>"$LOG"
                printf "[ Info     ]: Container updated.\n" | tee -a "$LOG"
            else
                notify "[ $img ] failed to update! Please investigate manually." 5 2>>"$LOG"
                printf "[ Error    ]: Couldn't update container. Something went wrong.\n" | tee -a "$LOG"
            fi
        fi
    done

    # Cleanup.
    if [ "$updated" == true ]; then
        printf "[ Info     ]: Cleaning up.\n" | tee -a "$LOG"
        /usr/bin/docker system prune -af
    fi
}

pre_checks
prepare_log
update
