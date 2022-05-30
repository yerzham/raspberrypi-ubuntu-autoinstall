#!/bin/bash

# THIRD-PARTY SOFTWARE NOTICE

# This file was derived (date: 29.05.2022) from a 
# covertsh/ubuntu-autoinstall-generator repository located at 
# https://github.com/covertsh/ubuntu-autoinstall-generator and distributed 
# under the following license, located in `LICENSE`:

# ================ [LICENSE BEGIN] ================
# MIT License

# Copyright (c) 2020 covertsh

# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:

# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.

# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ================ [LICENSE END] ================

# Subsequent changes to the software code are distributed under the license
# located in 'LICENSE' of this repository.

set -Eeuo pipefail

function cleanup() {
        trap - SIGINT SIGTERM ERR EXIT
        if [ -n "${tmpdir+x}" ]; then
                rm -rf "$tmpdir"
                log "🚽 Deleted temporary working directory $tmpdir"
        fi
        if [ ! -z "$loop" ]; then
                log "📦 Unmounting an image..."
                udisksctl unmount -b  "${loop}p1" &>/dev/null
                udisksctl loop-delete -b "$loop" &>/dev/null
                log "🔁 Deleted loop $loop"
        fi
        
}

trap cleanup SIGINT SIGTERM ERR EXIT
script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
[[ ! -x "$(command -v date)" ]] && echo "💥 date command not found." && exit 1
today=$(date +"%Y-%m-%d")

function log() {
        echo >&2 -e "[$(date +"%Y-%m-%d %H:%M:%S")] ${1-}"
}

function die() {
        local msg=$1
        local code=${2-1} # Bash parameter expansion - default exit status 1. See https://wiki.bash-hackers.org/syntax/pe#use_a_default_value
        log "$msg"
        exit "$code"
}

usage() {
        cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-a] [-e] [-u user-data-file] [-m meta-data-file] [-k] [-c] [-r] [-s source-image-file] [-d destination-image-file]

💁 This script will create fully-automated Ubuntu 20.04 Focal Fossa installation media.

Available options:

-h, --help              Print this help and exit
-v, --verbose           Print script debug info
-a, --all-in-one        Bake user-data and meta-data into the generated image. By default you will
                        need to boot systems with a CIDATA volume attached containing your
                        autoinstall user-data and meta-data files.
                        For more information see: https://ubuntu.com/server/docs/install/autoinstall-quickstart
-e, --use-hwe-kernel    Force the generated image to boot using the hardware enablement (HWE) kernel. Not supported
                        by early Ubuntu 20.04 release images.
-u, --user-data         Path to user-data file. Required if using -a
-m, --meta-data         Path to meta-data file. Will be an empty file if not specified and using -a
-k, --no-verify         Disable GPG verification of the source image file. By default SHA256SUMS-$today and
                        SHA256SUMS-$today.gpg in ${script_dir} will be used to verify the authenticity and integrity
                        of the source image file. If they are not present the latest daily SHA256SUMS will be
                        downloaded and saved in ${script_dir}. The Ubuntu signing key will be downloaded and
                        saved in a new keyring in ${script_dir}
-c, --no-md5            Disable MD5 checksum on boot
-r, --use-release-image   Use the current release image instead of the daily image. The file will be used if it already
                        exists.
-s, --source            Source image file. By default the latest daily image for Ubuntu 20.04 will be downloaded
                        and saved as ${script_dir}/ubuntu-original-$today.image
                        That file will be used by default if it already exists.
-d, --destination       Destination image file. By default ${script_dir}/ubuntu-autoinstall-$today.image will be
                        created, overwriting any existing file.
EOF
        exit
}

function parse_params() {
        # default values of variables set from params
        user_data_file=''
        meta_data_file=''
        download_url="https://cdimage.ubuntu.com/ubuntu-server/jammy/daily-preinstalled/current/"
        download_img="jammy-preinstalled-server-arm64+raspi.img.xz"
        original_img="ubuntu-original-$today.img.xz"
        source_img="${script_dir}/${original_img}"
        sha_suffix="${today}"
        gpg_verify=1
        all_in_one=0
        use_hwe_kernel=0
        md5_checksum=1
        use_release_image=0

        while :; do
                case "${1-}" in
                -h | --help) usage ;;
                -v | --verbose) set -x ;;
                -a | --all-in-one) all_in_one=1 ;;
                -e | --use-hwe-kernel) use_hwe_kernel=1 ;;
                -c | --no-md5) md5_checksum=0 ;;
                -k | --no-verify) gpg_verify=0 ;;
                -r | --use-release-image) use_release_image=1 ;;
                -u | --user-data)
                        user_data_file="${2-}"
                        shift
                        ;;
                -s | --source)
                        source_img="${2-}"
                        shift
                        ;;
                -m | --meta-data)
                        meta_data_file="${2-}"
                        shift
                        ;;
                -?*) die "Unknown option: $1" ;;
                *) break ;;
                esac
                shift
        done

        log "👶 Starting up..."

        # check required params and arguments
        [[ -z "${user_data_file}" ]] && die "💥 user-data file was not specified."
        [[ ! -f "$user_data_file" ]] && die "💥 user-data file could not be found."
        [[ -n "${meta_data_file}" ]] && [[ ! -f "$meta_data_file" ]] && die "💥 meta-data file could not be found."

        if [ "${source_img}" != "${script_dir}/${original_img}" ]; then
                [[ ! -f "${source_img}" ]] && die "💥 Source image file could not be found."
        fi

        if [ "${use_release_image}" -eq 1 ]; then
                download_url="https://cdimage.ubuntu.com/releases/22.04/release/"
                log "🔎 Checking for current release..."
                download_img=$(curl -sSL "${download_url}" | grep -oP 'ubuntu-22\.04\.{0,1}\d*-preinstalled-server-arm64\+raspi\.img\.xz' | head -n 1)
                original_img="${download_img}"
                source_img="${script_dir}/${download_img}"
                current_release=$(echo "${download_img}" | cut -f2 -d-)
                sha_suffix="${current_release}"
                log "💿 Current release is ${current_release}"
        fi

        source_img=$(realpath "${source_img}")

        return 0
}

ubuntu_gpg_key_id="843938DF228D22F7B3742BC0D94AA3F0EFE21092"

parse_params "$@"

tmpdir=$(mktemp -d)

if [[ ! "$tmpdir" || ! -d "$tmpdir" ]]; then
        die "💥 Could not create temporary working directory."
else
        log "📁 Created temporary working directory $tmpdir"
fi

log "🔎 Checking for required utilities..."
[[ ! -x "$(command -v udisksctl)" ]] && die "💥 udisksctl is not installed. On Ubuntu, install  the 'udisks2' package."
[[ ! -x "$(command -v sed)" ]] && die "💥 sed is not installed. On Ubuntu, install the 'sed' package."
[[ ! -x "$(command -v curl)" ]] && die "💥 curl is not installed. On Ubuntu, install the 'curl' package."
[[ ! -x "$(command -v gpg)" ]] && die "💥 gpg is not installed. On Ubuntu, install the 'gpg' package."
log "👍 All required utilities are installed."

if [ ! -f "${source_img}" ]; then
        log "🌎 Downloading image ${source_img}..."
        curl -NsSL "${download_url}/${download_img}" -o "${source_img}"
        log "👍 Downloaded and saved to ${source_img}"
else
        log "☑️ Using existing ${source_img} file."
        if [ ${gpg_verify} -eq 1 ]; then
                if [ "${source_img}" != "${script_dir}/${original_img}" ]; then
                        log "⚠️ Automatic GPG verification is enabled. If the source image file is not the latest daily or release image, verification will fail!"
                fi
        fi
fi

if [ ${gpg_verify} -eq 1 ]; then
        if [ ! -f "${script_dir}/SHA256SUMS-${sha_suffix}" ]; then
                log "🌎 Downloading SHA256SUMS & SHA256SUMS.gpg files..."
                curl -NsSL "${download_url}/SHA256SUMS" -o "${script_dir}/SHA256SUMS-${sha_suffix}"
                curl -NsSL "${download_url}/SHA256SUMS.gpg" -o "${script_dir}/SHA256SUMS-${sha_suffix}.gpg"
        else
                log "☑️ Using existing SHA256SUMS-${sha_suffix} & SHA256SUMS-${sha_suffix}.gpg files."
        fi

        if [ ! -f "${script_dir}/${ubuntu_gpg_key_id}.keyring" ]; then
                log "🌎 Downloading and saving Ubuntu signing key..."
                gpg -q --no-default-keyring --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" --keyserver "hkp://keyserver.ubuntu.com" --recv-keys "${ubuntu_gpg_key_id}"
                log "👍 Downloaded and saved to ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        else
                log "☑️ Using existing Ubuntu signing key saved in ${script_dir}/${ubuntu_gpg_key_id}.keyring"
        fi

        log "🔐 Verifying ${source_img} integrity and authenticity..."
        gpg -q --keyring "${script_dir}/${ubuntu_gpg_key_id}.keyring" --verify "${script_dir}/SHA256SUMS-${sha_suffix}.gpg" "${script_dir}/SHA256SUMS-${sha_suffix}" 2>/dev/null
        if [ $? -ne 0 ]; then
                rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
                die "👿 Verification of SHA256SUMS signature failed."
        fi

        rm -f "${script_dir}/${ubuntu_gpg_key_id}.keyring~"
        digest=$(sha256sum "${source_img}" | cut -f1 -d ' ')
        set +e
        grep -Fq "$digest" "${script_dir}/SHA256SUMS-${sha_suffix}"
        if [ $? -eq 0 ]; then
                log "👍 Verification succeeded."
                set -e
        else
                die "👿 Verification of image digest failed."
        fi
else
        log "🤞 Skipping verification of source image."
fi


log "🔧 Extracting image..."
unxz -f -k $source_img
loop=$(udisksctl loop-setup -f ${source_img::-3} | grep -o '[^ ]\+$' | head --bytes -2)
log "🔁 Created loop $loop"
if lsblk | grep -oq '${loop}p1'; then
        mount=$(lsblk | grep -o '${loop}p1.*' | grep -o '[^ ]\+$')
else
        mount=$(udisksctl mount -b ${loop}p1 | grep -o '[^ ]\+$')
fi
log "👍 Mounted system-boot to $mount"


if [ ! -f "$mount/user-data" ] || [ ! -f "$mount/meta-data" ]; then
        udisksctl unmount -b  "${loop}p1"
        udisksctl loop-delete -b "$loop"
        die "👿 Image first partition has no user-data or meta-data. Probably wrong partition or image."
fi

log "🧩 Adding user-data and meta-data files..."
rm "$mount/user-data"
cp "$user_data_file" "$mount/user-data"
if [ -n "${meta_data_file}" ]; then
        rm "$mount/meta-data"
        cp "$meta_data_file" "$tmpdir/meta-data"
fi
log "👍 Added cloud-config data."


die "✅ Completed." 0
