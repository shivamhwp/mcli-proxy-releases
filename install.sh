#!/bin/sh

set -eu

repository="shivamhwp/mcli-proxy-releases"
release_version="${MCLI_VERSION:-latest}"
install_directory="${MCLI_INSTALL_DIR:-${HOME}/.local/bin}"
github_token="${MCLI_GITHUB_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
custom_release_url="${MCLI_RELEASE_URL:-}"

step() {
  printf '\n[%s/7] %s\n' "$1" "$2"
}

step 1 "detecting platform"

case "$(uname -s)" in
  Darwin) operating_system="darwin" ;;
  Linux) operating_system="linux" ;;
  *)
    echo "mcli does not support $(uname -s)" >&2
    exit 1
    ;;
esac

case "$(uname -m)" in
  arm64 | aarch64) architecture="arm64" ;;
  x86_64 | amd64) architecture="x64" ;;
  *)
    echo "mcli does not support $(uname -m)" >&2
    exit 1
    ;;
esac

asset="mcli-${operating_system}-${architecture}"
printf 'target: %s\n' "${asset}"

if [ -n "${custom_release_url}" ]; then
  release_url="${custom_release_url%/}"
elif [ "${release_version}" = "latest" ]; then
  release_url="https://github.com/${repository}/releases/latest/download"
else
  case "${release_version}" in
    v*) tag="${release_version}" ;;
    *) tag="v${release_version}" ;;
  esac
  release_url="https://github.com/${repository}/releases/download/${tag}"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/mcli-install.XXXXXX")"
trap 'rm -rf "${temporary_directory}"' EXIT INT TERM

download() {
  source_url="$1"
  destination="$2"
  if [ -n "${github_token}" ]; then
    curl --fail --show-error --location --retry 3 --progress-bar \
      --header "Authorization: Bearer ${github_token}" \
      --output "${destination}" "${source_url}"
  else
    curl --fail --show-error --location --retry 3 --progress-bar \
      --output "${destination}" "${source_url}"
  fi
}

step 2 "downloading ${asset}"
download "${release_url}/${asset}" "${temporary_directory}/${asset}"

step 3 "downloading SHA256SUMS"
download "${release_url}/SHA256SUMS" "${temporary_directory}/SHA256SUMS"

step 4 "verifying checksum"
expected_checksum="$(awk -v name="${asset}" '$2 == name || $2 == "*" name { print $1; exit }' "${temporary_directory}/SHA256SUMS")"
if [ -z "${expected_checksum}" ]; then
  echo "SHA256SUMS does not contain ${asset}" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  actual_checksum="$(sha256sum "${temporary_directory}/${asset}" | awk '{ print $1 }')"
elif command -v shasum >/dev/null 2>&1; then
  actual_checksum="$(shasum -a 256 "${temporary_directory}/${asset}" | awk '{ print $1 }')"
else
  echo "mcli needs sha256sum or shasum to verify the download" >&2
  exit 1
fi

if [ "${actual_checksum}" != "${expected_checksum}" ]; then
  echo "checksum mismatch for ${asset}" >&2
  exit 1
fi

step 5 "installing binary"
mkdir -p "${install_directory}"
staged_binary="${install_directory}/.mcli.$$.install"
install -m 0755 "${temporary_directory}/${asset}" "${staged_binary}"
mv -f "${staged_binary}" "${install_directory}/mcli"

installed_version="$(${install_directory}/mcli --version)"
printf 'installed at %s/mcli\n' "${install_directory}"

step 6 "configuring shell"
case ":${PATH}:" in
  *":${install_directory}:"*) printf '%s is already in PATH\n' "${install_directory}" ;;
  *)
    shell_name="${SHELL##*/}"
    if [ "${shell_name}" = "fish" ]; then
      if command -v fish >/dev/null 2>&1 && fish -c 'fish_add_path --universal $argv[1]' -- "${install_directory}"; then
        printf 'added %s to Fish PATH\n' "${install_directory}"
      else
        printf "add to Fish PATH: fish_add_path '%s'\n" "${install_directory}"
      fi
    else
      echo "add to PATH: export PATH=\"${install_directory}:\$PATH\""
    fi
    ;;
esac

step 7 "mcli ${installed_version} is ready"
printf 'next: mcli setup\n'
