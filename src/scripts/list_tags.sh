#!/bin/bash
#
# Lists the tags of a repository for the list_tags command, with
# skopeo list-tags. Prints them, and can write them to a file, one per line.

set -euo pipefail

if [[ -z "${SCRIPT_SKOPEO_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_SKOPEO_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_SKOPEO_LIB}"

REPOSITORY=$(skopeo_subst "${PARAM_REPOSITORY}")
TLS_VERIFY=$(skopeo_bool tls_verify "${PARAM_TLS_VERIFY}")
TAGS_FILE=$(skopeo_subst "${PARAM_TAGS_FILE}")
EXTRA_ARGS=$(skopeo_subst "${PARAM_EXTRA_ARGS}")

skopeo_image repository "${REPOSITORY}"
if [[ -n "${TAGS_FILE}" && "${REPOSITORY}" != docker://* ]]; then
    # For an archive, skopeo lists references such as docker.io/library/app:1,
    # not tags.
    echo "ERROR: tags_file needs a registry repository (docker://), not '${REPOSITORY}'." >&2
    exit 1
fi
if [[ "${TAGS_FILE}" == \~/* ]]; then
    if [[ -z "${HOME:-}" ]]; then
        echo "ERROR: HOME is not set, so tags_file can't start with ~/." >&2
        exit 1
    fi
    TAGS_FILE="${HOME}${TAGS_FILE:1}"
fi
skopeo_words extra_args "${EXTRA_ARGS}"
EXTRA_ARG_LIST=(${SKOPEO_WORDS[@]+"${SKOPEO_WORDS[@]}"})
skopeo_require

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

LIST_ARGS=(list-tags)
if [[ "${TLS_VERIFY}" == false ]]; then
    LIST_ARGS+=(--tls-verify=false)
fi
# The array can be empty, and bash before 4.4 treats an empty array as unset
# under set -u, so it is expanded only when it has elements.
LIST_ARGS+=(${EXTRA_ARG_LIST[@]+"${EXTRA_ARG_LIST[@]}"})
# After --, a name that starts with "-" is not read as a flag.
LIST_ARGS+=(-- "${REPOSITORY}")

echo "Listing the tags of ${REPOSITORY} with skopeo..."
skopeo "${LIST_ARGS[@]}" > "${WORK_DIR}/tags.json"
cat "${WORK_DIR}/tags.json"
echo

if [[ -n "${TAGS_FILE}" ]]; then
    # skopeo prints the tags one per line, indented, inside "Tags": [ ... ].
    # A tag can't hold a quote or a backslash, so no JSON escape needs undoing,
    # and anything else in the list is refused rather than written.
    if ! awk '
        /^    "Tags": (\[\]|null)/ { in_tags = 0; seen = 1; next }
        /^    "Tags": \[/ { in_tags = 1; seen = 1; next }
        in_tags && /^    \]/ { in_tags = 0; next }
        in_tags {
            if (match($0, /^        "[A-Za-z0-9_][A-Za-z0-9_.-]*",?$/)) {
                line = $0
                sub(/^        "/, "", line)
                sub(/",?$/, "", line)
                print line
            } else {
                bad = 1
            }
        }
        END { exit (seen && !bad) ? 0 : 1 }
    ' "${WORK_DIR}/tags.json" > "${WORK_DIR}/tags.txt"; then
        echo "ERROR: Could not read the tags from skopeo list-tags' output." >&2
        exit 1
    fi
    if ! mkdir -p "$(dirname "${TAGS_FILE}")" || ! cp "${WORK_DIR}/tags.txt" "${TAGS_FILE}"; then
        echo "ERROR: Could not write the tags to ${TAGS_FILE}." >&2
        exit 1
    fi
    echo "Wrote the tags to ${TAGS_FILE}, one per line ($(wc -l < "${TAGS_FILE}" | tr -d ' ') in all)."
fi
