#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0
#
# Copyright (c) 2013-2026 Igor Pecovnik, igor@armbian.com
#
# This file is a part of the Armbian Build Framework
# https://github.com/armbian/build/

function deploy_qemu_binary_to_chroot() {
	declare chroot_target="${1}" caller="${2}"
	display_alert "deploy_qemu_binary_to_chroot" "deploy_qemu_binary_to_chroot '${chroot_target}' during '${caller}'" "debug"

	# Only deploy the binary if we're actually building a non-native architecture.
	if dpkg-architecture -e "${ARCH}"; then
		display_alert "Native build" "not deploying qemu binary during ${caller}" "debug"
		return 0
	fi

	declare src_host="/usr/bin/${QEMU_BINARY}"
	declare dst_target="${chroot_target}/usr/bin/${QEMU_BINARY}"
	declare dst_target_bkp="${dst_target}.armbian.orig"

	# Assume we're getting a clean base to work with. Namely, we count on the rootfs cache to _not_ have left a dangling binary.
	# If the dst_target already exists, it means the target actually has the qemu-static package installed.
	# In that case, we preserve the original binary; it will be restored by the undeploy.
	if [[ -f "${dst_target}" ]]; then
		display_alert "Preserving existing qemu binary" "${QEMU_BINARY} during ${caller}" "info"
		run_host_command_logged mv -v "${dst_target}" "${dst_target_bkp}"
	fi

	display_alert "Deploying qemu-user-static binary to chroot" "${QEMU_BINARY} during ${caller}" "info"
	run_host_command_logged cp -pv "${src_host}" "${dst_target}"

	return 0
}

function undeploy_qemu_binary_from_chroot() {
	declare chroot_target="${1}" caller="${2}"
	display_alert "undeploy_qemu_binary_from_chroot" "undeploy_qemu_binary_from_chroot '${chroot_target}' during '${caller}'" "debug"

	# Only deploy the binary if we're actually building a non-native architecture.
	if dpkg-architecture -e "${ARCH}"; then
		display_alert "Native build" "not deploying qemu binary during ${caller}" "debug"
		return 0
	fi

	declare dst_target="${chroot_target}/usr/bin/${QEMU_BINARY}"
	declare dst_target_bkp="${dst_target}.armbian.orig"

	# Check the binary we deployed is there. If not, panic, as we've lost control.
	if [[ ! -f "${dst_target}" ]]; then
		exit_with_error "Missing qemu binary during undeploy_qemu_binary_from_chroot from ${caller}"
	fi

	# Remove the binary we deployed, and restore the original if we had to preserve it.
	display_alert "Removing qemu-user-static binary from chroot" "${QEMU_BINARY} during ${caller}" "info"
	run_host_command_logged rm -fv "${dst_target}"

	if [[ -f "${dst_target_bkp}" ]]; then
		display_alert "Restoring original qemu binary" "${QEMU_BINARY} during ${caller}" "info"
		run_host_command_logged mv -v "${dst_target_bkp}" "${dst_target}"
	fi

	return 0
}

# "enable arm binary format so that the cross-architecture chroot environment will work" - classic comment from 2013
# this is called from prepare-host.sh::prepare_host_noninteractive() unconditionally.
function prepare_host_binfmt_qemu() {
	# NEEDS_BINFMT=yes is set by "default build" (image build) and rootfs artifact build, which is what requires binfmt_misc to be working.
	if [[ "${NEEDS_BINFMT:-"no"}" != "yes" ]]; then
		return 0
	fi

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "Debugging binfmt - early" "/proc/sys/fs/binfmt_misc/" "debug"
		run_host_command_logged ls -la /proc/sys/fs/binfmt_misc/ || true
	fi

	if dpkg-architecture -e "${ARCH}"; then
		display_alert "Native arch build" "target ${ARCH} on host $(dpkg --print-architecture)" "cachehit"
	else
		prepare_host_binfmt_qemu_cross
	fi

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "Debugging binfmt - late" "/proc/sys/fs/binfmt_misc/" "debug"
		run_host_command_logged ls -la /proc/sys/fs/binfmt_misc/ || true
	fi

	# Actually test, using `arch-test`, that we can run binaries for the wanted architecture.
	display_alert "checking" "arch-test for '${ARCH}'" "info"
	run_host_command_logged arch-test "${ARCH}"

	# Everything should be either setup or previously correct if we get here.
	return 0
}

# The actual binfmt manipulations when cross-build is confirmed above.
function prepare_host_binfmt_qemu_cross() {
	local failed_binfmt_modprobe=0

	display_alert "Cross arch build" "target ${ARCH} on host $(dpkg --print-architecture)" "info"

	# Check if binfmt_misc is loaded; if not, try to load it, but don't fail: it might be built in.
	if grep -q "^binfmt_misc" /proc/modules; then
		display_alert "binfmt_misc is already loaded" "binfmt_misc already loaded" "debug"
	else
		display_alert "binfmt_misc is not loaded" "trying to load binfmt_misc" "debug"

		# try to modprobe. if it fails, emit a warning later, but not here.
		# this is for the in-container case, where the host already has the module, but won't let the container know about it.
		modprobe -q binfmt_misc || failed_binfmt_modprobe=1
	fi

	# Now, /proc/sys/fs/binfmt_misc/ has to be mounted. Mount, or fail with a message
	if mountpoint -q /proc/sys/fs/binfmt_misc/; then
		display_alert "binfmt_misc is already mounted" "binfmt_misc already mounted" "debug"
	else
		display_alert "binfmt_misc is not mounted" "trying to mount binfmt_misc" "debug"
		mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc/ || {
			if [[ $failed_binfmt_modprobe == 1 ]]; then
				display_alert "Failed to load binfmt_misc module" "modprobe binfmt_misc failed" "wrn"
			fi
			display_alert "Check your HOST kernel" "CONFIG_BINFMT_MISC=m is required in host kernel" "warn"
			display_alert "Failed to mount" "binfmt_misc /proc/sys/fs/binfmt_misc/" "err"
			exit_with_error "Failed to mount binfmt_misc"
		}
		display_alert "binfmt_misc mounted" "binfmt_misc mounted" "debug"
	fi

	declare host_arch
	host_arch="$(arch)"
	declare -a wanted_arches=("arm" "aarch64" "x86_64" "riscv64" "loongarch64")
	declare -A arch_aliases=(["aarch64"]="arm64" ["x86_64"]="amd64")
	display_alert "Preparing binfmts for arch" "binfmts: host '${host_arch}', wanted arches '${wanted_arches[*]}'" "debug"
	declare wanted_arch arch_alias
	for wanted_arch in "${wanted_arches[@]}"; do
		arch_alias="${arch_aliases["${wanted_arch}"]:-"${wanted_arch}"}"
		display_alert "Preparing binfmts for arch" "wanted arch '${wanted_arch}' alias '${arch_alias}'" "debug"

		if [[ "${host_arch}" == "${wanted_arch}" ]]; then
			continue
		fi

		if [[ ! -e "/proc/sys/fs/binfmt_misc/qemu-${wanted_arch}" || ! -e "/usr/share/binfmts/qemu-${wanted_arch}" ]]; then
			display_alert "Updating binfmts" "update-binfmts --enable qemu-${wanted_arch}" "debug"

			# special case: some arm64 machines cant' really run armhf binaries natively (Apple Silicon); check if that is the case and forcibly import and enable qemu-arm for them.
			if [[ "${host_arch}" == "aarch64" && "${wanted_arch}" == "arm" ]]; then
				prepare_host_binfmt_qemu_cross_arm64_host_armhf_target
			else
				run_host_command_logged update-binfmts --enable "qemu-${wanted_arch}" "&>" "/dev/null" || {
					display_alert "Failed to update binfmts" "update-binfmts --enable qemu-${wanted_arch}" "wrn"
					# Fallback: if the binfmt database entry is missing (e.g. container with namespaced
					# binfmt_misc and systemd-binfmt based qemu-user-static), create it and retry.
					if [[ ! -e "/proc/sys/fs/binfmt_misc/qemu-${wanted_arch}" && -x "/usr/bin/qemu-${wanted_arch}-static" ]]; then
						display_alert "Attempting direct binfmt registration" "qemu-${wanted_arch}" "info"
						prepare_host_binfmt_register_directly "qemu-${wanted_arch}" "/usr/bin/qemu-${wanted_arch}-static"
					fi
				}
			fi
		fi
	done
}

# Directly register a binfmt entry by creating the /usr/share/binfmts/ database file
# and importing it. This is needed when running inside containers with namespaced binfmt_misc
# (kernel 6.7+) where the host's binfmt entries are not visible and the qemu-user-static
# package uses systemd-binfmt instead of binfmt-support for registration.
function prepare_host_binfmt_register_directly() {
	local binfmt_name="${1}" interpreter="${2}"

	# Define magic bytes and masks for each architecture (standard ELF headers)
	declare -A binfmt_magic=(
		["qemu-arm"]='\x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00'
		["qemu-aarch64"]='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00'
		["qemu-x86_64"]='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x3e\x00'
		["qemu-riscv64"]='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xf3\x00'
		["qemu-loongarch64"]='\x7f\x45\x4c\x46\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x02\x01'
	)
	declare -A binfmt_mask=(
		["qemu-arm"]='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
		["qemu-aarch64"]='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
		["qemu-x86_64"]='\xff\xff\xff\xff\xff\xfe\xfe\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
		["qemu-riscv64"]='\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
		["qemu-loongarch64"]='\xff\xff\xff\xff\xff\xff\xff\xfc\x00\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff'
	)

	local magic="${binfmt_magic[${binfmt_name}]}"
	local mask="${binfmt_mask[${binfmt_name}]}"

	if [[ -z "${magic}" || -z "${mask}" ]]; then
		display_alert "No magic bytes defined for" "${binfmt_name}" "wrn"
		return 1
	fi

	# Create the binfmt-support database file
	display_alert "Creating binfmt database entry" "${binfmt_name}" "info"
	cat <<-BINFMT_MAGIC >/usr/share/binfmts/${binfmt_name}
		package qemu-user-static
		interpreter ${interpreter}
		magic ${magic}
		offset 0
		mask ${mask}
		credentials yes
		fix_binary yes
		preserve yes
	BINFMT_MAGIC
	run_host_command_logged update-binfmts --import "${binfmt_name}" || true
	run_host_command_logged update-binfmts --enable "${binfmt_name}" || {
		display_alert "update-binfmts --enable still failed, trying direct register" "${binfmt_name}" "wrn"
		# Last resort: write directly to the register file
		echo ":${binfmt_name}:M::${magic}:${mask}:${interpreter}:PF" > /proc/sys/fs/binfmt_misc/register 2>&1 || {
			display_alert "Direct binfmt registration also failed" "${binfmt_name}" "err"
			return 1
		}
	}
	# Verify
	if [[ -e "/proc/sys/fs/binfmt_misc/${binfmt_name}" ]]; then
		display_alert "binfmt entry registered successfully" "${binfmt_name}" "info"
	else
		display_alert "binfmt entry still not registered" "${binfmt_name}" "err"
		return 1
	fi
	return 0
}

function prepare_host_binfmt_qemu_cross_arm64_host_armhf_target() {
	display_alert "Trying to update binfmts - aarch64 mostly does 32-bit sans emulation, but Apple said no" "update-binfmts --enable qemu-${wanted_arch}" "debug"
	run_host_command_logged update-binfmts --enable "qemu-${wanted_arch}" "&>" "/dev/null" "||" "true" # don't fail nor produce output, which can be misleading.

	if [[ "${SHOW_DEBUG}" == "yes" ]]; then
		display_alert "Debugging arch-test" "full output" "debug"
		run_host_command_logged arch-test "||" true
	fi

	# to check, we use arch-test; if will return 0 if _either_ the host can natively run armhf, or if qemu-arm is correctly working.
	if arch-test arm; then
		display_alert "Host can run armhf natively or emulation is correctly setup already" "no need to enable qemu-arm" "debug"
	else
		display_alert "arm64 host can't run armhf natively" "importing enabling qemu-arm" "debug"
		cat <<-BINFMT_ARM_MAGIC >/usr/share/binfmts/qemu-arm
			package qemu-user-static
			interpreter /usr/bin/qemu-arm-static
			magic \x7f\x45\x4c\x46\x01\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\x28\x00
			offset 0
			mask \xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff
			credentials yes
			fix_binary no
			preserve yes
		BINFMT_ARM_MAGIC
		run_host_command_logged update-binfmts --import "qemu-${wanted_arch}"
		run_host_command_logged update-binfmts --enable "qemu-${wanted_arch}"

		# Test again using arch-test.
		display_alert "Checking if arm 32-bit emulation on arm64 works after enabling" "qemu-arm emulation" "info"
		run_host_command_logged arch-test arm
		display_alert "arm 32-bit emulation on arm64" "has been correctly setup" "cachehit"
	fi
}
