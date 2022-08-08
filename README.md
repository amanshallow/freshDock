# freshDock

freshDock is a BASH script designed to automatically update Docker containers when docker-compose.yml is used for configuration. It uses many of the features available in Docker CLI (docker inspect) to locate the relevant information needed to update images and rebuild containers with docker-compose. Communicates with the [Docker Registry HTTP API V2](https://docs.docker.com/registry/spec/api/) to find the remote digest for a given `image:tag (ubuntu:latest)` and updates only if local digest differs from remote.

## Notifications

Currently [Gotify](https://github.com/gotify/server) is the only supported means of notification but it can be changed to another by manipulating the respective `cURL` command.

## Required constants (Gotify)

The following constants can be set at top of the script if Gotify is to be used for notifications:

|     Name      | Description                                           |
| :-----------: | ----------------------------------------------------- |
| GOTIFY_TOKEN  | Client token required for authenticating with Gotify. |
| GOTIFY_DOMAIN | Domain name only where Gotify is hosted.              |

## Logging

freshDock outputs errors to `freshDock.log` located in the script's directory.
