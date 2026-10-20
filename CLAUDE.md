# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is an unofficial CircleCI orb for skopeo, the containers project's CLI that copies, inspects and lists container images in registries and local directories, without a Docker daemon. The orb installs a checksum-verified skopeo and wraps its most used commands.

## Development Commands

```bash
# Pack the orb from source into a single file, and validate it
circleci orb pack src/ > orb.yml
circleci orb validate orb.yml

# Lint
yamllint .
shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh

# Tests (offline)
for t in tests/*_test.sh; do bash "$t" || break; done

# Build a skopeo release and print its SHA-512 table entries (linux amd64 + arm64)
./src/scripts/install_hash.sh -v <version>
```

## Architecture

### Orb Structure (`src/`)

- `@orb.yml` - Orb metadata (version 2.1)
- `commands/` - One command per skopeo subcommand, named after it
  - `install.yml` - Builds and installs skopeo with caching and checksum verification
  - `login.yml` / `logout.yml` - `skopeo login` / `skopeo logout`
  - `copy.yml` - `skopeo copy`, exports the digest it wrote (`digest_env_var`, default `SKOPEO_DIGEST`)
  - `inspect.yml` - `skopeo inspect`, exports the digest the image name points to (`digest_env_var`, default `SKOPEO_DIGEST`)
  - `list_tags.yml` - `skopeo list-tags`, optionally writing the tags one per line to `tags_file`
- `scripts/` - Shell implementations, one per command, included with `<< include(scripts/...) >>`
- `scripts/lib/skopeo.sh` - Helpers shared by the command scripts. Each command passes it to its step as `SCRIPT_SKOPEO_LIB: << include(scripts/lib/skopeo.sh) >>`, and the script `eval`s it after checking it is set. It only defines functions and has no `set` line.
- `examples/` - Usage examples, pinned to the orb's current version

### Key Implementation Details

**`scripts/install.sh`**: skopeo publishes source releases only, so install builds the release. It follows the layout every juburr orb's install.sh shares: a tool definition, a shared install logic block that must stay identical across the orbs, and a checksum table keyed `"<version>/<arch>"`. The table holds the SHA-512 of the binary the build produces. The tool definition overrides the shared install with `tool_install`, the hook zap-scanner-orb also uses:
- it takes a verified binary from the cache when it can;
- otherwise it downloads Go `SKOPEO_GO_VERSION` (or the release `skopeo_go_overrides` names for that version; 1.23.0 builds with Go 1.26.10, since its gRPC uses the HTTP/2 server x/net leaves out under Go 1.27) and checks it against `skopeo_go_sha512sums` in every mode;
- it builds with `skopeo_build`, verifies the binary with the shared `orb_verify`, caches it, and installs it with `orb_install_file`.

Go builds are reproducible, so a build on any machine gives the bytes the table pins. `skopeo_build` runs `go install <module>/cmd/skopeo@v<version>` and pins every setting that shapes the binary:
- `CGO_ENABLED=0`, `GOFLAGS=-trimpath -modcacherw`, `GOTOOLCHAIN=local`, `GOENV=off`, `GOWORK=off`;
- `GOOS`/`GOARCH`, `GOAMD64=v1`, `GOARM64=v8.0`, `GOFIPS140=off`;
- `GOEXPERIMENT`, `GOCACHEPROG` and `GOTOOLDIR` unset;
- the build tags of upstream's `make DISABLE_CGO=1` (`SKOPEO_BUILD_TAGS`), including `exclude_graphdriver_devicemapper`, which releases up to 1.15 used there and later ones ignore.

Upstream's install guide calls such static builds unsupported, which the README says; CI running every command on the orb's own build is what backs them.

It leaves the job's download settings (`GOPROXY`, `GOSUMDB` and the like) alone, since the checksum covers whatever they fetch. The module is `go.podman.io/skopeo` from 1.23.0 on and `github.com/containers/skopeo` before (`skopeo_module`). Three verification modes: `false`, `known_versions`, `strict` (default, fails before downloading or building an unlisted version). `scripts/cache_key.sh` is shared with the other orbs; never edit the shared parts in one orb only.

**`scripts/install_hash.sh`**: skopeo-only, since there is no release asset for the shared install_hash logic to check. It sources install.sh's tool definition and shared logic and builds with the same `skopeo_build`, so its hashes are of exactly the build install runs:
- `-v <version>` checks the Go archive against go.dev's published SHA-256 and `skopeo_go_sha512sums`, builds every architecture (cross-compiling the ones the host doesn't run) with `GOPROXY=https://proxy.golang.org` and `GOSUMDB=sum.golang.org` forced, and prints one entry per architecture. It also checks that the native build reports its version.
- `-g <go version>` prints `skopeo_go_sha512sums` entries for a Go release.

The table starts at 1.14.0, the first release with `--compat-auth-file`, which `login` needs. Changing `SKOPEO_GO_VERSION` means generating every entry again and bumping the cache key version (`skopeo-orb-v1`) in install.yml, so caches of the old binaries stop being restored. The install step has `no_output_timeout: 30m`, since Go prints nothing while it compiles.

**`scripts/lib/skopeo.sh`**:
- `skopeo_subst` expands environment variables by piping the value to `circleci env subst` on stdin, and uses the value as is without the CLI (local runs).
- `skopeo_words` splits `extra_args` like shell words with `split_shell_words`, the same parser container-ops-orb, oras-orb and crane-orb use: quotes keep spaces, and nothing is expanded or executed. A `$(...)`, backtick or shell operator outside quotes fails the step instead of reaching skopeo.
- `skopeo_image` requires an image name to start with a transport (`docker://`, `oci:`, ...).
- `skopeo_registry` requires a host with an optional port.
- `skopeo_auth_args` picks the credentials file for `login` and `logout`:
  - nothing extra when `REGISTRY_AUTH_FILE` is set, since skopeo then uses that file for every command;
  - otherwise `--compat-auth-file` with Docker's `config.json` (in `DOCKER_CONFIG` or `~/.docker`), which every later skopeo command reads, as do docker, crane and oras.

  skopeo's own default is `$XDG_RUNTIME_DIR/containers/auth.json`, or `/run/containers/<uid>/auth.json` without it, which a non-root CI user can't create.
- `skopeo_export` writes `export NAME=value` to `$BASH_ENV` with `printf 'export %s=%q\n'`.

**`scripts/login.sh`**: Reads the credentials through indirect expansion of the variable names passed as `username` and `password`, turns xtrace off first, and pipes the password to `skopeo login --password-stdin` with `printf`. skopeo checks the credentials with the registry, so wrong ones fail the step.

**`scripts/copy.sh`**: Passes `--multi-arch` (default `all` here; skopeo's is `system`; `docker-archive:` and `docker-daemon:` destinations need `system`) and `--digestfile` to a `mktemp` file, and exports the digest from it. `--digestfile` in `extra_args` is refused. skopeo copy refuses to run without a signature policy, and cimg/base has none. Unless `extra_args` has `--policy`/`--insecure-policy`, copy passes `CONTAINERS_POLICY_JSON` as `--policy` (1.14.0 doesn't read that variable itself), or, when no `policy.json` exists where skopeo looks (`$XDG_CONFIG_HOME` or `~/.config`, `/etc/containers`, `/usr/share/containers`), a `--policy` with containers-common's default (`insecureAcceptAnything`), and logs which. skopeo 1.14.0 rewrites an OCI index whose descriptors carry fields it doesn't know (such as `artifactType`), which changes the index's digest; the default version keeps it. `--preserve-digests` in `extra_args` makes that an error.

**`scripts/inspect.sh`**: Runs `skopeo inspect --raw` and `skopeo manifest-digest` first, exports that digest, then reads the requested output for the image pinned to that digest (`docker://` names only), so the digest and the output always describe the same manifest. With `raw` alone, the first read is the output. `extra_args` goes to both reads, so `--format`, `--raw` and `--config` in it are refused.

**`scripts/list_tags.sh`**: Writes `tags_file` by reading skopeo's indented JSON line by line. A tag can't hold a quote or backslash, so nothing needs unescaping; anything that isn't a tag fails the step. `tags_file` needs a `docker://` repository, since skopeo lists references for an archive.

Every skopeo call ends its options with `--`, so a name that starts with `-` is never read as a flag. skopeo needs `--tls-verify=false` (or `--src-`/`--dest-tls-verify=false`) for a registry without TLS, even on localhost. The scripts pass the TLS settings whether true or false: an omitted flag falls back to `registries.conf`, which can mark a registry insecure. `list_tags` reads the tags whatever their indentation.

### CI Pipeline (`.circleci/`)

- `config.yml` - Setup workflow: `test-install` (`tests/install_test.sh`, against a stand-in Go toolchain), `test-env-subst` (env subst and shell conventions), `test-commands` (`tests/login_test.sh` and `tests/commands_test.sh` against a stand-in skopeo), orb-tools lint, pack and review, shellcheck.
- `test-deploy.yml`:
  - `command-test`: builds the default version on cimg/base, checks that a second install takes it from the cache, and copies a public image to an OCI layout there, which has no `policy.json`.
  - `checksum-test`: the unlisted 1.13.3 fails closed; `known_versions` builds it.
  - `arm64-test`: a native arm64 build must match the table entry cross-built on amd64, and a second install takes it from the cache.
  - `registry-test`: a matrix over skopeo 1.14.0 and the default version, with a `registry:2` with htpasswd auth on a machine executor. It checks:
    - that a wrong password fails the orb's `login.sh`;
    - that copying `cgr.dev/chainguard/static:latest`, pinned to the digest it reads first, works whole and as linux/arm64;
    - the exported digests against the source's and the registry's;
    - `inspect`'s digest and saved output;
    - `list_tags`' tags file;
    - that docker reads the credentials `login` stored;
    - that the registry refuses skopeo after `logout`.

  Publishing runs on `v*` tags.

## Linting

YAML linting uses `.yamllint` config (extends "relaxed", 200-char line limit). Shell scripts are linted with shellcheck via the CI pipeline.

Scripts pass parameter values to `circleci env subst` on stdin, as `skopeo_subst` does. Passed as an argument, a value starting with `-` is parsed as a CLI flag. `tests/env_subst_test.sh` enforces this.

## Shell conventions

Every script in `src/scripts/` except the shared install code follows the conventions all juburr orbs share. `tests/shell_conventions_test.sh` checks the mechanical ones; it is identical in every orb, so never edit it.

- Line 1 is `#!/bin/bash` and the first command is `set -euo pipefail` (the library in `lib/` has no `set` line). No `set +o history`, never xtrace; `login.sh` runs `set +o xtrace` with a one-line comment.
- Under `-u`, use `${VAR:-}` for variables that may be unset. `PARAM_*` values the command YAML always sets are read directly, so tests that run a script directly must set every one of them.
- Expand an array that can be empty as `${arr[@]+"${arr[@]}"}`, not `"${arr[@]}"`: under `-u`, bash before 4.4 treats an empty array as unset and aborts with "unbound variable", and the orb supports bash 4.0+. The tests run the scripts with the bash first on the `PATH`, so put a bash 4.3 there to check this locally.
- `ERROR: ` and `WARN: ` messages go to stderr (`>&2` on every line of the message); everything else goes to stdout. Every non-zero exit prints an `ERROR:` line first, unless the failing tool already explained itself.
- `$BASH_ENV` exports use `printf 'export %s=%q\n'`; `eval` only runs orb code (`"${SCRIPT_SKOPEO_LIB}"`). Secrets never go on a command line, and curl that sends credentials or fetches trusted content uses `--fail` and `--proto '=https'`.
- Temporary files and directories come from `mktemp` and are removed by one EXIT trap per script (a second `trap ... EXIT` replaces the first).

## Naming

Command names are skopeo's own subcommands, in snake_case (`list_tags` for `list-tags`). Parameters that map onto one skopeo flag take its long name in snake_case (`multi_arch`, `src_tls_verify`, `dest_tls_verify`, `tls_verify`, `raw`, `config`, `no_tags`); positional arguments take skopeo's names for them (`source`/`destination` for copy, `image`). Two exceptions: `list_tags`' argument is `repository`, which is what skopeo's docs say it is, and `login`/`logout`'s `registry` follows oras-orb, crane-orb, helm-orb and container-ops-orb. Plumbing matches the other juburr orbs:
- credentials are `env_var_name` parameters named `username` and `password` (defaults `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`, shared with container-ops-orb, helm-orb, oras-orb and crane-orb);
- variables a command writes are `<thing>_env_var`;
- files it writes are `<thing>_file`;
- pass-through arguments are `extra_args`.

## Verification

Before committing changes, verify work locally if tools are available on the system:
- Run `shellcheck src/scripts/*.sh src/scripts/lib/*.sh tests/*.sh` to lint shell scripts
- Run every `tests/*_test.sh`
- Run `circleci orb pack src/ > orb.yml && circleci orb validate orb.yml` to validate the orb structure
- For changes to a command, also run it against a real registry that requires a login, under skopeo 1.14.0 and the default version, as `registry-test` does
- For changes to `skopeo_build` or `SKOPEO_GO_VERSION`, generate every table entry again with `install_hash.sh`, since they change the binary, and bump the cache key version in install.yml
