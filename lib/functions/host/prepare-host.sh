#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2023 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

# prepare_host
#
# * checks and installs necessary packages
# * creates directory structure
# * changes system settings
#
function prepare_host() {
	LOG_SECTION="prepare_host_noninteractive" do_with_logging prepare_host_noninteractive
	return 0
}

function assert_prepared_host() {
	if [[ "${PRE_PREPARED_HOST:-"no"}" == "yes" ]]; then
		return 0
	fi

	if [[ ${prepare_host_has_already_run:-0} -lt 1 ]]; then
		exit_with_error "assert_prepared_host: Host has not yet been prepared. This is a bug in armbian-next code. Please report!"
	fi
}

function check_basic_host() {
	display_alert "Checking" "basic host setup" "info"
	obtain_and_check_host_release_and_arch # sets HOSTRELEASE and validates it for sanity; also HOSTARCH
	check_host_has_enough_disk_space       # Checks disk space and exits if not enough
	check_windows_wsl2                     # checks if on Windows, on WSL2, (not 1) and exits if not supported
	wait_for_package_manager               # wait until dpkg is not locked...
}

function prepare_host_noninteractive() {
	display_alert "Preparing" "host" "info"

	# The 'offline' variable must always be set to 'true' or 'false'
	declare offline=false
	if [ "$OFFLINE_WORK" == "yes" ]; then
		offline=true
	fi

	# fix for Locales settings, if locale-gen is installed, and /etc/locale.gen exists.
	if [[ -n "$(command -v locale-gen)" && -f /etc/locale.gen ]]; then
		if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
			# @TODO: rpardini: this is bull, we're always root here. we've been pre-sudo'd.
			local sudo_prefix="" && is_root_or_sudo_prefix sudo_prefix # nameref; "sudo_prefix" will be 'sudo' or ''
			${sudo_prefix} sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
			${sudo_prefix} locale-gen
		fi
	else
		display_alert "locale-gen is not installed @host" "skipping locale-gen -- problems might arise" "warn"
	fi

	# Let's try and get all log output in English, overriding the builder's chosen or default language
	export LANG="en_US.UTF-8"
	export LANGUAGE="en_US.UTF-8"
	export LC_ALL="en_US.UTF-8"
	export LC_MESSAGES="en_US.UTF-8"

	declare -g USE_LOCAL_APT_DEB_CACHE=${USE_LOCAL_APT_DEB_CACHE:-yes} # Use SRC/cache/aptcache as local apt cache by default
	display_alert "Using local apt cache?" "USE_LOCAL_APT_DEB_CACHE: ${USE_LOCAL_APT_DEB_CACHE}" "debug"

	# if USE_LOCAL_APT_DEB_CACHE equals no, display_alert a warning, it's not a good idea.
	if [[ "${USE_LOCAL_APT_DEB_CACHE}" == "no" ]]; then
		display_alert "USE_LOCAL_APT_DEB_CACHE is set to 'no'" "not recommended" "wrn"
	fi

	if armbian_is_running_in_container; then
		display_alert "Running in container" "Adding provisions for container building" "info"
		declare -g CONTAINER_COMPAT=yes # this controls mknod usage for loop devices.

		if [[ "${MANAGE_ACNG}" == "yes" ]]; then
			display_alert "Running in container" "Disabling ACNG - MANAGE_ACNG=yes not supported in containers" "warn"
			declare -g MANAGE_ACNG=no
		fi

		SYNC_CLOCK=no
	else
		display_alert "NOT running in container" "No special provisions for container building" "debug"
	fi

	# If offline, do not try to install dependencies, manage acng, or sync the clock.
	if ! $offline; then
		# Prepare the list of host dependencies; it requires the target arch, the host release and arch
		late_prepare_host_dependencies
		install_host_dependencies "late dependencies during prepare_release"

		# Manage apt-cacher-ng, if such is the case
		[[ "${MANAGE_ACNG}" == "yes" ]] && acng_configure_and_restart_acng

		# sync clock
		if [[ $SYNC_CLOCK != no && -f /var/run/ntpd.pid ]]; then
			display_alert "ntpd is running, skipping" "SYNC_CLOCK=no" "debug"
			SYNC_CLOCK=no
		fi

		if [[ $SYNC_CLOCK != no ]]; then
			display_alert "Syncing clock" "host" "info"
			run_host_command_logged ntpdate "${NTP_SERVER:-pool.ntp.org}" || true # allow failures
		fi
	fi

	# create directory structure # @TODO: this should be close to DEST, otherwise super-confusing
	mkdir -p "${SRC}"/{cache,output} "${USERPATCHES_PATH}" "${SRC}"/output/info

	# @TODO: original: mkdir -p "${DEST}"/debs-beta/extra "${DEST}"/debs/extra "${DEST}"/{config,debug,patch} "${USERPATCHES_PATH}"/overlay "${SRC}"/cache/{sources,hash,hash-beta,toolchain,utility,rootfs} "${SRC}"/.tmp
	mkdir -p "${USERPATCHES_PATH}"/overlay "${SRC}"/cache/{sources,rootfs} "${SRC}"/.tmp

	# If offline, do not try to download/install toolchains.
	if ! $offline; then
		download_external_toolchains # Mostly deprecated, since SKIP_EXTERNAL_TOOLCHAINS=yes is the default
	fi

	prepare_host_binfmt_qemu # in qemu-static.sh as most binfmt/qemu logic is there now

	# @TODO: rpardini: this does not belong here, instead with the other templates, pre-configuration.
	[[ ! -f "${USERPATCHES_PATH}"/customize-image.sh ]] && run_host_command_logged cp -pv "${SRC}"/config/templates/customize-image.sh.template "${USERPATCHES_PATH}"/customize-image.sh
	[[ ! -f "${USERPATCHES_PATH}"/config-example.conf ]] && run_host_command_logged cp -pv "${SRC}"/config/templates/config-example.conf.template "${USERPATCHES_PATH}"/config-example.conf

	if [[ -d "${USERPATCHES_PATH}" ]]; then
		# create patches directory structure under USERPATCHES_PATH
		find "${SRC}"/patch -maxdepth 2 -type d ! -name . | sed "s%/.*patch%/$USERPATCHES_PATH%" | xargs mkdir -p
	fi

	# Reset owner of userpatches if so required
	reset_uid_owner "${USERPATCHES_PATH}" # Fix owner of files in the final destination

	declare -i -g -r prepare_host_has_already_run=1 # global, readonly.

	return 0
}

# Early: we've possibly no idea what the host release or arch we're building on, or what the target arch is. All-deps.
# Early: we've a best-guess indication of the host release, but not target. (eg: Dockerfile generate)
# Early: we're certain about the host release and arch, but not anything about the target (eg: docker build of the Dockerfile, cli-requirements)
# Late: we know everything; produce a list that is optimized for the host+target we're building. (eg: Oleg)
function early_prepare_host_dependencies() {
	if [[ "x${host_release:-}x" == "xx" ]]; then
		display_alert "Host release unknown" "host_release not set on call to early_prepare_host_dependencies" "warn"
	fi
	if [[ "x${host_arch:-}x" == "xx" ]]; then
		display_alert "Host arch unknown" "host_arch not set on call to early_prepare_host_dependencies" "debug"
	fi
	adaptative_prepare_host_dependencies
}

function late_prepare_host_dependencies() {
	[[ -z "${ARCH}" ]] && exit_with_error "ARCH is not set"
	[[ -z "${HOSTRELEASE}" ]] && exit_with_error "HOSTRELEASE is not set"
	[[ -z "${HOSTARCH}" ]] && exit_with_error "HOSTARCH is not set"
	[[ -z "${RELEASE}" ]] && display_alert "RELEASE is not set" "defaulting to host's '${HOSTRELEASE}'" "debug"

	target_arch="${ARCH}" host_release="${HOSTRELEASE}" \
		host_arch="${HOSTARCH}" target_release="${RELEASE:-"${HOSTRELEASE}"}" \
		early_prepare_host_dependencies
}

# Adaptive: used by both early & late.
function adaptative_prepare_host_dependencies() {
	if [[ "x${host_release:-"unknown"}x" == "xx" ]]; then
		display_alert "No specified host_release" "preparing for all-hosts, all-targets deps" "debug"
	else
		display_alert "Using passed-in host_release" "${host_release}" "debug"
	fi

	if [[ "x${target_arch:-"unknown"}x" == "xx" ]]; then
		display_alert "No specified target_arch" "preparing for all-hosts, all-targets deps" "debug"
	else
		display_alert "Using passed-in target_arch" "${target_arch}" "debug"
	fi

	#### Common: for all releases, all host arches, and all target arches.
	declare -a -g host_dependencies=(
		# big bag of stuff from before
		bc binfmt-support
		bison
		bsdextrautils
		libc6-dev make dpkg-dev gcc # build-essential, without g++
		ca-certificates ccache cpio
		device-tree-compiler dialog dirmngr dosfstools
		dwarves # dwarves has been replaced by "pahole" and is now a transitional package
		flex
		gawk gnupg gpg
		imagemagick # required for plymouth: converting images / spinners
		jq          # required for parsing JSON, specially rootfs-caching related.
		kmod        # this causes initramfs rebuild, but is usually pre-installed, so no harm done unless it's an upgrade
		libbison-dev libelf-dev libfdt-dev libfile-fcntllock-perl libmpc-dev libfl-dev lz4
		libncurses-dev libssl-dev libusb-1.0-0-dev
		linux-base locales lsof
		ncurses-base ncurses-term # for `make menuconfig`
		ntpsec-ntpdate #this is a more secure ntpdate
		patchutils pkg-config pv
		"qemu-user-static" "arch-test"
		rsync
		swig # swig is needed for some u-boot's. example: "bananapi.conf"
		u-boot-tools
		udev # causes initramfs rebuild, but is usually pre-installed.
		uuid-dev
		zlib1g-dev

		# by-category below
		file tree expect                         # logging utilities; expect is needed for 'unbuffer' command
		colorized-logs                           # for ansi2html, ansi2txt, pipetty
		unzip zip pigz xz-utils pbzip2 lzop zstd # compressors et al
		parted gdisk fdisk                       # partition tools @TODO why so many?
		aria2 curl axel                          # downloaders et al
		parallel                                 # do things in parallel (used for fast md5 hashing in initrd cache)
		rdfind                                   # armbian-firmware-full/linux-firmware symlink creation step
	)

	# @TODO: distcc -- handle in extension?

	### Python
	host_deps_add_extra_python # See python-tools.sh::host_deps_add_extra_python()

	### Python3 -- required for Armbian's Python tooling, and also for more recent u-boot builds. Needs 3.9+; ffi-dev is needed for some Python packages when the wheel is not prebuilt
	### 'python3-setuptools' and 'python3-pyelftools' moved to requirements.txt to make sure build hosts use the same/latest versions of these tools.
	### 'python3-dev' depends on distutils, so instead depend on libpython3-dev which doesn't.
	host_dependencies+=("python3" "libpython3-dev" "libffi-dev")

	# Needed for some u-boot's, lest "tools/mkeficapsule.c:21:10: fatal error: gnutls/gnutls.h"
	host_dependencies+=("libgnutls28-dev")

	# Some versions of U-Boot do not require/import 'python3-setuptools' properly, so add them explicitly.
	if [[ 'tag:v2022.04' == "${BOOTBRANCH:-}" || 'tag:v2022.07' == "${BOOTBRANCH:-}" ]]; then
		display_alert "Adding package to 'host_dependencies'" "python3-setuptools" "info"
		host_dependencies+=("python3-setuptools")
	fi

	### Python2 -- required for some older u-boot builds
	# Debian newer than 'bookworm' and Ubuntu newer than 'lunar'/'mantic' does not carry python2 anymore; in this case some u-boot's might fail to build.
	# Last versions to support python2 were Debian 'bullseye' and Ubuntu 'jammy'
	if [[ "bullseye jammy" == *"${host_release}"* ]]; then
		host_dependencies+=("python2" "python2-dev")
	else
		display_alert "Python2 not available on host release '${host_release}'" "ancient u-boot versions might/will fail to build" "info"
	fi

	# Only install acng if asked to.
	if [[ "${MANAGE_ACNG}" == "yes" ]]; then
		host_dependencies+=("apt-cacher-ng")
	fi

	### ARCH
	declare wanted_arch="${target_arch:-"all"}"

	if [[ "${wanted_arch}" == "amd64" || "${wanted_arch}" == "all" ]]; then
		host_dependencies+=("gcc-x86-64-linux-gnu") # from crossbuild-essential-amd64
	fi

	if [[ "${wanted_arch}" == "arm64" || "${wanted_arch}" == "all" ]]; then
		# gcc-aarch64-linux-gnu: from crossbuild-essential-arm64
		# gcc-arm-linux-gnueabi: necessary for rockchip64 (and maybe other too) ATF compilation
		host_dependencies+=("gcc-aarch64-linux-gnu" "gcc-arm-linux-gnueabi")
	fi

	if [[ "${wanted_arch}" == "armhf" || "${wanted_arch}" == "all" ]]; then
		host_dependencies+=("gcc-arm-linux-gnueabihf") # from crossbuild-essential-armhf crossbuild-essential-armel
	fi

	if [[ "${wanted_arch}" == "riscv64" || "${wanted_arch}" == "all" ]]; then
		host_dependencies+=("gcc-riscv64-linux-gnu") # crossbuild-essential-riscv64 is not even available "yet"
		host_dependencies+=("debian-archive-keyring")
	fi

	if [[ "${wanted_arch}" != "amd64" ]]; then
		host_dependencies+=("libc6-amd64-cross") # Support for running x86 binaries (under qemu on other arches)
	fi

	if [[ "${KERNEL_COMPILER}" == "clang" ]]; then
		host_dependencies+=("clang")
		host_dependencies+=("llvm")
		host_dependencies+=("lld")
	fi

	declare -g EXTRA_BUILD_DEPS=""
	call_extension_method "add_host_dependencies" <<- 'ADD_HOST_DEPENDENCIES'
		*run before installing host dependencies*
		you can add packages to install, space separated, to ${EXTRA_BUILD_DEPS} here.
	ADD_HOST_DEPENDENCIES

	if [ -n "${EXTRA_BUILD_DEPS}" ]; then
		# shellcheck disable=SC2206 # I wanna expand. @TODO: later will convert to proper array
		host_dependencies+=(${EXTRA_BUILD_DEPS})
	fi

	declare -g FINAL_HOST_DEPS="${host_dependencies[*]}"
	call_extension_method "host_dependencies_known" <<- 'HOST_DEPENDENCIES_KNOWN'
		*run after all host dependencies are known (but not installed)*
		At this point we can read `${FINAL_HOST_DEPS}`, but changing won't have any effect.
		All the dependencies, including the default/core deps and the ones added via `${EXTRA_BUILD_DEPS}`
		are determined at this point, but not yet installed.
	HOST_DEPENDENCIES_KNOWN
}

function install_host_dependencies() {
	display_alert "Installing build dependencies" "$*" "debug"

	# don't prompt for apt cacher selection. this is to skip the prompt only, since we'll manage acng config later.
	local sudo_prefix="" && is_root_or_sudo_prefix sudo_prefix # nameref; "sudo_prefix" will be 'sudo' or ''
	${sudo_prefix} echo "apt-cacher-ng    apt-cacher-ng/tunnelenable      boolean false" | ${sudo_prefix} debconf-set-selections

	# This handles the wanted list in $host_dependencies, updates apt only if needed
	# $host_dependencies is produced by early_prepare_host_dependencies()
	install_host_side_packages "${host_dependencies[@]}"

	run_host_command_logged update-ccache-symlinks

	declare -g FINAL_HOST_DEPS="${host_dependencies[*]}"

	call_extension_method "host_dependencies_ready" <<- 'HOST_DEPENDENCIES_READY'
		*run after all host dependencies are installed*
		At this point we can read `${FINAL_HOST_DEPS}`, but changing won't have any effect.
		All the dependencies, including the default/core deps and the ones added via `${EXTRA_BUILD_DEPS}`
		are installed at this point. The system clock has not yet been synced.
	HOST_DEPENDENCIES_READY

	unset FINAL_HOST_DEPS # don't leak this after the hook is done
}

function check_host_has_enough_disk_space() {
	declare -a dirs_to_check=("${DEST}" "${SRC}/cache")
	for dir in "${dirs_to_check[@]}"; do
		if [[ ! -d "${dir}" ]]; then
			display_alert "Directory not found" "Skipping disk space check for '${dir}'" "debug"
			continue
		fi
		check_dir_has_enough_disk_space "${dir}" 10 || exit_if_countdown_not_aborted 10 "Low free disk space left in '${dir}'"
	done
}

function check_dir_has_enough_disk_space() {
	declare target="${1}"
	declare -i min_free_space_gib="${2:-10}"
	declare -i free_space_bytes
	free_space_bytes=$(findmnt --noheadings --output AVAIL --bytes --target "${target}" --uniq 2> /dev/null) # in bytes
	if [[ -n "$free_space_bytes" && $((free_space_bytes / 1073741824)) -lt $min_free_space_gib ]]; then
		display_alert "Low free space left" "${target}: $((free_space_bytes / 1073741824))GiB free, ${min_free_space_gib} GiB required" "wrn"
		return 1
	fi
	display_alert "Free space left" "${target}: $((free_space_bytes / 1073741824))GiB" "debug"
	return 0
}
