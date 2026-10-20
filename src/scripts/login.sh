#!/bin/bash
#
# Logs in to a registry for the login command, with skopeo login, which checks
# the credentials with the registry before storing them. They are stored in
# Docker's config.json, where later skopeo, docker, crane and oras commands
# read them, or in REGISTRY_AUTH_FILE when it is set.

set -euo pipefail
# A job can turn xtrace on for every step (SHELLOPTS, or set -x in $BASH_ENV), and it would print the password.
set +o xtrace

if [[ -z "${SCRIPT_SKOPEO_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SKOPEO_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SKOPEO_LIB}"

REGISTRY=$(skopeo_subst "${PARAM_REGISTRY}")
TLS_VERIFY=$(skopeo_bool tls_verify "${PARAM_TLS_VERIFY}")
skopeo_env_var_name username "${PARAM_USERNAME}"
skopeo_env_var_name password "${PARAM_PASSWORD}"
USERNAME=${!PARAM_USERNAME:-}
PASSWORD=${!PARAM_PASSWORD:-}

# Removes the credentials from this shell when the step ends, whatever its
# outcome.
cleanup_secrets() {
    unset PASSWORD USERNAME
}
trap cleanup_secrets EXIT

skopeo_registry "${REGISTRY}"
if [[ -z "${USERNAME}" ]]; then
    echo "ERROR: The ${PARAM_USERNAME} environment variable, which username names, is empty or unset." >&2
    echo "  Set it in a context or project environment variable, or pass the name of another variable as username." >&2
    exit 1
fi
if [[ -z "${PASSWORD}" ]]; then
    echo "ERROR: The ${PARAM_PASSWORD} environment variable, which password names, is empty or unset." >&2
    echo "  Set it in a context or project environment variable, or pass the name of another variable as password." >&2
    exit 1
fi
skopeo_require

echo "Logging in to ${REGISTRY} with skopeo..."
echo "  Username: from ${PARAM_USERNAME}"
echo "  Password: from ${PARAM_PASSWORD}"
echo "  TLS verify: ${TLS_VERIFY}"
skopeo_auth_args

LOGIN_ARGS=(login --username "${USERNAME}" --password-stdin)
if [[ "${TLS_VERIFY}" == false ]]; then
    LOGIN_ARGS+=(--tls-verify=false)
fi
LOGIN_ARGS+=(${SKOPEO_AUTH_ARGS[@]+"${SKOPEO_AUTH_ARGS[@]}"})
# After --, a registry that starts with "-" is not read as a flag.
LOGIN_ARGS+=(-- "${REGISTRY}")

# The password goes on stdin, never on the command line. printf, not echo:
# echo would take a password of -n or -e as its own option.
printf '%s\n' "${PASSWORD}" | skopeo "${LOGIN_ARGS[@]}"
