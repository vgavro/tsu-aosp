#!/usr/bin/bash
set -e
# vim: noexpandtab copyindent preserveindent softtabstop=0 shiftwidth=4 tabstop=4

# Copyright (c) 2020, Cswl C. https://github.com/cswl
# This software is licensed under the ISC Liscense.
# https://github.com/cswl/tsu/blob/v8/LICENSE.md

### tsu
_TSU_VERSION="8.6.1"

log_DEBUG() { __debug_wrapper() { :; }; }

gather_debug_info() {
	echo "Environment: "
	env
	echo "============================"
	dpkg --print-architecture
	echo "Android version:"
	getprop ro.build.version.release
	echo "Android device:"
	getprop ro.product.manufacturer
	getprop ro.product.model
	uname -a

} >>"$LOG_FILE"

# Allow debugging with a long option
if [[ "$1" == '--dbg' ]]; then
	_TSU_DEBUG=true
	printf -v LOG_FILE "%(%Y%m%d)T"
	LOG_FILE="./tsu_debug_$LOG_FILE"
	gather_debug_info
	set -x
	shift
fi

## Support for busybox style calling convention.
## This works because we don't actually `readlink` the script location.
_TSU_CALL="${BASH_SOURCE[0]##*/}"
if [[ "$_TSU_CALL" == "sudo" ]]; then
	_TSU_AS_SUDO=true
fi

show_usage() {
	cat <<"EOF"
#SHOW_USAGE_BLOCK
EOF
}

show_usage_sudo() {
	cat <<"EOF"
sudo - run commands as root or another user 
  usage: sudo command 
  usage: sudo [-E] [-u USER] command 

    Options:
      -E          Preserve environment variables from the current shell.
      -u USER 	Switch to USER instead of root..
EOF
}

# Defaults in Termux and Android
TERMUX_FS="/data/data/com.termux/files"
TERMUX_PREFIX="$TERMUX_FS/usr"
TERMUX_PATH="$TERMUX_PREFIX/bin:$TERMUX_PREFIX/bin/applets"
ROOT_HOME="$TERMUX_FS/home/.suroot"
ANDROID_SYSPATHS="/system/bin:/system/xbin"
EXTRA_SYSPATHS="/sbin:/sbin/bin:/vendor/bin"
#ANDROID_ASROOT_SYSPATHS="/bin:/xbin"

# Some constants that may change in future.
BB_MAGISK="/sbin/.magisk/busybox"

# Options parsing

# Loop through arguments and process them
log_DEBUG TSU_AS_SUDO
if [[ "$_TSU_AS_SUDO" == true ]]; then
	# Handle cases where people do `sudo su`
	if [[ "$1" == "su" ]]; then
		unset _TSU_AS_SUDO
	fi

	_is_pos() {
		for e in -u --user -E --preserve-enviroment; do [[ "$e" == "$1" ]] && return 1; done
		return 0
	}

	for arg in "$@"; do

		# It is important to break as soon as we see a positional argument
		# Otherwise `sudo id -u` or `sudo some_cmd -E` wont work as expected

		if _is_pos "$arg"; then break; fi

		case $arg in
		-u | --user)
			SWITCH_USER="$2"
			shift
			shift
			;;
		-E | --preserve-enviroment)
			ENVIRONMENT_PRESERVE=true
			shift
			;;
		esac
	done

fi

log_DEBUG _TSU_AS_SUDO
if [[ -z "$_TSU_AS_SUDO" ]]; then
	for arg in "$@"; do
		case $arg in
		-p | --syspre)
			PREPEND_SYSTEM_PATH=true
			shift
			;;
		-s | --shell)
			ALT_SHELL="$2"
			shift
			shift
			;;
		--version)
			echo "tsu - $_TSU_VERSION"
			exit
			;;
		-h | --help)
			show_usage
			exit
			;;

		*)
			POS_ARGS+=("$1")
			shift
			;;
		esac
	done

	SWITCH_USER="${POS_ARGS[0]}"
fi

declare -A EXP_ENV

env_path_helper() {

	# We will try to match the default behavior of normal linux su
	# Unless the user specifically asks to preserve the enviroment,
	# We create a fresh new one.
	log_DEBUG "${FUNCNAME[0]}"

	log_DEBUG SWITCH_USER
	if [[ -z "$SWITCH_USER" ]]; then
		## By default we start a fresh root shell with HOME set to that of the root home

		NEW_HOME="$ROOT_HOME"
		EXP_ENV[TMPDIR]="$ROOT_HOME/.tmp"
		# Create $TMPDIR, and $HOME, if they do not exist
		[[ -d "${EXP_ENV[TMPDIR]}" ]] || mkdir -p "${EXP_ENV[TMPDIR]}"

		EXP_ENV[PREFIX]="$PREFIX"

		# Empty LD_PRELOAD cause problems on some systems
		[[ -n "$LD_PRELOAD" ]] && EXP_ENV[LD_PRELOAD]="$LD_PRELOAD"

		# Android versions prior to 7.0 will break if LD_LIBRARY_PATH is set
		log_DEBUG "LD_LIBRARY_PATH"
		if [[ -n "$LD_LIBRARY_PATH" ]]; then
			SYS_LIBS="/system/lib64"
			EXP_ENV[LD_LIBRARY_PATH]="$LD_LIBRARY_PATH:$SYS_LIBS"
		fi

		log_DEBUG _TSU_AS_SUDO
		if [[ "$_TSU_AS_SUDO" == true ]]; then
			# sudo copies PATH variable, so most user binaries can run as root
			# tested with `sudo env` version 1.8.31p1
			NEW_PATH="$PATH"
			EXP_ENV[SUDO_GID]="$(id -g)"
			EXP_ENV[SUDO_USER]="$(id -un)"
			EXP_ENV[SUDO_USER]="$(id -u)"
		else
			NEW_PATH="$TERMUX_PATH"
			ASP="${ANDROID_SYSPATHS}:${EXTRA_SYSPATHS}"
			# Should we add /system/* paths:
			# Some Android utilities work. but some break
			log_DEBUG "PREPEND_SYSTEM_PATH"
			if [[ -n "$PREPEND_SYSTEM_PATH" ]]; then
				NEW_PATH="$ASP:$NEW_PATH"
			else
				NEW_PATH="$NEW_PATH:$ASP"
			fi
		fi

	else
		# Other uid in the system cannot run Termux binaries
		NEW_HOME="/"
		NEW_PATH="$ANDROID_SYSPATHS"
	fi

	# We create a new environment cause the one on the
	# user Termux enviroment may be polluted with startup scripts
	EXP_ENV[PATH]="$NEW_PATH"
	EXP_ENV[HOME]="$NEW_HOME"
	EXP_ENV[TERM]="xterm-256color"

	[[ -z "$_TSU_DEBUG" ]] || set +x
	## Android specific exports: Need more testing.
	EXP_ENV[ANDROID_ROOT]="$ANDROID_ROOT"
	EXP_ENV[ANDROID_DATA]="$ANDROID_DATA"
	[[ -z "$_TSU_DEBUG" ]] || set -x
}

root_shell_helper() {
	log_DEBUG "${FUNCNAME[0]}"

	if [[ -n "$SWITCH_USER" ]]; then
		ROOT_SHELL="/system/bin/sh"
		return
	fi
	# Selection of shell, checked in this order.
	# user defined shell -> user's login shell
	# bash ->  sh
	log_DEBUG "ALT_SHELL"
	if [[ "$ALT_SHELL" == "system" ]]; then
		ROOT_SHELL="/system/bin/sh"
	elif [[ -n "$ALT_SHELL" ]]; then
		# Expand //usr/ to /usr/
		ALT_SHELL_EXPANDED="${ALT_SHELL/\/usr\//$TERMUX_PREFIX\/}"
		ROOT_SHELL="$ALT_SHELL_EXPANDED"
	elif [[ -x "$HOME/.termux/shell" ]]; then
		ROOT_SHELL="$(readlink -f -- "$HOME/.termux/shell")"
	elif [[ -x "$PREFIX/bin/bash" ]]; then
		ROOT_SHELL="$PREFIX/bin/bash"
	else
		ROOT_SHELL="$PREFIX/bin/sh"
	fi
}

log_DEBUG _TSU_AS_SUDO
if [[ "$_TSU_AS_SUDO" == true ]]; then
	if [[ -z "$1" ]]; then
		show_usage_sudo
		exit 1
	fi
	log_DEBUG ENVIRONMENT_PRESERVE
	[[ -n "$ENVIRONMENT_PRESERVE" ]] || env_path_helper
else
	root_shell_helper
	env_path_helper
	set -- "$ROOT_SHELL"
fi

SU_BINARY_SEARCH=("/system/xbin/su" "/system/bin/su" "/su/bin/su")

# On some systems with other root methods `/sbin` is inacessible.
if [[ -x "/sbin" ]]; then
	SU_BINARY_SEARCH+=("/sbin/su" "/sbin/bin/su")
else
	SKIP_SBIN=1
fi

# Unset all Termux LD_* enviroment variables to prevent symbols missing , dlopen()ing of wrong libs.
ENV=()
if [[ -n "$ENVIRONMENT_PRESERVE" ]]; then
	while IFS='' read -r line; do ENV+=("$line"); done < <(env)
	[[ -n "$LD_PRELOAD" ]] && EXP_ENV[LD_PRELOAD]="$LD_PRELOAD"
	[[ -n "$LD_LIBRARY_PATH" ]] && EXP_ENV[LD_LIBRARY_PATH]="$LD_LIBRARY_PATH"
fi
unset LD_LIBRARY_PATH
unset LD_PRELOAD

## Build the environment
[[ -z "$_TSU_DEBUG" ]] || set +x
ENV_BUILT=()

for key in "${!EXP_ENV[@]}"; do
	ENV_BUILT+=("$key=${EXP_ENV[$key]}")
done
[[ -z "$_TSU_DEBUG" ]] || set -x

### TODO: Implement this cleanly.

### ----- MAGISKSU
# shellcheck disable=SC2117
if [[ -z "$SKIP_SBIN" && -x "/sbin/su" && "$(/sbin/su -v)" == *"MAGISKSU" ]]; then
	# We are on Magisk su
	su_args=("/sbin/su")

	if [[ -n "$ENVIRONMENT_PRESERVE" ]]; then
		su_cmd+=("env" "${ENV[@]}" "PATH=$BB_MAGISK:$PATH" "${ENV_BUILT[@]}")
	else
		su_cmd+=("env" "-i" "PATH=$BB_MAGISK:$PATH" "${ENV_BUILT[@]}")
	fi
	su_cmd+=("$@")
	su_args+=( "-c" "$(printf '%q ' "${su_cmd[@]}")" )
	[[ -z "$SWITCH_USER" ]] || su_args+=("$SWITCH_USER")
	exec "${su_args[@]}"
	##### ----- END MAGISKSU
else
	##### ----- OTHERS SU
	for SU_BINARY in "${SU_BINARY_SEARCH[@]}"; do
		if [[ -x "$SU_BINARY" ]]; then
			SU_HELP="$($SU_BINARY --help 2>&1)"
			if [[
				-n "$SU_AOSP" ||
				# https://android.googlesource.com/platform/system/extras/+/95f7685/su/su.c
				"$SU_HELP" == *"usage: su [UID[,GID[,GID2]...]] [COMMAND [ARG...]]"* ||
				# https://android.googlesource.com/platform/system/extras/+/refs/heads/android10-mainline-media-release/su/su.cpp
				"$SU_HELP" == *"usage: su [WHO [COMMAND...]]"*
			]]; then
				# This is AOSP su without -c argument
				su_args=("$SU_BINARY")
				# Default uid is required
				[[ -z "$SWITCH_USER" ]] && su_args+=("0") || su_args+=("$SWITCH_USER")
				if [[ -n "$ENVIRONMENT_PRESERVE" ]]; then
					su_cmd=("env" "${ENV[@]}" "${ENV_BUILT[@]}")
				else
					su_cmd=("env" "-i" "${ENV_BUILT[@]}")
				fi
				su_cmd+=("$@")
				exec "${su_args[@]}" "${su_cmd[@]}"
			else
				su_args=("$SU_BINARY")

				# Let's use the system toybox/toolbox for now
				if [[ -n "$ENVIRONMENT_PRESERVE" ]]; then
					su_cmd=("env" "${ENV[@]}" "${ENV_BUILT[@]}")
				else
					su_cmd=("env" "-i" "${ENV_BUILT[@]}")
				fi
				su_cmd+=("$@")
				su_args+=( "-c" "$(printf '%q ' "${su_cmd[@]}")" )

				[[ -z "$SWITCH_USER" ]] || su_args+=("$SWITCH_USER")
				exec "${su_args[@]}"
			fi
		fi
	done
fi
##### ----- END OTHERS SU

# We didnt find any su binary
set +x
printf -- "No superuser binary detected. \n"
printf -- "Are you rooted? \n"

if [[ -n "$_TSU_DEBUG" ]]; then
	echo "-------------------------------------"
	echo "tsu ran in debug mode."
	echo "Full log can be found in tsu_debug.log"
	echo "Report any issues to: https://github.com/cswl/tsu "
fi

exit 1
