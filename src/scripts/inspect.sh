#!/bin/bash
#
# Inspects an image for the inspect command, with skopeo inspect, without
# pulling it. Prints the result, can save it to a file, and exports the digest
# of the manifest the image name points to.

set -euo pipefail

if [[ -z "${SCRIPT_SKOPEO_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SKOPEO_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SKOPEO_LIB}"

IMAGE=$(skopeo_subst "${PARAM_IMAGE}")
RAW=$(skopeo_bool raw "${PARAM_RAW}")
CONFIG=$(skopeo_bool config "${PARAM_CONFIG}")
NO_TAGS=$(skopeo_bool no_tags "${PARAM_NO_TAGS}")
TLS_VERIFY=$(skopeo_bool tls_verify "${PARAM_TLS_VERIFY}")
OUTPUT_FILE=$(skopeo_subst "${PARAM_OUTPUT_FILE}")
EXTRA_ARGS=$(skopeo_subst "${PARAM_EXTRA_ARGS}")
skopeo_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"

skopeo_image image "${IMAGE}"
if [[ "${OUTPUT_FILE}" == \~/* ]]; then
    if [[ -z "${HOME:-}" ]]; then
        echo "ERROR: HOME is not set, so output_file can't start with ~/." >&2
        exit 1
    fi
    OUTPUT_FILE="${HOME}${OUTPUT_FILE:1}"
fi
skopeo_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${SKOPEO_WORDS[@]+"${SKOPEO_WORDS[@]}"})
# The manifest read takes extra_args too, and these would change what it
# reads, so they are parameters instead.
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        --format | --format=* | -f*)
            echo "ERROR: extra_args can't set --format: inspect prints JSON, which output_file saves for jq." >&2
            exit 1
            ;;
        --raw | --raw=* | --config | --config=*)
            flag=${word%%=*}
            echo "ERROR: extra_args can't set ${flag}: use the ${flag#--} parameter instead." >&2
            exit 1
            ;;
    esac
done
skopeo_require

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Passed even when true, so a registries.conf that marks the registry
# insecure can't relax it.
COMMON_ARGS=(--tls-verify="${TLS_VERIFY}")
# The array can be empty, and bash before 4.4 treats an empty array as unset
# under set -u, so it is expanded only when it has elements.
COMMON_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})

# pin_digest IMAGE DIGEST: IMAGE by DIGEST instead of its tag, for a registry
# image (docker://). Other transports name local images, which are printed as
# named.
pin_digest() {
    local name
    if [[ "$1" != docker://* ]]; then
        printf '%s\n' "$1"
        return
    fi
    name=${1#docker://}
    name=${name%%@*}
    # A tag follows the last ":" of the last path component; a ":" before the
    # first "/" is a registry port.
    if [[ "${name##*/}" == *:* ]]; then
        name=${name%:*}
    fi
    printf 'docker://%s@%s\n' "${name}" "$2"
}

echo "Inspecting ${IMAGE} with skopeo..."
# The manifest first: its digest is what the image name points to now, and
# the rest of the output is read for that digest, so a tag that moves in
# between can't make the two disagree.
skopeo inspect --raw ${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"} -- "${IMAGE}" > "${WORK_DIR}/manifest.json"
DIGEST=$(skopeo manifest-digest -- "${WORK_DIR}/manifest.json")
if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$|^sha512:[0-9a-f]{128}$ ]]; then
    echo "ERROR: skopeo manifest-digest printed '${DIGEST}', not a sha256 or sha512 digest." >&2
    exit 1
fi

if [[ "${RAW}" == true && "${CONFIG}" == false ]]; then
    cp "${WORK_DIR}/manifest.json" "${WORK_DIR}/output.json"
else
    INSPECT_ARGS=(inspect)
    if [[ "${RAW}" == true ]]; then
        INSPECT_ARGS+=(--raw)
    fi
    if [[ "${CONFIG}" == true ]]; then
        INSPECT_ARGS+=(--config)
    fi
    # Only the full inspect output lists tags.
    if [[ "${NO_TAGS}" == true && "${CONFIG}" == false ]]; then
        INSPECT_ARGS+=(--no-tags)
    fi
    INSPECT_ARGS+=(${COMMON_ARGS[@]+"${COMMON_ARGS[@]}"})
    INSPECT_ARGS+=(-- "$(pin_digest "${IMAGE}" "${DIGEST}")")
    skopeo "${INSPECT_ARGS[@]}" > "${WORK_DIR}/output.json"
fi

cat "${WORK_DIR}/output.json"
echo
if [[ -n "${OUTPUT_FILE}" ]]; then
    if ! mkdir -p "$(dirname "${OUTPUT_FILE}")" || ! cp "${WORK_DIR}/output.json" "${OUTPUT_FILE}"; then
        echo "ERROR: Could not write the output to ${OUTPUT_FILE}." >&2
        exit 1
    fi
    echo "Saved the output to ${OUTPUT_FILE}."
fi
echo "  Digest: ${DIGEST}"
skopeo_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} for later steps."
