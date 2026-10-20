#!/bin/bash
#
# Installs skopeo for the install command: the Linux amd64 or arm64 build that
# matches this machine, built from source and verified against the checksum
# table in this file before it is installed.
#
# Every juburr orb's install.sh has the same three parts:
#   1. tool definition: what to download and how to install it (skopeo only)
#   2. shared install logic: identical in every orb
#   3. checksum table: one SHA-512 per release and architecture
#
# Add the checksums for a new release with:
#   src/scripts/install_hash.sh -v <version>

# CircleCI runs steps with /bin/sh when the image has no bash, and macOS ships
# bash 3, which lacks associative arrays.
if [ -z "${BASH_VERSION:-}" ] || [ "${BASH_VERSINFO:-0}" -lt 4 ]; then
    echo "ERROR: Installing skopeo needs bash 4 or newer. Use an executor image that has it." >&2
    exit 1
fi
set -euo pipefail

# >>> tool definition >>>
ORB_NAME="skopeo-orb"
TOOL_NAME="skopeo"
TOOL_BINARY="skopeo"
TOOL_ARCHES="amd64 arm64"
# The default install_path, under HOME.
TOOL_DEFAULT_INSTALL_DIR="bin"

# skopeo publishes source releases only, so install builds the release with
# a pinned Go toolchain (skopeo_build) and checks the binary it built against
# the checksum table. Go builds are reproducible: the same source, Go release
# and settings give the same bytes on any machine, which is what the table
# pins. The source comes from the Go module proxy, checked against Go's
# public checksum database, and the Go toolchain is checked against
# skopeo_go_sha512sums.

# The Go release that builds the versions in the checksum table, except those
# in skopeo_go_overrides. The table holds checksums of binaries this Go built,
# so changing it means generating every entry again with install_hash.sh, and
# bumping the cache key version in install.yml so caches of the old binaries
# stop being restored.
SKOPEO_GO_VERSION="1.27.3"

# skopeo releases that SKOPEO_GO_VERSION can't build, and the Go release that
# builds each. The gRPC in skopeo 1.23.0 uses the HTTP/2 server that x/net
# leaves out under Go 1.27 and later.
declare -A skopeo_go_overrides=(
    ["1.23.0"]="1.26.10"
)

# SHA-512 checksums of the Go release archives, keyed "<go version>/<arch>".
# Add one with: src/scripts/install_hash.sh -g <go version>
declare -A skopeo_go_sha512sums=(
    ["1.27.3/amd64"]="1270262f20a6ef23f5901c146c5e2a18225be92ccf63d03543cdb4ff17f1165c2e7ead97b7164f50ced861f8cbef93f76a7552614a257d66e5d1e9357c1b34e0"
    ["1.27.3/arm64"]="75caaff42ec918db37d087d397270b63c40191065abb56db15564e246a4728667d54dd9f1432dfd38e5db490a4bf1737d86f4ca920517007c2c97810dc06b7a2"
    ["1.26.10/amd64"]="fff91a8d62212b2b8f66f2a7029173eb6ce6e13767f04e7ec321cb1682d16b843fc3499370c56b385c47303b65f4f6a64b4a745adb3eb4adde2438284fa873b7"
    ["1.26.10/arm64"]="7d6aa72a27027fd032189d651354a93fad837d4ca3bae032e067d55e2d1ee78b3ddae7588324c93b367f4167182addd482632fd42b77780135707f6e0f669c1d"
)

# The build tags of skopeo's own build without cgo (make DISABLE_CGO=1; newer
# releases dropped devicemapper, which they ignore): signatures are checked
# with a Go OpenPGP implementation instead of gpgme, and the storage drivers
# that need C libraries are left out.
SKOPEO_BUILD_TAGS="containers_image_openpgp exclude_graphdriver_btrfs exclude_graphdriver_devicemapper"

# tool_asset_name VERSION ARCH: the file the checksum table describes, which
# is the binary the build produces. It is also the name it is cached under.
tool_asset_name() {
    printf 'skopeo\n'
}

# tool_archive_member VERSION ARCH: empty, since the checksum covers the
# built binary itself. There is no release asset, so there is no
# tool_asset_urls either: tool_install builds instead of downloading.
tool_archive_member() {
    :
}

# tool_version BINARY: prints the installed version without using the network.
tool_version() {
    "$1" --version
}

# skopeo_module VERSION: the Go module skopeo VERSION is published as. It
# moved from github.com/containers/skopeo to go.podman.io/skopeo in 1.23.0.
skopeo_module() {
    if [[ "$(printf '%s\n%s\n' 1.23.0 "$1" | sort -V | head -n 1)" == "1.23.0" ]]; then
        printf 'go.podman.io/skopeo\n'
    else
        printf 'github.com/containers/skopeo\n'
    fi
}

# skopeo_go_version VERSION: the Go release that builds skopeo VERSION.
skopeo_go_version() {
    printf '%s\n' "${skopeo_go_overrides["$1"]:-${SKOPEO_GO_VERSION}}"
}

# skopeo_fetch_go GO_VERSION ARCH DIR: downloads Go GO_VERSION for ARCH,
# checks it against skopeo_go_sha512sums, and extracts it into DIR, so the
# toolchain is DIR/go.
skopeo_fetch_go() {
    local go_version=$1 arch=$2 dir=$3 archive expected actual
    archive="${dir}/go${go_version}.linux-${arch}.tar.gz"
    expected=${skopeo_go_sha512sums["${go_version}/${arch}"]:-}
    if [[ ! "${expected}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "This orb has no valid checksum for Go ${go_version} (${arch}), which builds skopeo."
    fi
    mkdir -p "${dir}"
    if ! orb_download "${archive}" "https://dl.google.com/go/go${go_version}.linux-${arch}.tar.gz"; then
        orb_die "Could not download Go ${go_version} (${arch}), which builds skopeo. Re-run the job if the download host was failing."
    fi
    actual=$(sha512sum "${archive}" | awk '{ print $1 }')
    if [[ "${actual}" != "${expected}" ]]; then
        orb_die "The Go ${go_version} (${arch}) download does not match this orb's checksum, so skopeo was not built." \
            "Expected ${expected}, got ${actual}."
    fi
    orb_info "Go ${go_version} (${arch}) matches its SHA-512 checksum."
    if ! tar -xzf "${archive}" -o -C "${dir}" 2> "${dir}/tar.log"; then
        orb_die "Could not extract Go ${go_version}: $(head -c 300 "${dir}/tar.log")"
    fi
    rm -f "${archive}"
}

# skopeo_build VERSION ARCH GOROOT DIR: builds skopeo VERSION for ARCH with the
# Go toolchain in GOROOT, working in DIR, and sets SKOPEO_BUILT_FILE to the
# binary. Go's output goes to DIR/build.log. Every setting that shapes the
# binary is pinned here, so Go settings in the job's environment can't change
# it. The download settings (GOPROXY, GOSUMDB, GOPRIVATE and the like) are
# left as the job sets them, for jobs behind a module proxy: the checksum
# check covers whatever they fetch.
skopeo_build() {
    local version=$1 arch=$2 goroot=$3 dir=$4 module host_arch
    local -a go_env
    module=$(skopeo_module "${version}")
    mkdir -p "${dir}/gopath" "${dir}/gocache" "${dir}/config"
    go_env=(env -u GOEXPERIMENT -u GODEBUG -u GOROOT_FINAL -u GOCACHEPROG -u GOTOOLDIR
        GOROOT="${goroot}" GOPATH="${dir}/gopath" GOMODCACHE="${dir}/gopath/pkg/mod" GOCACHE="${dir}/gocache"
        GOBIN="" GOENV=off GOWORK=off GOTOOLCHAIN=local XDG_CONFIG_HOME="${dir}/config"
        GOFLAGS="-trimpath -modcacherw" CGO_ENABLED=0 GOOS=linux GOARCH="${arch}" GOAMD64=v1 GOARM64=v8.0
        GOFIPS140=off)
    if ! "${go_env[@]}" "${goroot}/bin/go" install -tags "${SKOPEO_BUILD_TAGS}" "${module}/cmd/skopeo@v${version}" \
        > "${dir}/build.log" 2>&1; then
        return 1
    fi
    # go install puts a binary built for another architecture in a
    # subdirectory named after it.
    host_arch=$("${go_env[@]}" "${goroot}/bin/go" env GOHOSTARCH)
    SKOPEO_BUILT_FILE="${dir}/gopath/bin/skopeo"
    if [[ "${host_arch}" != "${arch}" ]]; then
        SKOPEO_BUILT_FILE="${dir}/gopath/bin/linux_${arch}/skopeo"
    fi
    [[ -f "${SKOPEO_BUILT_FILE}" ]]
}

# Installs a verified skopeo from the cache, or builds one. A cached binary
# that fails verification is discarded and built again, like a cached
# download. The cache is only read when there is a checksum to verify the
# cached binary against.
tool_install() {
    local binary="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" build_dir="${ORB_WORK_DIR}/build" go_version
    if [[ "${ORB_CACHING}" == "true" && -n "${ORB_EXPECTED_SHA512}" && -f "${ORB_CACHE_FILE}" ]]; then
        if cp "${ORB_CACHE_FILE}" "${binary}" && orb_info "Using skopeo ${ORB_VERSION} from the cache." \
            && orb_verify "${binary}"; then
            orb_install_file "${binary}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
            return 0
        fi
        orb_warn "The cached skopeo ${ORB_VERSION} could not be read or failed verification. Discarding it and building it again."
        orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
            "Set caching to false to skip it until then."
        rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
    fi

    orb_require_tools sha512sum tar gzip
    go_version=$(skopeo_go_version "${ORB_VERSION}")
    orb_info "Building skopeo ${ORB_VERSION} from source with Go ${go_version}. This takes a few minutes;" \
        "with caching on, later jobs install the verified binary from the cache instead."
    skopeo_fetch_go "${go_version}" "${ORB_ARCH}" "${build_dir}"
    orb_info "Building $(skopeo_module "${ORB_VERSION}")/cmd/skopeo@v${ORB_VERSION}..."
    if ! skopeo_build "${ORB_VERSION}" "${ORB_ARCH}" "${build_dir}/go" "${build_dir}"; then
        orb_warn "The last lines of the Go build:"
        tail -n 40 "${build_dir}/build.log" | sed 's/^/  /' >&2
        orb_die "Could not build skopeo ${ORB_VERSION}. If the log above shows a network error, re-run the job;" \
            "if it says the version is unknown, check that skopeo ${ORB_VERSION} was released."
    fi
    if ! cp "${SKOPEO_BUILT_FILE}" "${binary}" || [[ ! -s "${binary}" ]]; then
        orb_die "The skopeo ${ORB_VERSION} build produced no binary."
    fi
    if ! orb_verify "${binary}"; then
        orb_die "The skopeo ${ORB_VERSION} build is not the binary this orb's checksum table pins for it, so it was not installed."
    fi
    orb_store_cache "${binary}"
    orb_install_file "${binary}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}
# <<< tool definition <<<

# >>> shared install logic >>>
# Everything from here to the end marker is identical in the install.sh of
# every juburr orb, so change it in all of them together. Tool-specific
# behavior belongs in the tool definition above.
#
# Parameters arrive as PARAM_VERSION, PARAM_VERIFY_CHECKSUMS,
# PARAM_INSTALL_PATH and PARAM_CACHING. The checksum table (sha512sums) is
# defined after this block.

orb_info() { printf '%s\n' "$*"; }
orb_warn() { printf 'WARN: %s\n' "$*" >&2; }
orb_die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

# Expands environment variables in a parameter value. The value is piped in
# on stdin: passed as an argument, a value starting with "-" would be parsed
# as a flag. Without the CircleCI CLI (local runs), the value is used as is.
orb_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# CircleCI passes boolean parameters as 1/0; local callers use true/false.
orb_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *) orb_die "${1} must be true or false, not '${2}'." ;;
    esac
}

# Reads an absolute directory parameter: NAME VALUE HOME_SUBDIR. Environment
# variables and a leading ~/ are expanded, trailing slashes are removed, and
# an empty value means $HOME/HOME_SUBDIR.
orb_dir_param() {
    local value
    value=$(orb_subst "$2")
    if [[ -z "${value}" || "${value}" == \~ || "${value}" == \~/* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            orb_die "HOME is not set, so ${1} has no default. Set ${1} to an absolute path."
        fi
        if [[ -z "${value}" ]]; then
            value="${HOME}/${3}"
        else
            value="${HOME}${value:1}"
        fi
    fi
    while [[ "${value}" == */ && "${value}" != "/" ]]; do
        value=${value%/}
    done
    if [[ "${value}" != /* ]]; then
        orb_die "${1} must be an absolute path, not '${value}'."
    fi
    # The directory may be added to the PATH, where ":" separates entries.
    if [[ "${value}" == *:* ]]; then
        orb_die "${1} can't contain ':', which separates PATH entries: '${value}'."
    fi
    printf '%s\n' "${value}"
}

orb_require_tools() {
    local tool package
    for tool in "$@"; do
        if ! command -v "${tool}" > /dev/null 2>&1; then
            case "${tool}" in
                tar | gzip) package=${tool} ;;
                *) package=coreutils ;;
            esac
            orb_die "Installing ${TOOL_NAME} needs '${tool}', which is not available. Install it in an earlier step," \
                "for example with 'microdnf install -y ${package}' on Red Hat UBI images."
        fi
    done
}

# Newest version in the checksum table.
orb_latest_version() {
    local key
    for key in "${!sha512sums[@]}"; do
        printf '%s\n' "${key%/*}"
    done | sort -uV | tail -n 1
}

orb_detect_arch() {
    local os machine
    os=$(uname -s)
    machine=$(uname -m)
    if [[ "${os}" != "Linux" ]]; then
        orb_die "This orb installs Linux builds of ${TOOL_NAME}, but this machine runs ${os}."
    fi
    if [[ "${TOOL_ARCHES}" == "noarch" ]]; then
        ORB_ARCH="noarch"
        orb_info "  platform:         noarch (${os} ${machine})"
        return 0
    fi
    case "${machine}" in
        x86_64 | amd64) ORB_ARCH="amd64" ;;
        aarch64 | arm64) ORB_ARCH="arm64" ;;
        *) orb_die "Unsupported CPU architecture '${machine}'. Supported: x86_64 (amd64), aarch64/arm64 (arm64)." ;;
    esac
    if [[ " ${TOOL_ARCHES} " != *" ${ORB_ARCH} "* ]]; then
        orb_die "${TOOL_NAME} is not published for ${ORB_ARCH}. Supported: ${TOOL_ARCHES}."
    fi
    orb_info "  platform:         linux/${ORB_ARCH} (uname -m: ${machine})"
}

# Decides how this install is verified, before anything is downloaded.
orb_lookup_checksum() {
    ORB_EXPECTED_SHA512=${sha512sums["${ORB_VERSION}/${ORB_ARCH}"]:-}
    if [[ -n "${ORB_EXPECTED_SHA512}" && ! "${ORB_EXPECTED_SHA512}" =~ ^[0-9a-f]{128}$ ]]; then
        orb_die "The checksum table entry for ${ORB_VERSION}/${ORB_ARCH} is malformed."
    fi
    if [[ "${ORB_VERIFY_CHECKSUMS}" == "false" ]]; then
        orb_warn "verify_checksums is false, so ${TOOL_NAME} will be installed WITHOUT checksum verification. This is not recommended."
        ORB_EXPECTED_SHA512=""
    elif [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        if [[ "${ORB_VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            orb_warn "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), and verify_checksums is known_versions."
            orb_warn "Installing an UNVERIFIED binary. Upgrade this orb, or submit a PR with the checksum."
        else
            orb_die "This orb has no checksum for ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}), so it cannot be verified (verify_checksums: strict)." \
                "Use a version this orb lists (the newest is $(orb_latest_version)), upgrade the orb, or opt out with verify_checksums: known_versions."
        fi
    fi
}

orb_init() {
    ORB_VERSION=$(orb_subst "${PARAM_VERSION:-}")
    ORB_VERSION=${ORB_VERSION#v}
    # The version is part of the download URL, so only release versions pass.
    if [[ ! "${ORB_VERSION}" =~ ^[0-9]+(\.[0-9]+){1,2}(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ ]]; then
        orb_die "Invalid ${TOOL_NAME} version '${ORB_VERSION}'. Expected a release version such as $(orb_latest_version)."
    fi
    ORB_VERIFY_CHECKSUMS=${PARAM_VERIFY_CHECKSUMS:-strict}
    case "${ORB_VERIFY_CHECKSUMS}" in
        strict | known_versions | false) ;;
        *) orb_die "verify_checksums must be strict, known_versions or false, not '${ORB_VERIFY_CHECKSUMS}'." ;;
    esac
    ORB_INSTALL_PATH=$(orb_dir_param install_path "${PARAM_INSTALL_PATH:-}" "${TOOL_DEFAULT_INSTALL_DIR}")
    ORB_BIN_DIR=${ORB_INSTALL_PATH}
    ORB_CACHING=$(orb_bool caching "${PARAM_CACHING:-false}")

    orb_info "Installing ${TOOL_NAME} ${ORB_VERSION}"
    orb_info "  install_path:     ${ORB_INSTALL_PATH}"
    orb_info "  verify_checksums: ${ORB_VERIFY_CHECKSUMS}"
    orb_info "  caching:          ${ORB_CACHING}"
    orb_detect_arch
    orb_lookup_checksum

    ORB_ASSET_NAME=$(tool_asset_name "${ORB_VERSION}" "${ORB_ARCH}")
    ORB_ARCHIVE_MEMBER=$(tool_archive_member "${ORB_VERSION}" "${ORB_ARCH}")
    orb_require_tools mktemp
    # Only verification needs sha512sum, so the opt-out modes run without it.
    if [[ -n "${ORB_EXPECTED_SHA512}" ]]; then
        orb_require_tools sha512sum
    fi
    if [[ -n "${ORB_ARCHIVE_MEMBER}" ]]; then
        orb_require_tools tar gzip
    fi

    ORB_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/${ORB_NAME}.XXXXXX")
    ORB_CLEANUP=("${ORB_WORK_DIR}")
    trap 'rm -rf "${ORB_CLEANUP[@]}"' EXIT

    # Restored and saved by install.yml. Files are stored by version and
    # architecture, so a cache restored for another version is never used.
    # Nothing is created here unless a verified asset is stored, so an
    # unverified install leaves nothing for save_cache to save.
    ORB_CACHE_FILE=""
    if [[ "${ORB_CACHING}" == "true" && -z "${HOME:-}" ]]; then
        orb_warn "HOME is not set, so the cache is not used."
        ORB_CACHING=false
    elif [[ "${ORB_CACHING}" == "true" ]]; then
        ORB_CACHE_FILE="${HOME}/.cache/${ORB_NAME}/${ORB_VERSION}/${ORB_ARCH}/${ORB_ASSET_NAME}"
    fi
}

# orb_download DEST URL...: downloads the first URL that works to DEST.
# Transient failures are retried with backoff; a 404 moves on to the next URL.
orb_download() {
    local dest=$1 url help option attempt rc
    local -a fetch
    shift
    if command -v curl > /dev/null 2>&1; then
        # A stalled transfer counts as a failure and is retried.
        fetch=(curl -fsSL --proto '=https' --proto-redir '=https' --retry 8 --retry-max-time 300
            --connect-timeout 30 --speed-limit 1 --speed-time 60)
        # curl added --retry-connrefused in 7.52, and lists it under --help all
        # since 7.73. The output is captured, not piped, so curl can't hit a
        # closed pipe.
        help=$({ curl --help all || curl --help; } 2>&1) || true
        if [[ "${help}" == *--retry-connrefused* ]]; then
            fetch+=(--retry-connrefused)
        fi
        fetch+=(-o)
    elif command -v wget > /dev/null 2>&1; then
        fetch=(wget -q)
        # Only the retry options this wget supports (BusyBox wget has none).
        help=$(wget --help 2>&1) || true
        for option in --tries=20 --waitretry=30 --retry-connrefused --timeout=60 --retry-on-http-error=429,500,502,503,504; do
            if [[ "${help}" == *"${option%%=*}"* ]]; then
                fetch+=("${option}")
            fi
        done
        fetch+=(-O)
    else
        orb_die "Neither curl nor wget is available. Install one of them in an earlier step."
    fi
    for url in "$@"; do
        # curl retries timeouts and HTTP 5xx itself, but not a connection
        # dropped partway through, so that gets two more attempts here. An
        # HTTP error such as a 404 (curl exit code 22) moves on to the next
        # URL. wget retries both itself.
        for attempt in 1 2 3; do
            orb_info "Downloading ${url}"
            rc=0
            "${fetch[@]}" "${dest}.partial" "${url}" || rc=$?
            if [[ "${rc}" -eq 0 ]]; then
                mv -f "${dest}.partial" "${dest}"
                return 0
            fi
            if [[ "${fetch[0]}" != "curl" || "${rc}" -eq 22 || "${attempt}" -eq 3 ]]; then
                break
            fi
            orb_warn "The download failed (curl exit code ${rc}). Retrying in $((attempt * 10)) seconds."
            sleep $((attempt * 10))
        done
        orb_warn "Could not download ${url}."
    done
    rm -f "${dest}.partial"
    return 1
}

# orb_extract ASSET MEMBER: sets ORB_VERIFIED_FILE to the file the checksum
# table describes, which is MEMBER extracted from ASSET, or ASSET itself
# when MEMBER is empty. An empty file is refused, which matters when there
# is no checksum to catch it.
orb_extract() {
    local asset=$1 member=$2 dir
    ORB_VERIFIED_FILE=${asset}
    if [[ -n "${member}" ]]; then
        dir="${ORB_WORK_DIR}/extract"
        rm -rf "${dir}"
        mkdir "${dir}"
        # -o (don't restore the archive's owner) is spelled the same in GNU
        # tar, bsdtar and BusyBox tar, even one built without long options.
        if ! tar -xzf "${asset}" -o -C "${dir}" -- "${member}" 2> "${ORB_WORK_DIR}/tar.log"; then
            orb_warn "Could not extract ${member} from ${ORB_ASSET_NAME}: $(head -c 300 "${ORB_WORK_DIR}/tar.log")"
            return 1
        fi
        ORB_VERIFIED_FILE="${dir}/${member}"
        if [[ ! -f "${ORB_VERIFIED_FILE}" || -L "${ORB_VERIFIED_FILE}" ]]; then
            orb_warn "${member} in ${ORB_ASSET_NAME} is not a regular file."
            return 1
        fi
    fi
    if [[ ! -s "${ORB_VERIFIED_FILE}" ]]; then
        orb_warn "${ORB_VERIFIED_FILE##*/} is empty."
        return 1
    fi
}

# orb_verify FILE: checks FILE against the checksum table, when verifying.
orb_verify() {
    local actual
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        return 0
    fi
    actual=$(sha512sum "$1" | awk '{ print $1 }')
    orb_info "Verifying the SHA-512 checksum of ${1##*/}..."
    orb_info "  expected: ${ORB_EXPECTED_SHA512}"
    orb_info "  actual:   ${actual}"
    if [[ "${actual}" != "${ORB_EXPECTED_SHA512}" ]]; then
        orb_warn "Checksum verification failed."
        return 1
    fi
    orb_info "Checksum verification passed."
}

# orb_temp_beside FILE: sets ORB_TEMP to a new, empty file in FILE's
# directory, to be renamed over FILE, and registers it for cleanup. mktemp
# creates it exclusively, so a file planted in a shared directory isn't
# written through.
orb_temp_beside() {
    ORB_TEMP=$(mktemp "${1%/*}/.${1##*/}.XXXXXX") || return 1
    ORB_CLEANUP+=("${ORB_TEMP}")
}

# Saves a downloaded asset for save_cache. Only verified assets are kept, so
# the cache never supplies a file the checksum table didn't vouch for.
orb_store_cache() {
    if [[ "${ORB_CACHING}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        orb_info "Not caching ${ORB_ASSET_NAME}, since it was not verified."
        return 0
    fi
    if mkdir -p "${ORB_CACHE_FILE%/*}" && orb_temp_beside "${ORB_CACHE_FILE}" \
        && cp "$1" "${ORB_TEMP}" && mv -f "${ORB_TEMP}" "${ORB_CACHE_FILE}"; then
        return 0
    fi
    orb_warn "Could not save ${ORB_ASSET_NAME} to ${ORB_CACHE_FILE%/*}; continuing without the cache."
}

# Fetches the release asset, from the cache when possible, and verifies it.
# Leaves the verified file in ORB_VERIFIED_FILE. A cached asset that fails
# verification is discarded and downloaded again. The cache is only read
# when there is a checksum to verify the cached asset against.
orb_fetch_verified() {
    local asset="${ORB_WORK_DIR}/${ORB_ASSET_NAME}" use_cache=${ORB_CACHING} from_cache urls
    if [[ -z "${ORB_EXPECTED_SHA512}" ]]; then
        use_cache=false
    fi
    while true; do
        from_cache=false
        rm -f "${asset}"
        if [[ "${use_cache}" == "true" && -f "${ORB_CACHE_FILE}" ]]; then
            if ! cp "${ORB_CACHE_FILE}" "${asset}"; then
                orb_warn "Could not read the cached ${ORB_ASSET_NAME}. Downloading it instead."
                use_cache=false
                continue
            fi
            orb_info "Using ${ORB_ASSET_NAME} from the cache."
            from_cache=true
        else
            mapfile -t urls < <(tool_asset_urls "${ORB_VERSION}" "${ORB_ARCH}" "${ORB_ASSET_NAME}")
            if ! orb_download "${asset}" "${urls[@]}"; then
                orb_die "Could not download ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}). Check that this version" \
                    "was published for ${ORB_ARCH}, or re-run the job if the download host was failing."
            fi
        fi
        if orb_extract "${asset}" "${ORB_ARCHIVE_MEMBER}" && orb_verify "${ORB_VERIFIED_FILE}"; then
            break
        fi
        if [[ "${from_cache}" == "true" ]]; then
            orb_warn "The cached ${ORB_ASSET_NAME} failed verification. Discarding it and downloading it again."
            orb_warn "CircleCI can't replace a saved cache, so later jobs will do the same until it expires." \
                "Set caching to false to skip it until then."
            # Like saving it, removing it is best-effort: a read-only cache
            # directory only means the download isn't cached.
            rm -f "${ORB_CACHE_FILE}" 2> /dev/null || true
            use_cache=false
            continue
        fi
        orb_die "The ${TOOL_NAME} ${ORB_VERSION} (${ORB_ARCH}) download was rejected and not installed."
    done
    if [[ "${from_cache}" == "false" ]]; then
        orb_store_cache "${asset}"
    fi
}

# orb_install_file SOURCE DEST: installs SOURCE as the executable DEST. The
# file is staged under DEST's name in a private directory beside DEST and run
# once (orb_smoke_test) before a single rename replaces DEST, so a binary
# that can't run here leaves an existing install in place.
orb_install_file() {
    local dir=${2%/*} name=${2##*/} staging=""
    if ! mkdir -p "${dir}"; then
        orb_die "Could not create ${dir}. Choose an install_path this job's user can write to without root."
    fi
    if [[ -d "$2" ]]; then
        orb_die "Cannot install to $2, which is a directory."
    fi
    if staging=$(mktemp -d "${dir}/.${name}.XXXXXX"); then
        ORB_CLEANUP+=("${staging}")
    fi
    if [[ -z "${staging}" ]] || ! { cp "$1" "${staging}/${name}" && chmod 0755 "${staging}/${name}"; }; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
    orb_smoke_test "${staging}/${name}"
    if ! mv -f "${staging}/${name}" "$2"; then
        orb_die "Could not install ${TOOL_BINARY} to ${dir}. Choose an install_path this job's user can write to without root."
    fi
}

# The default for tools that ship a single binary.
orb_install_binary() {
    orb_fetch_verified
    orb_install_file "${ORB_VERIFIED_FILE}" "${ORB_INSTALL_PATH}/${TOOL_BINARY}"
}

# Adds DIR to the PATH of later steps, unless it is already there.
orb_export_path() {
    local found
    if [[ ":${PATH}:" == *":$1:"* ]]; then
        # Later steps see this PATH, so an earlier copy of the binary wins.
        # -ef accepts the same file reached through a symlinked directory.
        found=$(command -v "${TOOL_BINARY}" || true)
        if [[ -n "${found}" && ! "${found}" -ef "$1/${TOOL_BINARY}" ]]; then
            orb_warn "${found} comes before $1 on the PATH, so later steps will run it instead of the ${TOOL_BINARY} installed here."
        fi
        return 0
    fi
    if [[ -n "${BASH_ENV:-}" ]]; then
        # ${PATH} is expanded when BASH_ENV is sourced, not now.
        # shellcheck disable=SC2016
        printf 'export PATH=%q:"${PATH}"\n' "$1" >> "${BASH_ENV}"
        orb_info "Added $1 to the PATH for later steps."
    else
        orb_warn "$1 is not on the PATH. Add it to run ${TOOL_BINARY} by name."
    fi
}

# orb_smoke_test FILE: runs the new binary once, which catches a build that
# can't run here: one for another architecture (exit code 126), or one that
# crashes, such as with SIGILL on a CPU it doesn't support. tool_version
# needs no network, so any failure means the binary doesn't work.
orb_smoke_test() {
    local output rc=0 line
    if ! declare -F tool_version > /dev/null; then
        return 0
    fi
    output=$(tool_version "$1" 2>&1) || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        orb_die "The downloaded ${TOOL_BINARY} cannot run on this machine: asking it for its version" \
            "exited with code ${rc}. ${output}"
    fi
    orb_info "${TOOL_BINARY} reports:"
    while IFS= read -r line; do
        orb_info "  ${line}"
    done <<< "${output}"
}

orb_install_main() {
    orb_init
    if declare -F tool_install > /dev/null; then
        tool_install
    else
        orb_install_binary
    fi
    orb_export_path "${ORB_BIN_DIR}"
    orb_info "Installed ${TOOL_NAME} ${ORB_VERSION} to ${ORB_INSTALL_PATH}."
}
# <<< shared install logic <<<

# >>> checksum table >>>
# SHA-512 checksums keyed "<version>/<arch>", newest release first, where arch
# is amd64, arm64, or noarch for a release that is the same everywhere.
# tool_archive_member says which file each checksum covers.
declare -A sha512sums=(
    ["1.24.1/amd64"]="2d302e8059fae9ceef43999dd6f608ef93c1f94f3b5040d028f6af111274fa29e64b4119bccb30307d18f571223feed644e203947d7280b64411e86f4badae3d"
    ["1.24.1/arm64"]="043ed724c96ce651b6b16d4f8d90763b786051a93781dbae67a8109338aaefdbcdae9fa9cbadb7b4427c8a517d49804a036265401bc242ec40db39cd6578c41b"
    ["1.24.0/amd64"]="7e7aa8572ea69019b438111903f3652a7c6f989dd5e4597122c54775800acb75ddb5dca932b168c21564ba4faac035a16e9d49a95e6abab0bad4d4f482a4462b"
    ["1.24.0/arm64"]="be5bac6421036bcff8d7fd2e3ea43658ad8e2705cbb4f0b9ecac4e4a1207321ef2053864aef14a776c8831cf7e862d57509eb318ddc066a4b0a343b514780270"
    ["1.23.0/amd64"]="e031f2e3b314ca4f37553df5e8ce47f22495f50cf06747d5c01819c071c8767e8e31fdf2f3b76740abc4a76e2227e45558dbe5ea71a05e94165d41192efca933"
    ["1.23.0/arm64"]="b3caff44e914026fbaf3c2384779e0416ac1692fbd2fe9f364d1bb2615b661ced0359039eabd209abf48854c7c2e43322980f35971128524ef8ffc14f4ff665f"
    ["1.22.3/amd64"]="8a9a5799ad2009eb26ff4140183bedf3cc3c16b94b1af7fc1e4fa1ed72ca5a4dc8c7b2aad857e555de9dda99108c9d1485d451f1b5fbb51317e7793f3d4aedbb"
    ["1.22.3/arm64"]="58fe3d347cdb4f79821da9df4b38d7b93c576611162f67e18593b5f69e56a5236f1cbc3ada2de30f632da5477e27a3a7ce200be5bb42db90b8245b1a3d94dab8"
    ["1.22.2/amd64"]="4a03b8e2ef117823f35c2851518244101cb325d1ca5eedd170c9b5b5f27ce563fba8c9d48390d8554a9ce15a1018f418e84e8fa7fefbb04d2c9ee5b04c6e5dca"
    ["1.22.2/arm64"]="762557aee0835dbcc0da09b70558cf3b9e8ec692cda8e1f2385f1023872b004db7f53157bbc3b8691f9ac8686a3ad9b9fbb976808519a4b102e7c2aaeb7c2147"
    ["1.22.1/amd64"]="714d99d80a0a2322564125ddaf73d7e05ec64b3ac05c33e5cef00789b355edb77508a8d45230b81cd08f926fda9f7d42a540d73ce50b1bb8bac2366302f08ed0"
    ["1.22.1/arm64"]="c740604a1e2fc4496ccf3570bf525d16527002d3a24069824097726fab09eee214f36b04948d9118082936d40247492fa3f2af57ee179ecc7660b6c31565cb4e"
    ["1.22.0/amd64"]="53d7969fcb92f10ce635619198263f9d02f81885abbd91ecc9cca130727bd6d6dffa57edc008f6ba96653c3c26d5a74dcf134202fc46a98f97467853fe5a0fc0"
    ["1.22.0/arm64"]="85dfec0502e6af09aea2beceb8dfdc1cd225de0f423b319fc02a5dd346c8db1184cd4641cf8ba657b9bab3017a0ab15f6900bec0e16209d9d9ddee7ae219cacb"
    ["1.21.0/amd64"]="a98f9a313fb5af70f5bce3b03bff7d469a99ee6c2f62f8f095b82bb75994406369cd0a36f2f46ec3bd3668a68cd515c872b6d94176eb3da3b2566ed7292853f0"
    ["1.21.0/arm64"]="faab5d1268852e910bafa7532dc6194c84dd0c79bda83d116d382d3b3fc48dfef64da327e9d08256ca0dbe7c57fd3e04c2c1a2ac228fc9f91cf96e620295c738"
    ["1.20.1/amd64"]="ed5edb60dab4312ed118f1facc59fcf9f6b11e5fdc5aeb5b48fb119bfde1da7fdad06bec5d9fa89af29bc909f6bd2d55840ad6ac71f26c3675bd1324daff8d0e"
    ["1.20.1/arm64"]="80ba48f668baa24abe6305340252a18721a196d4bee63ebef20aff86bd66f6aa94e8d777878b00b00ed6f5485a371eb785afdf52f49ec760a77b8d77db574a7e"
    ["1.20.0/amd64"]="3c6cd3e26bd358651fc169ed07d4552560bb7a7532485123303b1c686d0a7472e90b03936134b1bdd9fc1b4e6649204093932e498086313acee77426c85e4435"
    ["1.20.0/arm64"]="bb4f1faa9f6a77b2581c4aa85ebeca2ef3e16613dab712a4305469516ab0d8d383eb8ca20d17ab6901f1248238664c1e3e3202cff51b56ec026b0c291640a698"
    ["1.19.0/amd64"]="da3ee40c1da57d1f23e787499dbcb94f170c643a3c623ea1eedf274fc082aee40157bf51dd0c91d24df485f2270e68ec3cd05e6b6dc23bb7b9e6b6fe3ff93a40"
    ["1.19.0/arm64"]="9f058b70fb4f64711c3351e60729767e0a4b7a7606a9bb0f463fa16299096963e4918b631f123691f600a1907b62da5c57eee5778d35f0e41d9599ebf29876c5"
    ["1.18.2/amd64"]="6d5eaa096818d4655174a5c1a69b9b3514167a75c5fa2865fa7fb0da22e3da6905ac6ec3fa6fff4f6e5e504745b047642bee443cdc09ddb9e06dfc8ee72fd205"
    ["1.18.2/arm64"]="fce989e6e85f37365707926bb30c316e7124e3c1ac7dfc50a02c5693344cb48f5cef4a0b4778d327bc45c6081ab2158b5cf4c645f57db753b17395811272530b"
    ["1.18.0/amd64"]="791b2c9b8e06b366de32a833f72084b4b208ccb40ca65aa02e5cd372716a5fe9c8e57a2fb8c7f4c3336475cebe1573c94a2fe463ccfae5857400c66a22632508"
    ["1.18.0/arm64"]="3012e440d22e74791f5d625f49cd9a17378b380cf137cb87a4ae8956db5ed7b64e8a2f0b2de62babb64c0356d93e17d6f1748a40f9037619aa3506a23e2e5174"
    ["1.17.0/amd64"]="a27e8f7c61ab809dff8cb1b5801815c7d40b7ba4436a7cfb30db26f4df9c625d8255eafb1bf1a5adef00bfbfe68a12afc9f0d19bab0d0961d8766b577eab4fe8"
    ["1.17.0/arm64"]="a97148aa34378666b307e1111cb11a1ccbbb5fb9ac870bc6ece11f85b259fb731d489b9548102cb062fdc7c4d6317742207019debabac8436e590b05e4d753ea"
    ["1.16.1/amd64"]="79ed329d475fab5a5945abdff717ae1dd2162f3a0c655e34508e74b11acccfdffbb39d1b52030c0f369b248a81c909ac0f1dc923cdce2eb0a9bba11b835b0bb7"
    ["1.16.1/arm64"]="f07bf47897741f0a8800a112e75780dcd4186161d2957e5d35939a23e1263740142d195a95da993019db1f2931f65e3a8c548aae66008f269d38c9303af4c281"
    ["1.16.0/amd64"]="ad569e323f996dec7d8146373c835990dd25f63cecd7344f29b4be161ae0a670908772e7e2ca57226db5300bcac15a76a94eb343dcc7418e882473b450ccc67d"
    ["1.16.0/arm64"]="e874e6b7989815d8ac179eb132f5f70b31bbf1f74ee6efd8e0f5c9c286290e3e886590f53bef2724caf46f09ae20aad80d9b22cfba6ea973a794e119c0f1d69a"
    ["1.15.2/amd64"]="73cc18dedeb39e0f143d3bc381533ff93afe6e45b08d9084b2f625150e94c3646ae5ebb6b3af5eaa6010efa5cb0105d3638a4f251fb0f27447f8aec7413d8acd"
    ["1.15.2/arm64"]="18a2fa5c0ddfdd6802253805b3aeea23cdadac4c6f868ee6c8beada3bd1a2e57dfa9ab5c8914725bb2c24bd1ed5951c80579f5b0ea724efd6449bf03edfb8979"
    ["1.15.1/amd64"]="5d3b9c15bf3ed1ea7cfde5a85cbf3fde79e182a72f35adf59a77d7d4a5f0e8a5314d60b89dc3335baf8433eaca26b1d82b9fc9c8654159fe01dd8f5c2e987516"
    ["1.15.1/arm64"]="18d378adac1009ac3b1159e0efd5b4726164b6286382def4fa322b06cf0790fdfa71765488e8111ddaa8e64332c32cd850d2726d81a9d9e01f74af6617b2da58"
    ["1.15.0/amd64"]="74bb4a566c9d99383493440ba02fe64c85fc652ba08b9563c6b50987434e6f457ba7f17a137306875c0f717fa0fb1761cdd1bf3e82493d6ebb49d025be21a88d"
    ["1.15.0/arm64"]="8446316748062064f8aae645e94f3566c42035bc6753ac6c695383ef206c2aa5a2efede2c265047f9b5c638a285836167cc99275cacd02134950c030769a4cd5"
    ["1.14.6/amd64"]="aac0a192003758cb878fdc21b547efd157d846b0b6db2401c731de0be6388186b0d0e4f2f4cffa8a6426f2901908029da48f409d05942a0c6684200dc209fb53"
    ["1.14.6/arm64"]="b6947a93881acd7c89ec2be18f8e1a24006b3b58f9893a23521a5d0b135ce11f184fd943646e433f0e7fa25f30b2d6ba58aa0ceaf0e99ad1ed34e1f534ed5f9a"
    ["1.14.5/amd64"]="bf8d83c6b0c8fabd8697952748f4c2aa8b19ad6300d3dcdc3ce03f7c25ec63c7be2fc995fb99b827cd62eb982189e65f9dead10a71552b5fd7121e25c9313f70"
    ["1.14.5/arm64"]="d950ad819b45c5075ac77716af56da600ec3fc46ff58509b5aeaa25273d5350e49209703b9e9d94d4ace63ee1489db06103ac70b7e355a7800d3201d638d8e24"
    ["1.14.4/amd64"]="ec7c37bba78fb96fa6b5d8ad41b17d43e1985026fa186f75aaa475cd633bb10e1e9663e8b62e3e3ad46a0a02de4464e51a6815efb2b13d0a1020df2534db8244"
    ["1.14.4/arm64"]="d111146910a4c1233f3a7ec9e9ffacf1099a2311252a60f36a11b4c944b307c031698ba6242920bd09ed208101f4e47abbc7bfb72aac9688e3fdb41b5764696a"
    ["1.14.3/amd64"]="2b8f2d6e9bb4565385caa17029554053008d8602d482fc2fce2a5f93c2ad255e3b0f2a9f17dea1e0d6a5ffc4afb11655fee83cf9f8c5445faf3c0bb99c0ba60f"
    ["1.14.3/arm64"]="609de180ec8135b57e12b4e25d7d4e5052323ca687cffd2f35de8a2837b280b897ac43230676aff59c55b899b3d821b92b915d3ceff84737e0a18d9cfa485f27"
    ["1.14.2/amd64"]="e85a20dd1cd671c297964dec8b1163616d85dd6ded76f16a274077eb38d08d073cab77f82b7f481d9212ad86eca026047887864db29e79cad1a4b67063f8fb09"
    ["1.14.2/arm64"]="37402108d871743a622ed8b195c6ce2a161b2e1c711c5d6044152cf7caa01cf6edab3fee02772e0c0fc96a39f0b5c3b397fb6da589e3daa9420c6c018a888e20"
    ["1.14.1/amd64"]="3deab334ff53ded3481fc91b4e9136714cb2806505d1a5d77daabb2d86bdc145badd5ae6d8b9d6e40a5645d3a37ea8a15da43604f87ac033afd23bf5dda1d5c7"
    ["1.14.1/arm64"]="08683abfdcb361eca286eb34e7a3e3578ee4c18e6fa1d4f42a11004769b2f758bba99003c98320bd3aac49e4ceb5d6a636e6737da3e43080859dabda31e1526b"
    ["1.14.0/amd64"]="d400794c453ce7713c5d5303f2a078a2b7777fa83c262de3596fd7d2348ee8f481f614c35ab531df2cfd41855a539c028fd6f5201b1ae226588558c538ca0d1d"
    ["1.14.0/arm64"]="4597aeb1ee0800b7bf4ca55509a727b9a98942532526f0777c4cfb15f4068b0c8f9d430ae854e63886a7b6399916b1e40cd332edccfc580fbe76cdb51aae39d3"
)
# <<< checksum table <<<

orb_install_main
