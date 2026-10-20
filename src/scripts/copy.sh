#!/bin/bash
#
# Copies an image for the copy command, with skopeo copy: from one registry or
# repository to another, or between a registry and a local directory or
# archive, without a Docker daemon. Exports the digest of the image it wrote
# for later steps.
#
# skopeo copy refuses to run without a signature policy (policy.json), and
# executors without the containers-common package, such as cimg/base, have
# none. The copy then uses the policy that package installs by default, which
# accepts any image, and says so.

set -euo pipefail

if [[ -z "${SCRIPT_SKOPEO_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SKOPEO_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SKOPEO_LIB}"

SOURCE=$(skopeo_subst "${PARAM_SOURCE}")
DESTINATION=$(skopeo_subst "${PARAM_DESTINATION}")
MULTI_ARCH=${PARAM_MULTI_ARCH}
SRC_TLS_VERIFY=$(skopeo_bool src_tls_verify "${PARAM_SRC_TLS_VERIFY}")
DEST_TLS_VERIFY=$(skopeo_bool dest_tls_verify "${PARAM_DEST_TLS_VERIFY}")
EXTRA_ARGS=$(skopeo_subst "${PARAM_EXTRA_ARGS}")
skopeo_env_var_name digest_env_var "${PARAM_DIGEST_ENV_VAR}"

skopeo_image source "${SOURCE}"
skopeo_image destination "${DESTINATION}"
case "${MULTI_ARCH}" in
    system | all | index-only) ;;
    *)
        echo "ERROR: multi_arch must be system, all or index-only, not '${MULTI_ARCH}'." >&2
        exit 1
        ;;
esac
skopeo_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${SKOPEO_WORDS[@]+"${SKOPEO_WORDS[@]}"})
POLICY_GIVEN=false
for word in ${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"}; do
    case "${word}" in
        --digestfile | --digestfile=*)
            echo "ERROR: extra_args can't set --digestfile: copy writes the digest to digest_env_var itself." >&2
            exit 1
            ;;
        --policy | --policy=* | --insecure-policy | --insecure-policy=*) POLICY_GIVEN=true ;;
    esac
done
skopeo_require

# policy_found: succeeds if skopeo has a signature policy to load: one named
# by CONTAINERS_POLICY_JSON or in any place skopeo looks for policy.json.
policy_found() {
    local file
    if [[ -n "${CONTAINERS_POLICY_JSON:-}" ]]; then
        return 0
    fi
    for file in "${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/containers/policy.json" \
        "${HOME:-/nonexistent}/.config/containers/policy.json" \
        /etc/containers/policy.json /usr/share/containers/policy.json; do
        if [[ -f "${file}" ]]; then
            return 0
        fi
    done
    return 1
}

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
DIGEST_FILE="${WORK_DIR}/digest"
POLICY_NOTE="the executor's policy.json"
if [[ "${POLICY_GIVEN}" == true ]]; then
    POLICY_NOTE="from extra_args"
fi

COPY_ARGS=(copy --multi-arch "${MULTI_ARCH}" --digestfile "${DIGEST_FILE}")
if [[ "${POLICY_GIVEN}" == false ]] && ! policy_found; then
    printf '{"default":[{"type":"insecureAcceptAnything"}]}\n' > "${WORK_DIR}/policy.json"
    COPY_ARGS+=(--policy "${WORK_DIR}/policy.json")
    POLICY_NOTE="none on this executor, so any image is accepted, as with containers-common's default policy.json"
fi
if [[ "${SRC_TLS_VERIFY}" == false ]]; then
    COPY_ARGS+=(--src-tls-verify=false)
fi
if [[ "${DEST_TLS_VERIFY}" == false ]]; then
    COPY_ARGS+=(--dest-tls-verify=false)
fi
# The array can be empty, and bash before 4.4 treats an empty array as unset
# under set -u, so it is expanded only when it has elements.
COPY_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
# After --, an image name that starts with "-" is not read as a flag.
COPY_ARGS+=(-- "${SOURCE}" "${DESTINATION}")

echo "Copying ${SOURCE} to ${DESTINATION} with skopeo..."
echo "  Multi-arch: ${MULTI_ARCH}"
echo "  TLS verify: source ${SRC_TLS_VERIFY}, destination ${DEST_TLS_VERIFY}"
echo "  Signature policy: ${POLICY_NOTE}"
skopeo "${COPY_ARGS[@]}"

DIGEST=$(cat "${DIGEST_FILE}")
if [[ ! "${DIGEST}" =~ ^sha256:[0-9a-f]{64}$|^sha512:[0-9a-f]{128}$ ]]; then
    echo "ERROR: skopeo copy wrote '${DIGEST}' as the digest, not a sha256 or sha512 digest." >&2
    exit 1
fi
echo "Copied ${SOURCE} to ${DESTINATION}."
echo "  Digest: ${DIGEST}"
skopeo_export "${PARAM_DIGEST_ENV_VAR}" "${DIGEST}"
echo "Exported ${PARAM_DIGEST_ENV_VAR} for later steps."
