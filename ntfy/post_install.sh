#!/bin/bash
set -e
SERVICES_USER="${MAIN_NODE_HOSTNAME_LOWERCASE}_services"
SERVICES_TOPIC="${SERVICES_USER}_*"
echo "NOTE: You may need to create a user, generate a token, and replace it in VARS.sh. Example of helpful commands (run in the container):

ntfy user add $USER
ntfy access $USER \"*\" rw
ntfy user change-role $USER admin

ntfy user $SERVICES_USER
ntfy access $SERVICES_USER \"$SERVICES_TOPIC\" rw
ntfy token_add $SERVICES_USER"