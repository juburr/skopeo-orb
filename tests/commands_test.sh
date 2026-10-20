#!/usr/bin/env bash
#
# Tests src/scripts/copy.sh, inspect.sh, list_tags.sh and logout.sh against a
# stand-in skopeo that records its arguments, one call per file, and answers
# the way skopeo does:
#
#   - each command builds exactly the skopeo arguments expected, with no empty
#     argument where an optional array is empty, even on bash < 4.4
#   - the boolean parameters become skopeo's flags, and copy's multi_arch its
#     --multi-arch
#   - extra_args split like shell words, and a $(...) or backtick reaches
#     nothing that runs it
#   - image names must start with a transport, such as docker://
#   - copy exports the digest skopeo wrote with --digestfile, shell-quoted, to
#     the variable digest_env_var names, and refuses anything that isn't one
#   - copy gives skopeo a policy that accepts any image only when the
#     executor has no signature policy and extra_args names none
#   - inspect reads the manifest first, exports its digest, and reads the
#     rest of the output for that digest, pinning a registry image to it
#   - inspect and list_tags save their output to output_file and tags_file,
#     and refuse extra_args that would change what inspect reads
#   - logout removes the credentials from the file login stored them in
#   - a failed skopeo fails the step and exports nothing
#   - missing or invalid values stop the step before skopeo runs
#
# The scripts run with the bash first on the PATH, so putting an older bash
# there checks it. The circleci CLI is stubbed when it isn't on the PATH.
#
# Run from a checkout:
#   bash <this file>

set -uo pipefail

# Find the repository root, the directory that holds src/@orb.yml.
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
until [[ -f "${ROOT}/src/@orb.yml" ]]; do
    if [[ "${ROOT}" == "/" ]]; then
        echo "FAIL: no src/@orb.yml above ${BASH_SOURCE[0]}"
        exit 1
    fi
    ROOT=$(dirname "${ROOT}")
done
SCRIPTS="${ROOT}/src/scripts"
SCRIPT_SKOPEO_LIB=$(cat "${SCRIPTS}/lib/skopeo.sh")
export SCRIPT_SKOPEO_LIB

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/bin" "${WORK}/job" "${WORK}/calls" "${WORK}/policies" "${WORK}/home"
printf '{"default":[{"type":"reject"}]}\n' > "${WORK}/policy.json"

# A stand-in for the circleci CLI, which only has to substitute nothing.
if ! command -v circleci > /dev/null 2>&1; then
    printf '#!/bin/sh\ncat\n' > "${WORK}/bin/circleci"
    chmod +x "${WORK}/bin/circleci"
fi

DIGEST="sha256:$(printf 'image' | sha256sum | awk '{ print $1 }')"

# Records each call's arguments, one per line, in calls/<n>, with the
# temporary files skopeo is given as <digestfile>, <manifest> and <policy>
# (whose content goes to policies/<n>). It writes
# SKOPEO_COPY_DIGEST to copy's --digestfile, prints a manifest for
# inspect --raw, SKOPEO_MANIFEST_DIGEST for manifest-digest, the image's name
# for any other inspect, and SKOPEO_TAGS as list-tags does. SKOPEO_FAIL names
# a subcommand that fails. skopeo --version, which is not recorded, reports
# SKOPEO_VERSION.
cat > "${WORK}/bin/skopeo" << EOF
#!/bin/bash
if [[ "\$1" == --version ]]; then
    echo "skopeo version \${SKOPEO_VERSION:-1.24.1}"
    exit 0
fi
n=\$(find "${WORK}/calls" -type f | wc -l)
digestfile="" previous="" raw=false
for arg in "\$@"; do
    if [[ "\${previous}" == --digestfile ]]; then
        digestfile=\${arg}
        printf '<digestfile>\n'
    elif [[ "\${previous}" == --policy && "\${arg}" == */tmp.*/policy.json ]]; then
        cp "\${arg}" "${WORK}/policies/\$((n + 1))"
        printf '<policy>\n'
    elif [[ "\$1" == manifest-digest && "\${arg}" == /* ]]; then
        printf '<manifest>\n'
    else
        printf '%s\n' "\${arg}"
    fi
    [[ "\${arg}" == --raw ]] && raw=true
    previous=\${arg}
done > "${WORK}/calls/\$((n + 1))"
if [[ "\$1" == "\${SKOPEO_FAIL:-}" ]]; then
    echo "skopeo \$1 failed" >&2
    exit 1
fi
case "\$1" in
    copy) printf '%s' "\${SKOPEO_COPY_DIGEST-${DIGEST}}" > "\${digestfile}" ;;
    manifest-digest) printf '%s\n' "\${SKOPEO_MANIFEST_DIGEST-${DIGEST}}" ;;
    inspect)
        if [[ "\${raw}" == true && " \$* " != *" --config "* ]]; then
            printf '{"schemaVersion":2,"manifests":[]}'
        else
            printf '{\n    "Name": "%s"\n}\n' "\${@: -1}"
        fi
        ;;
    list-tags)
        if [[ -n "\${SKOPEO_LIST_OUTPUT:-}" ]]; then
            printf '%s\n' "\${SKOPEO_LIST_OUTPUT}"
            exit 0
        fi
        printf '{\n    "Repository": "%s",\n    "Tags": [' "\${@: -1}"
        sep=""
        for tag in \${SKOPEO_TAGS-1.0.0 latest}; do
            printf '%s\n        "%s"' "\${sep}" "\${tag}"
            sep=","
        done
        if [[ -n "\${sep}" ]]; then printf '\n    ]\n}\n'; else printf ']\n}\n'; fi
        ;;
esac
EOF
chmod +x "${WORK}/bin/skopeo"

FAILURES=0
RC=0
OUTPUT=""

# run SCRIPT [VAR=value ...]: runs SCRIPT from the job directory with its
# parameters' defaults, overridden by the given assignments, and sets RC and
# OUTPUT. BASH_ENV and the recorded calls start empty.
run() {
    local script=$1
    shift
    rm -f "${WORK}/calls/"* "${WORK}/policies/"*
    : > "${WORK}/bash_env"
    OUTPUT=$(cd "${WORK}/job" && env -u REGISTRY_AUTH_FILE -u DOCKER_CONFIG -u XDG_CONFIG_HOME -u CONTAINERS_POLICY_JSON \
        PATH="${WORK}/bin:${PATH}" \
        HOME="${WORK}/home" \
        BASH_ENV="${WORK}/bash_env" \
        "${DEFAULTS[@]}" \
        ${@+"$@"} \
        bash "${SCRIPTS}/${script}" 2>&1)
    RC=$?
}

# check DESCRIPTION COMMAND...: records a failure, with the output, unless
# COMMAND succeeds.
check() {
    local description=$1 call
    shift
    if "$@"; then
        printf 'ok: %s\n' "${description}"
    else
        printf 'FAIL: %s\n' "${description}"
        printf '    | %s\n' "${OUTPUT}"
        for call in "${WORK}/calls/"*; do
            [[ -f "${call}" ]] || continue
            printf '    skopeo call %s: %s\n' "${call##*/}" "$(tr '\n' ' ' < "${call}")"
        done
        FAILURES=$((FAILURES + 1))
    fi
}
rc_is_zero() { [[ "${RC}" -eq 0 ]]; }
rc_is_nonzero() { [[ "${RC}" -ne 0 ]]; }
output_has() { grep -qF -- "$1" <<< "${OUTPUT}"; }
skopeo_not_run() { [[ -z "$(ls -A "${WORK}/calls")" ]]; }
calls_are() { [[ "$(find "${WORK}/calls" -type f | wc -l)" -eq "$1" ]]; }
nothing_exported() { [[ ! -s "${WORK}/bash_env" ]]; }
# call_is N ARG...: call N got exactly these arguments.
call_is() {
    local n=$1
    shift
    [[ -f "${WORK}/calls/${n}" && "$(cat "${WORK}/calls/${n}")" == "$(printf '%s\n' "$@")" ]]
}
# exported NAME VALUE: a clean shell that sources BASH_ENV sees NAME=VALUE.
exported() {
    # shellcheck disable=SC2016 # expanded by the clean shell, not here
    [[ "$(env -i bash -c 'source "$1"; printf "%s" "${!2}"' _ "${WORK}/bash_env" "$1")" == "$2" ]]
}
# file_is PATH CONTENT: PATH holds exactly CONTENT.
file_is() { [[ -f "$1" && "$(cat "$1")" == "$2" ]]; }

SOURCE="docker://ghcr.io/myorg/app:1.0.0"
DESTINATION="docker://registry.example:5000/app:1.0.0"

# --- copy
# HOME has a policy.json, so these runs don't depend on whether this machine
# has one.
mkdir -p "${WORK}/home/.config/containers"
cp "${WORK}/policy.json" "${WORK}/home/.config/containers/policy.json"
DEFAULTS=(PARAM_SOURCE="${SOURCE}" PARAM_DESTINATION="${DESTINATION}" PARAM_MULTI_ARCH="all"
    PARAM_SRC_TLS_VERIFY="1" PARAM_DEST_TLS_VERIFY="1" PARAM_EXTRA_ARGS="" PARAM_DIGEST_ENV_VAR="SKOPEO_DIGEST")

run copy.sh
check "copy succeeds" rc_is_zero
check "copy copies every platform, asks for the digest and requires TLS on both sides" \
    call_is 1 copy --multi-arch all --digestfile "<digestfile>" --src-tls-verify=true --dest-tls-verify=true \
    -- "${SOURCE}" "${DESTINATION}"
check "copy uses the policy.json in HOME" output_has "Signature policy: ${WORK}/home/.config/containers/policy.json"
check "copy exports the digest skopeo wrote" exported SKOPEO_DIGEST "${DIGEST}"

run copy.sh PARAM_MULTI_ARCH="system" PARAM_SRC_TLS_VERIFY="0" PARAM_DEST_TLS_VERIFY="0" \
    PARAM_EXTRA_ARGS='--preserve-digests --override-arch "arm64"' PARAM_DIGEST_ENV_VAR="APP_DIGEST"
check "copy with every option succeeds" rc_is_zero
check "copy passes multi_arch, both TLS settings and the extra arguments" \
    call_is 1 copy --multi-arch system --digestfile "<digestfile>" --src-tls-verify=false --dest-tls-verify=false \
    --preserve-digests --override-arch arm64 -- "${SOURCE}" "${DESTINATION}"
check "copy exports to the variable digest_env_var names" exported APP_DIGEST "${DIGEST}"

run copy.sh PARAM_EXTRA_ARGS="--digestfile /tmp/elsewhere"
check "copy refuses --digestfile in extra_args" rc_is_nonzero
check "copy says it writes the digest itself" output_has "ERROR: extra_args can't set --digestfile"
check "copy does not run skopeo with --digestfile in extra_args" skopeo_not_run

run copy.sh PARAM_EXTRA_ARGS="--policy /etc/custom-policy.json" CONTAINERS_POLICY_JSON="${WORK}/env-policy.json"
check "copy leaves a --policy in extra_args to skopeo" \
    call_is 1 copy --multi-arch all --digestfile "<digestfile>" --src-tls-verify=true --dest-tls-verify=true \
    --policy /etc/custom-policy.json -- "${SOURCE}" "${DESTINATION}"
check "copy says the policy comes from extra_args" output_has "Signature policy: from extra_args"

run copy.sh PARAM_EXTRA_ARGS="--insecure-policy"
check "copy adds no policy to --insecure-policy" \
    call_is 1 copy --multi-arch all --digestfile "<digestfile>" --src-tls-verify=true --dest-tls-verify=true \
    --insecure-policy -- "${SOURCE}" "${DESTINATION}"
check "copy says --insecure-policy comes from extra_args" output_has "Signature policy: from extra_args"

run copy.sh PARAM_EXTRA_ARGS="--insecure-policy=False --insecure-policy=1"
check "copy takes the last --insecure-policy" output_has "Signature policy: from extra_args"

run copy.sh PARAM_EXTRA_ARGS="--insecure-policy --insecure-policy=false"
check "copy looks for a policy when --insecure-policy is false" \
    output_has "Signature policy: ${WORK}/home/.config/containers/policy.json"

# Older releases, such as 1.14.0, don't read CONTAINERS_POLICY_JSON, so copy passes it.
run copy.sh CONTAINERS_POLICY_JSON="${WORK}/env-policy.json"
check "copy passes CONTAINERS_POLICY_JSON as --policy" \
    call_is 1 copy --multi-arch all --digestfile "<digestfile>" --policy "${WORK}/env-policy.json" \
    --src-tls-verify=true --dest-tls-verify=true -- "${SOURCE}" "${DESTINATION}"
check "copy says the policy comes from CONTAINERS_POLICY_JSON" output_has "(CONTAINERS_POLICY_JSON)"

# skopeo 1.23.0 and later read the user's policy from XDG_CONFIG_HOME when it
# is set; earlier releases only from HOME.
mkdir -p "${WORK}/xdg/containers" "${WORK}/xdg-empty"
cp "${WORK}/policy.json" "${WORK}/xdg/containers/policy.json"
run copy.sh XDG_CONFIG_HOME="${WORK}/xdg"
check "copy uses the policy.json in XDG_CONFIG_HOME" output_has "Signature policy: ${WORK}/xdg/containers/policy.json"
run copy.sh XDG_CONFIG_HOME="${WORK}/xdg" SKOPEO_VERSION="1.22.3"
check "copy before 1.23.0 uses the policy.json in HOME, not XDG_CONFIG_HOME" \
    output_has "Signature policy: ${WORK}/home/.config/containers/policy.json"

# no_policy_run NAME [VAR=value ...]: runs copy.sh where skopeo finds no
# policy and checks that copy gives it one that accepts any image.
no_policy_run() {
    local name=$1
    shift
    run copy.sh ${@+"$@"}
    check "${name} succeeds" rc_is_zero
    check "${name} gives skopeo a policy" \
        call_is 1 copy --multi-arch all --digestfile "<digestfile>" --policy "<policy>" \
        --src-tls-verify=true --dest-tls-verify=true -- "${SOURCE}" "${DESTINATION}"
    check "${name}: the policy accepts any image" file_is "${WORK}/policies/1" '{"default":[{"type":"insecureAcceptAnything"}]}'
    check "${name} says the policy accepts any image" output_has "Signature policy: none on this executor"
}
if [[ -e /etc/containers/policy.json || -e /usr/share/containers/policy.json ]]; then
    echo "skip: this machine has a system policy.json, so the copies without one were not checked"
else
    no_policy_run "copy with XDG_CONFIG_HOME set and a policy in HOME only" XDG_CONFIG_HOME="${WORK}/xdg-empty"
    rm -f "${WORK}/home/.config/containers/policy.json"
    no_policy_run "copy before 1.23.0 with a policy in XDG_CONFIG_HOME only" \
        XDG_CONFIG_HOME="${WORK}/xdg" SKOPEO_VERSION="1.22.3"
    no_policy_run "copy without a policy"

    run copy.sh PARAM_EXTRA_ARGS="--insecure-policy=false"
    check "copy gives skopeo a policy with --insecure-policy=false and no policy" \
        call_is 1 copy --multi-arch all --digestfile "<digestfile>" --policy "<policy>" \
        --src-tls-verify=true --dest-tls-verify=true --insecure-policy=false -- "${SOURCE}" "${DESTINATION}"
    check "copy says that policy accepts any image" output_has "Signature policy: none on this executor"
fi
cp "${WORK}/policy.json" "${WORK}/home/.config/containers/policy.json"

run copy.sh SKOPEO_COPY_DIGEST="sha512:$(printf 'image' | sha512sum | awk '{ print $1 }')"
check "copy accepts a sha512 digest" rc_is_zero

# shellcheck disable=SC2016 # the command substitution must reach the script unexpanded
run copy.sh PARAM_EXTRA_ARGS='--retry-times $(touch pwned)'
check "copy refuses a command substitution in extra_args" rc_is_nonzero
check "copy explains the command substitution" output_has "ERROR: extra_args could not be split into arguments"
check "copy runs nothing from extra_args" test ! -e "${WORK}/job/pwned"
check "copy does not run skopeo with unusable extra_args" skopeo_not_run

run copy.sh PARAM_SOURCE="ghcr.io/myorg/app:1.0.0"
check "copy refuses a source without a transport" rc_is_nonzero
check "copy suggests the transport" output_has "ERROR: source must start with a transport, such as docker://ghcr.io/myorg/app:1.0.0"
check "copy does not run skopeo without a transport" skopeo_not_run

run copy.sh PARAM_DESTINATION=""
check "copy requires a destination" rc_is_nonzero
check "copy says destination is required" output_has "ERROR: destination is required"

run copy.sh PARAM_MULTI_ARCH="every"
check "copy rejects an unknown multi_arch" rc_is_nonzero
check "copy names multi_arch in the error" output_has "ERROR: multi_arch must be system, all or index-only"

run copy.sh PARAM_DEST_TLS_VERIFY="maybe"
check "copy rejects a dest_tls_verify that isn't a boolean" rc_is_nonzero
check "copy names dest_tls_verify in the error" output_has "ERROR: dest_tls_verify must be true or false"

run copy.sh PARAM_DIGEST_ENV_VAR="1BAD"
check "copy refuses a digest_env_var that can't name a variable" rc_is_nonzero
check "copy does not run skopeo with a bad variable name" skopeo_not_run

run copy.sh SKOPEO_FAIL=copy
check "copy fails when skopeo copy fails" rc_is_nonzero
check "copy exports nothing when skopeo fails" nothing_exported

run copy.sh SKOPEO_COPY_DIGEST="not-a-digest"
check "copy refuses a digest file that holds no digest" rc_is_nonzero
check "copy says what skopeo wrote" output_has "ERROR: skopeo copy wrote 'not-a-digest' as the digest"
check "copy exports nothing for an unusable digest" nothing_exported

run copy.sh BASH_ENV=""
check "copy succeeds without BASH_ENV" rc_is_zero
check "copy warns that nothing was exported" output_has "WARN: BASH_ENV is not set"

run copy.sh SCRIPT_SKOPEO_LIB=""
check "copy fails without the shared helpers" rc_is_nonzero
check "copy says the shared helpers are missing" output_has "ERROR: The shared helpers were not loaded"

# --- inspect
IMAGE="docker://registry.example:5000/myorg/app:1.0.0"
PINNED="docker://registry.example:5000/myorg/app@${DIGEST}"
DEFAULTS=(PARAM_IMAGE="${IMAGE}" PARAM_RAW="0" PARAM_CONFIG="0" PARAM_NO_TAGS="0" PARAM_TLS_VERIFY="1"
    PARAM_OUTPUT_FILE="" PARAM_EXTRA_ARGS="" PARAM_DIGEST_ENV_VAR="SKOPEO_DIGEST")

run inspect.sh
check "inspect succeeds" rc_is_zero
check "inspect reads the manifest first, requiring TLS" call_is 1 inspect --raw --tls-verify=true -- "${IMAGE}"
check "inspect takes the digest of that manifest" call_is 2 manifest-digest -- "<manifest>"
check "inspect reads the rest for that digest" call_is 3 inspect --tls-verify=true -- "${PINNED}"
check "inspect prints the output" output_has "\"Name\": \"${PINNED}\""
check "inspect exports the digest" exported SKOPEO_DIGEST "${DIGEST}"

run inspect.sh PARAM_RAW="1"
check "inspect with raw succeeds" rc_is_zero
check "inspect with raw needs no second inspect" calls_are 2
check "inspect with raw prints the manifest" output_has '{"schemaVersion":2,"manifests":[]}'

run inspect.sh PARAM_CONFIG="1" PARAM_NO_TAGS="1"
check "inspect with config reads the configuration, which lists no tags" call_is 3 inspect --config --tls-verify=true -- "${PINNED}"

run inspect.sh PARAM_RAW="1" PARAM_CONFIG="1"
check "inspect with raw and config reads the configuration as stored" call_is 3 inspect --raw --config --tls-verify=true -- "${PINNED}"

run inspect.sh PARAM_NO_TAGS="1" PARAM_TLS_VERIFY="0" PARAM_EXTRA_ARGS="--override-arch arm64" \
    PARAM_DIGEST_ENV_VAR="APP_DIGEST"
check "inspect with every option succeeds" rc_is_zero
check "inspect passes TLS and the extra arguments to the manifest read" \
    call_is 1 inspect --raw --tls-verify=false --override-arch arm64 -- "${IMAGE}"
check "inspect passes no_tags, TLS and the extra arguments to the second read" \
    call_is 3 inspect --no-tags --tls-verify=false --override-arch arm64 -- "${PINNED}"
check "inspect exports to the variable digest_env_var names" exported APP_DIGEST "${DIGEST}"

# pinned IMAGE: inspect's second read names IMAGE pinned to DIGEST as this.
for pair in \
    "docker://localhost:5000/app:1|docker://localhost:5000/app@${DIGEST}" \
    "docker://localhost:5000/app|docker://localhost:5000/app@${DIGEST}" \
    "docker://alpine:3.20|docker://alpine@${DIGEST}" \
    "docker://ghcr.io/a/b@sha256:0000|docker://ghcr.io/a/b@${DIGEST}" \
    "docker://ghcr.io/a/b:1@sha256:0000|docker://ghcr.io/a/b@${DIGEST}" \
    "oci:/tmp/layout:1.0|oci:/tmp/layout:1.0"; do
    run inspect.sh PARAM_IMAGE="${pair%%|*}"
    check "inspect reads ${pair%%|*} as ${pair#*|}" call_is 3 inspect --tls-verify=true -- "${pair#*|}"
done

run inspect.sh PARAM_OUTPUT_FILE="~/out/inspect.json"
check "inspect with output_file succeeds" rc_is_zero
check "inspect saves the output to output_file, expanding ~/" \
    file_is "${WORK}/home/out/inspect.json" "$(printf '{\n    "Name": "%s"\n}' "${PINNED}")"

run inspect.sh PARAM_RAW="1" PARAM_OUTPUT_FILE="manifest.json"
check "inspect saves the raw manifest to output_file" file_is "${WORK}/job/manifest.json" '{"schemaVersion":2,"manifests":[]}'

for flag in "--format {{.Digest}}" "-f {{.Name}}" "--format={{.Digest}}" "--raw" "--config=true"; do
    run inspect.sh PARAM_EXTRA_ARGS="${flag}"
    check "inspect refuses ${flag%% *} in extra_args" rc_is_nonzero
    check "inspect does not run skopeo with ${flag%% *} in extra_args" skopeo_not_run
done
check "inspect names the parameter to use instead" output_has "use the config parameter instead"

run inspect.sh PARAM_OUTPUT_FILE="~/inspect.json" HOME=""
check "inspect refuses output_file under ~/ without HOME" rc_is_nonzero
check "inspect says HOME is not set" output_has "ERROR: HOME is not set"

run inspect.sh SKOPEO_MANIFEST_DIGEST="nonsense"
check "inspect refuses a digest that isn't one" rc_is_nonzero
check "inspect says what manifest-digest printed" output_has "ERROR: skopeo manifest-digest printed 'nonsense'"
check "inspect exports nothing for an unusable digest" nothing_exported

run inspect.sh SKOPEO_FAIL=inspect
check "inspect fails when skopeo inspect fails" rc_is_nonzero
check "inspect exports nothing when skopeo fails" nothing_exported

run inspect.sh PARAM_IMAGE="registry.example/app:1"
check "inspect refuses an image without a transport" rc_is_nonzero
check "inspect does not run skopeo without a transport" skopeo_not_run

run inspect.sh PARAM_RAW="yes"
check "inspect rejects a raw that isn't a boolean" rc_is_nonzero

# --- list_tags
REPOSITORY="docker://registry.example:5000/myorg/app"
DEFAULTS=(PARAM_REPOSITORY="${REPOSITORY}" PARAM_TLS_VERIFY="1" PARAM_TAGS_FILE="" PARAM_EXTRA_ARGS="")

run list_tags.sh
check "list_tags succeeds" rc_is_zero
check "list_tags lists the repository's tags, requiring TLS" call_is 1 list-tags --tls-verify=true -- "${REPOSITORY}"
check "list_tags prints the tags" output_has '"latest"'

run list_tags.sh PARAM_TLS_VERIFY="0" PARAM_EXTRA_ARGS="--retry-times 2" PARAM_TAGS_FILE="~/tags/all.txt"
check "list_tags with every option succeeds" rc_is_zero
check "list_tags passes TLS and the extra arguments" \
    call_is 1 list-tags --tls-verify=false --retry-times 2 -- "${REPOSITORY}"
check "list_tags writes the tags to tags_file, one per line, expanding ~/" \
    file_is "${WORK}/home/tags/all.txt" $'1.0.0\nlatest'

run list_tags.sh PARAM_TAGS_FILE="tags.txt" SKOPEO_TAGS="only"
check "list_tags writes a single tag" file_is "${WORK}/job/tags.txt" "only"

run list_tags.sh PARAM_TAGS_FILE="tags.txt" SKOPEO_TAGS=""
check "list_tags succeeds for a repository without tags" rc_is_zero
check "list_tags writes an empty tags_file for it" file_is "${WORK}/job/tags.txt" ""

run list_tags.sh PARAM_TAGS_FILE="tags.txt" SKOPEO_LIST_OUTPUT=$'{\n    "Repository": "r",\n    "Tags": null\n}'
check "list_tags reads a null tag list as no tags" file_is "${WORK}/job/tags.txt" ""

run list_tags.sh PARAM_TAGS_FILE="tags.txt" SKOPEO_LIST_OUTPUT=$'{\n "Repository": "r",\n "Tags": [\n  "a",\n  "b"\n ]\n}'
check "list_tags reads tags indented another way" file_is "${WORK}/job/tags.txt" $'a\nb'

run list_tags.sh PARAM_TAGS_FILE="bad.txt" SKOPEO_LIST_OUTPUT=$'{\n    "Repository": "r",\n    "Tags": [\n        "ok",\n        "not a tag"\n    ]\n}'
check "list_tags refuses a list it can't read" rc_is_nonzero
check "list_tags says it could not read the tags" output_has "ERROR: Could not read the tags"
check "list_tags writes no tags_file then" test ! -e "${WORK}/job/bad.txt"

run list_tags.sh PARAM_REPOSITORY="docker-archive:app.tar" PARAM_TAGS_FILE="tags.txt"
check "list_tags refuses tags_file for an archive" rc_is_nonzero
check "list_tags says tags_file needs a registry" output_has "ERROR: tags_file needs a registry repository"

run list_tags.sh PARAM_REPOSITORY="docker-archive:app.tar"
check "list_tags lists an archive without tags_file" call_is 1 list-tags --tls-verify=true -- "docker-archive:app.tar"

run list_tags.sh PARAM_TAGS_FILE="~/tags.txt" HOME=""
check "list_tags refuses tags_file under ~/ without HOME" rc_is_nonzero

run list_tags.sh SKOPEO_FAIL=list-tags
check "list_tags fails when skopeo list-tags fails" rc_is_nonzero

run list_tags.sh PARAM_REPOSITORY="registry.example/app"
check "list_tags refuses a repository without a transport" rc_is_nonzero
check "list_tags names repository in the error" output_has "ERROR: repository must start with a transport"

# --- logout
DEFAULTS=(PARAM_REGISTRY="registry.example:5000")

run logout.sh
check "logout succeeds" rc_is_zero
check "logout removes the credentials from Docker's config file" \
    call_is 1 logout --compat-auth-file "${WORK}/home/.docker/config.json" -- "registry.example:5000"

run logout.sh DOCKER_CONFIG="${WORK}/docker"
check "logout uses the config file in DOCKER_CONFIG" \
    call_is 1 logout --compat-auth-file "${WORK}/docker/config.json" -- "registry.example:5000"

run logout.sh REGISTRY_AUTH_FILE="${WORK}/auth.json"
check "logout leaves REGISTRY_AUTH_FILE to skopeo" call_is 1 logout -- "registry.example:5000"

run logout.sh PARAM_REGISTRY="https://registry.example"
check "logout refuses a registry given as a URL" rc_is_nonzero
check "logout does not run skopeo for a URL" skopeo_not_run

run logout.sh PARAM_REGISTRY=""
check "logout requires a registry" rc_is_nonzero
check "logout says registry is required" output_has "ERROR: registry is required"

run logout.sh SKOPEO_FAIL=logout
check "logout fails when skopeo logout fails" rc_is_nonzero

# --- skopeo_export
# The digests above need no quoting, so the helper gets a value that does.
# shellcheck disable=SC2016 # the command substitution must reach skopeo_export unexpanded
HOSTILE='two words $(touch '"${WORK}"'/job/exported-pwned) "quoted"'
: > "${WORK}/bash_env"
OUTPUT=$(BASH_ENV="${WORK}/bash_env" bash -c 'set -euo pipefail; eval "$1"; skopeo_export HOSTILE_VALUE "$2"' _ \
    "${SCRIPT_SKOPEO_LIB}" "${HOSTILE}" 2>&1)
RC=$?
check "skopeo_export writes the value" rc_is_zero
check "skopeo_export shell-quotes the value" exported HOSTILE_VALUE "${HOSTILE}"
check "skopeo_export runs nothing in the value" test ! -e "${WORK}/job/exported-pwned"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All copy, inspect, list_tags and logout tests passed."
