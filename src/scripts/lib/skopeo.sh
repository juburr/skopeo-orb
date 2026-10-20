#!/bin/bash

# Shared helpers for the skopeo-orb commands. Each command passes this file to
# its step as SCRIPT_SKOPEO_LIB, and its script evals it after
# set -euo pipefail, so it only defines functions.

# skopeo_subst VALUE: prints VALUE with environment variables expanded. The
# value is piped in on stdin: passed as an argument, a value starting with "-"
# would be parsed as a flag. Without the CircleCI CLI (local runs), the value
# is used as is.
skopeo_subst() {
    if command -v circleci > /dev/null 2>&1; then
        printf '%s' "$1" | circleci env subst
    else
        printf '%s\n' "$1"
    fi
}

# skopeo_bool NAME VALUE: prints true or false. CircleCI passes boolean
# parameters as 1 or 0; local callers use true or false.
skopeo_bool() {
    case "$2" in
        1 | true) echo true ;;
        0 | false) echo false ;;
        *)
            echo "ERROR: ${1} must be true or false, not '${2}'." >&2
            exit 1
            ;;
    esac
}

# skopeo_require: stops the step unless skopeo is on the PATH.
skopeo_require() {
    if ! command -v skopeo > /dev/null 2>&1; then
        echo "ERROR: skopeo is not on the PATH. Run the install command in an earlier step." >&2
        exit 1
    fi
}

# split_shell_words STRING: splits STRING into the SHELL_WORDS array the way
# the shell splits a command line into words, but expands and executes
# nothing. Single quotes keep everything literal. Inside double quotes a
# backslash escapes only ", \, $, ` and newline, as in bash. Outside quotes a
# backslash escapes the next character, and a backslash-newline joins lines.
# A # that starts a word starts a comment, which runs to the end of the line.
# Spaces, tabs and newlines separate words, and '' is an empty word. Returns 1
# if a quote is never closed, 2 if the input ends in a backslash outside
# quotes (which escapes nothing), 3 for bash's $'...' or $"..." quoting, which
# it does not implement, 4 for a $(...) or backtick outside quotes, which it
# would not run, and 5 for a shell operator (| & ; < > ( )) outside quotes,
# such as a redirection or a <(...) process substitution.
split_shell_words() {
    local input=$1 word="" in_word=false quote="" char next i
    SHELL_WORDS=()
    for ((i = 0; i < ${#input}; i++)); do
        char=${input:i:1}
        if [[ "${quote}" == "'" ]]; then
            if [[ "${char}" == "'" ]]; then quote=""; else word+=${char}; fi
        elif [[ "${quote}" == '"' ]]; then
            if [[ "${char}" == '"' ]]; then
                quote=""
            elif [[ "${char}" == "\\" ]] && ((i + 1 < ${#input})); then
                next=${input:i+1:1}
                case "${next}" in
                    '"' | "\\" | '$' | '`') word+=${next}; i=$((i + 1)) ;;
                    $'\n') i=$((i + 1)) ;;
                    *) word+=${char} ;;
                esac
            else
                word+=${char}
            fi
        else
            case "${char}" in
                ' ' | $'\t' | $'\n')
                    if [[ "${in_word}" == true ]]; then
                        SHELL_WORDS+=("${word}")
                        word=""
                        in_word=false
                    fi
                    ;;
                "'" | '"') quote=${char}; in_word=true ;;
                "#")
                    if [[ "${in_word}" == true ]]; then
                        word+=${char}
                    else
                        while ((i + 1 < ${#input})) && [[ "${input:i+1:1}" != $'\n' ]]; do
                            i=$((i + 1))
                        done
                    fi
                    ;;
                "\\")
                    ((i + 1 < ${#input})) || return 2
                    i=$((i + 1))
                    if [[ "${input:i:1}" != $'\n' ]]; then
                        word+=${input:i:1}
                        in_word=true
                    fi
                    ;;
                '$')
                    case "${input:i+1:1}" in
                        "'" | '"') return 3 ;;
                        "(") return 4 ;;
                    esac
                    word+=${char}
                    in_word=true
                    ;;
                '`') return 4 ;;
                '|' | '&' | ';' | '<' | '>' | '(' | ')') return 5 ;;
                *) word+=${char}; in_word=true ;;
            esac
        fi
    done
    [[ -z "${quote}" ]] || return 1
    if [[ "${in_word}" == true ]]; then
        SHELL_WORDS+=("${word}")
    fi
}

# skopeo_words PARAMETER VALUE: sets SKOPEO_WORDS to VALUE split like shell
# words (see split_shell_words), naming PARAMETER in any error. Nothing in it
# is expanded or executed: a $(...) or backtick that reached a parameter
# through an environment variable (a branch name, a commit message) reaches
# skopeo as text inside quotes, and fails the step outside them.
skopeo_words() {
    local status=0
    split_shell_words "$2" || status=$?
    case "${status}" in
        0) ;;
        1)
            echo "ERROR: ${1} could not be split into arguments: it has a quote that is never closed." >&2
            echo "  A literal ' or \" needs a backslash before it, or quotes of the other kind around it." >&2
            exit 1
            ;;
        2)
            echo "ERROR: ${1} could not be split into arguments: it ends in a backslash." >&2
            echo "  A literal \\ at the end needs another \\ before it." >&2
            exit 1
            ;;
        3)
            echo "ERROR: ${1} could not be split into arguments: \$'...' and \$\"...\" quoting is not supported." >&2
            echo "  Use '...' or \"...\" instead." >&2
            exit 1
            ;;
        4)
            echo "ERROR: ${1} could not be split into arguments: it has a \$(...) or backtick outside quotes." >&2
            echo "  ${1} is not run as shell code, so the command would not run. Quote it to pass it to skopeo as text." >&2
            exit 1
            ;;
        *)
            echo "ERROR: ${1} could not be split into arguments: it has one of | & ; < > ( ) outside quotes." >&2
            echo "  ${1} is not run as shell code, so pipes, redirections and <(...) would not work. Quote it to pass it to skopeo as text." >&2
            exit 1
            ;;
    esac
    # shellcheck disable=SC2034 # read by the script that evals this file
    SKOPEO_WORDS=(${SHELL_WORDS[@]+"${SHELL_WORDS[@]}"})
}

# skopeo_env_var_name PARAMETER VALUE: stops the step unless VALUE can name an
# environment variable.
skopeo_env_var_name() {
    if [[ ! "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "ERROR: ${1} must name an environment variable, not '${2}'." >&2
        exit 1
    fi
}

# skopeo_image PARAMETER VALUE: stops the step unless VALUE is a skopeo image
# name, which starts with its transport, such as docker:// for a registry.
skopeo_image() {
    if [[ -z "$2" ]]; then
        echo "ERROR: ${1} is required." >&2
        exit 1
    fi
    if [[ ! "$2" =~ ^[a-z][a-z0-9-]*: ]]; then
        echo "ERROR: ${1} must start with a transport, such as docker://${2}, not '${2}'." >&2
        echo "  skopeo names images by transport: docker:// for a registry, oci: or dir: for a local directory." >&2
        exit 1
    fi
}

# skopeo_registry VALUE: stops the step unless VALUE is a registry host with
# an optional port.
skopeo_registry() {
    if [[ -z "$1" ]]; then
        echo "ERROR: registry is required, such as ghcr.io or localhost:5000." >&2
        exit 1
    fi
    if [[ "$1" == *://* || "$1" == */* ]]; then
        echo "ERROR: registry must be a host with an optional port, such as ghcr.io or localhost:5000, not '${1}'." >&2
        exit 1
    fi
}

# skopeo_auth_args: sets SKOPEO_AUTH_ARGS to the credentials file login and
# logout write. With REGISTRY_AUTH_FILE set, skopeo uses that file for every
# command, so nothing is added. Otherwise login writes Docker's config.json,
# which skopeo reads, as do docker, crane and oras. skopeo's own default,
# under $XDG_RUNTIME_DIR or /run/containers/<uid>, is often not set or not
# writable in a CI job.
skopeo_auth_args() {
    SKOPEO_AUTH_ARGS=()
    if [[ -n "${REGISTRY_AUTH_FILE:-}" ]]; then
        echo "  Credentials file: ${REGISTRY_AUTH_FILE} (REGISTRY_AUTH_FILE)"
        return 0
    fi
    if [[ -z "${DOCKER_CONFIG:-}" && -z "${HOME:-}" ]]; then
        echo "ERROR: HOME is not set, so there is no Docker config file to store the credentials in." >&2
        echo "  Set REGISTRY_AUTH_FILE to the path of a credentials file." >&2
        exit 1
    fi
    SKOPEO_AUTH_ARGS=(--compat-auth-file "${DOCKER_CONFIG:-${HOME}/.docker}/config.json")
    echo "  Credentials file: ${SKOPEO_AUTH_ARGS[1]}"
}

# skopeo_export NAME VALUE: exports NAME=VALUE, shell-quoted, to later steps
# through BASH_ENV.
skopeo_export() {
    if [[ -z "${BASH_ENV:-}" ]]; then
        echo "WARN: BASH_ENV is not set, so ${1} is not exported to later steps." >&2
        return 0
    fi
    printf 'export %s=%q\n' "$1" "$2" >> "${BASH_ENV}"
}
