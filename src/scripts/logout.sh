#!/bin/bash
#
# Removes registry credentials for the logout command, with skopeo logout,
# from the file the login command stored them in.

set -euo pipefail

if [[ -z "${SCRIPT_SKOPEO_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SKOPEO_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SKOPEO_LIB}"

REGISTRY=$(skopeo_subst "${PARAM_REGISTRY}")

skopeo_registry "${REGISTRY}"
skopeo_require

echo "Removing the credentials for ${REGISTRY} with skopeo..."
skopeo_auth_args
LOGOUT_ARGS=(logout)
LOGOUT_ARGS+=(${SKOPEO_AUTH_ARGS[@]+"${SKOPEO_AUTH_ARGS[@]}"})
# After --, a registry that starts with "-" is not read as a flag.
LOGOUT_ARGS+=(-- "${REGISTRY}")
skopeo "${LOGOUT_ARGS[@]}"
