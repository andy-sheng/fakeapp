#!/bin/bash
# @Author: Ethan
# @Date:   2025-11-30
# @Last Modified by:   Ethan
# @Last Modified time: 2025-11-30
# Enhanced version that accepts IPA file path and modifies Info.plist based on IPA content

working_tmp=$(mktemp -t fakeapp -d);
fakesample_tgz="$working_tmp/fakesample.tgz";
ipa_extract_tmp="$working_tmp/ipa_extract";
bundle_id_prefix="${FAKEAPP_BUNDLE_ID_PREFIX:-com.example.fakeapp}";

trap 'rm -rf "$working_tmp"' EXIT SIGHUP SIGINT SIGQUIT;

usage () {
	echo "Usage: fakeapp [--bundle-id BUNDLE_ID] [--certificate SIGNING_IDENTITY] IPA_FILE";
	echo "Try 'fakeapp --help' for more information.";
}

show_help () {
	cat <<EOF
fakeapp - Create a debuggable Xcode project from a decrypted iOS IPA.

USAGE:
  fakeapp [OPTIONS] IPA_FILE
  fakeapp skill [--client CLIENT] [--dest DIR] [--print] [--uninstall]
  fakeapp help | --help | -h

COMMANDS:
  skill                         Install the fakeapp agent skill into your AI
                                clients (Claude Code, Codex, Cursor, ...).
                                Run 'fakeapp skill --help' for details.

OPTIONS:
  -b, --bundle-id BUNDLE_ID     Bundle ID for signing the generated app.
                                Default: ${bundle_id_prefix}.<appname>
  -c, --certificate IDENTITY    Xcode code signing identity for device builds
                                (e.g. "Apple Development: Name (TEAMID)").
  -o, --output DIR              Output directory for the generated project.
                                Default: current directory. Created if missing.
      --no-symbols              Skip Objective-C symbol restoration (by default the
                                app's stripped main executable gets its ObjC class /
                                method names written back into the symbol table so
                                Xcode/LLDB backtraces show -[Class method]).
  -h, --help                    Show this help and exit.

EXAMPLES:
  # Basic
  fakeapp ~/Downloads/MyApp.ipa

  # Custom Bundle ID + signing certificate
  fakeapp --bundle-id com.example.fake.myapp \\
          --certificate "Apple Development: Name (TEAMID)" app.ipa

  # Output the generated project into a specific folder
  fakeapp --output ~/Projects/fakeapps app.ipa

ENVIRONMENT:
  FAKEAPP_BUNDLE_ID_PREFIX      Default Bundle ID prefix
                                (current: ${bundle_id_prefix})

AFTER GENERATING THE PROJECT:
  Device      : open the .xcodeproj, set Team/certificate, select a device, Cmd+R.
  Simulator   : select an iPhone Simulator and Cmd+R (Apple Silicon, no certificate).
                Mach-O is auto-patched to the simulator platform and ad-hoc signed;
                launch by the PROJECT Bundle ID, not the app's original ID.

NOTES:
  Only decrypted IPA files are supported.
EOF
}

parse_args () {
	ipa_path="";
	requested_bundle_id="";
	signing_certificate="";
	output_dir=".";
	no_symbols="";

	while [ "$#" -gt 0 ]; do
		case "$1" in
			-b|--bundle-id)
				shift;
				[ "$#" -gt 0 ] || {
					echo "ERROR: --bundle-id requires a value";
					usage;
					exit 1;
				}
				requested_bundle_id="$1";
				;;
			-c|--certificate|--signing-certificate)
				shift;
				[ "$#" -gt 0 ] || {
					echo "ERROR: --certificate requires a value";
					usage;
					exit 1;
				}
				signing_certificate="$1";
				;;
			-o|--output|--output-dir)
				shift;
				[ "$#" -gt 0 ] || {
					echo "ERROR: --output requires a value";
					usage;
					exit 1;
				}
				output_dir="$1";
				;;
			--no-symbols)
				no_symbols=1;
				;;
			-h|--help|help)
				show_help;
				exit 0;
				;;
			--)
				shift;
				break;
				;;
			-*)
				echo "ERROR: Unknown option: $1";
				usage;
				exit 1;
				;;
			*)
				[ -z "$ipa_path" ] || {
					echo "ERROR: Multiple IPA paths provided: $ipa_path and $1";
					usage;
					exit 1;
				}
				ipa_path="$1";
				;;
		esac
		shift;
	done

	while [ "$#" -gt 0 ]; do
		[ -z "$ipa_path" ] || {
			echo "ERROR: Multiple IPA paths provided: $ipa_path and $1";
			usage;
			exit 1;
		}
		ipa_path="$1";
		shift;
	done

	export ipa_path;
	export requested_bundle_id;
	export signing_certificate;
	export output_dir;
}

# --- install-skill: agent client registry ---------------------------------
# Known agent clients that consume Agent Skills (a <skills>/<name>/SKILL.md
# layout). To support another client, extend all three case statements below.
skill_known_clients () {
	echo "claude codex cursor agents";
}

skill_client_name () {
	case "$1" in
		claude) echo "Claude Code" ;;
		codex)  echo "Codex CLI" ;;
		cursor) echo "Cursor" ;;
		agents) echo "Agent Skills" ;;
		*)      echo "$1" ;;
	esac
}

# Root config dir; its existence means the client is installed for this user.
skill_client_root () {
	case "$1" in
		claude) echo "$HOME/.claude" ;;
		codex)  echo "$HOME/.codex" ;;
		cursor) echo "$HOME/.cursor" ;;
		agents) echo "$HOME/.agents" ;;
		*)      return 1 ;;
	esac
}

# Directory the skill folder is installed into.
skill_client_dir () {
	case "$1" in
		claude) echo "$HOME/.claude/skills" ;;
		codex)  echo "$HOME/.codex/skills" ;;
		cursor) echo "$HOME/.cursor/skills" ;;
		agents) echo "$HOME/.agents/skills" ;;
		*)      return 1 ;;
	esac
}

skill_is_known_client () {
	local c;
	for c in $(skill_known_clients); do
		[ "$c" = "$1" ] && return 0;
	done
	return 1;
}

show_install_skill_help () {
	cat <<EOF
fakeapp skill - Install the fakeapp agent skill into your AI clients.

USAGE:
  fakeapp skill [OPTIONS]

OPTIONS:
  --client CLIENT   Target client(s): claude, codex, cursor, agents, or all.
                    Repeatable and/or comma-separated. When omitted, installs
                    into every supported client detected on this machine
                    (falling back to Claude Code if none are detected).
  --dest DIR        Install into a custom skills directory (overrides --client).
  --print           Print the bundled SKILL.md to stdout and exit.
  --uninstall       Remove the installed fakeapp skill instead of installing.
  --force           Overwrite an existing installed skill.
  -h, --help        Show this help and exit.

SUPPORTED CLIENTS:
  claude   Claude Code    -> ~/.claude/skills/fakeapp
  codex    Codex CLI      -> ~/.codex/skills/fakeapp
  cursor   Cursor         -> ~/.cursor/skills/fakeapp
  agents   Agent Skills   -> ~/.agents/skills/fakeapp

EXAMPLES:
  fakeapp skill                        # auto-detect installed clients
  fakeapp skill --client claude        # a single client
  fakeapp skill --client claude,codex  # several clients
  fakeapp skill --client all --force   # (re)install everywhere
  fakeapp skill --dest ~/.config/skills
  fakeapp skill --print                # inspect the skill content
  fakeapp skill --uninstall            # remove from detected clients
EOF
}

parse_install_skill_args () {
	skill_clients="";
	skill_dest="";
	skill_print=0;
	skill_uninstall=0;
	skill_force=0;

	while [ "$#" -gt 0 ]; do
		case "$1" in
			--client)
				shift;
				[ "$#" -gt 0 ] || { echo "ERROR: --client requires a value"; exit 1; }
				skill_clients="$skill_clients ${1//,/ }";
				;;
			--dest|--destination)
				shift;
				[ "$#" -gt 0 ] || { echo "ERROR: --dest requires a value"; exit 1; }
				skill_dest="$1";
				;;
			--print)     skill_print=1 ;;
			--uninstall) skill_uninstall=1 ;;
			--force)     skill_force=1 ;;
			-h|--help)   show_install_skill_help; exit 0 ;;
			-*)          echo "ERROR: Unknown option: $1"; show_install_skill_help; exit 1 ;;
			*)           echo "ERROR: Unexpected argument: $1"; show_install_skill_help; exit 1 ;;
		esac
		shift;
	done

	# Normalize/validate requested clients ("all" expands to every known one).
	local normalized="" c;
	for c in $skill_clients; do
		if [ "$c" = "all" ]; then
			normalized="$(skill_known_clients)";
			break;
		fi
		skill_is_known_client "$c" || {
			echo "ERROR: Unknown client: $c (known: $(skill_known_clients) all)";
			exit 1;
		};
		normalized="$normalized $c";
	done
	skill_clients="$normalized";

	[ "$skill_print" -eq 1 ] && [ "$skill_uninstall" -eq 1 ] && {
		echo "ERROR: --print cannot be combined with --uninstall"; exit 1;
	};

	export skill_clients skill_dest skill_print skill_uninstall skill_force;
}

prepare_skill_source () {
	# Materialize the bundled skill tree into $working_tmp/skills/fakeapp.
	mkdir -p "$working_tmp/skills";
	if [ -n "${fakeapp_skill_package:-}" ]; then
		local skill_tgz="$working_tmp/fakeapp_skill.tgz";
		base64 -D -o "$skill_tgz" <<< "$fakeapp_skill_package";
		tar xzf "$skill_tgz" -C "$working_tmp/skills";
	elif [ -d "$(dirname "$0")/skills/fakeapp" ]; then
		# Dev fallback: running the source script beside a skills/ directory.
		cp -r "$(dirname "$0")/skills/." "$working_tmp/skills/";
	else
		echo "ERROR: bundled fakeapp skill not found."; exit 1;
	fi
	[ -f "$working_tmp/skills/fakeapp/SKILL.md" ] || {
		echo "ERROR: bundled skill is missing SKILL.md"; exit 1;
	};
}

run_install_skill () {
	prepare_skill_source;
	local skill_src="$working_tmp/skills/fakeapp";

	if [ "${skill_print:-0}" -eq 1 ]; then
		cat "$skill_src/SKILL.md";
		return 0;
	fi

	# Resolve targets as newline-separated "Display Name|/path/to/skills".
	local targets="" c;
	if [ -n "${skill_dest:-}" ]; then
		local dest_expanded;
		case "$skill_dest" in
			"~")   dest_expanded="$HOME" ;;
			"~/"*) dest_expanded="$HOME/${skill_dest#\~/}" ;;
			*)     dest_expanded="$skill_dest" ;;
		esac
		[ "$dest_expanded" = "/" ] && {
			echo "ERROR: refusing to use / as skills destination"; exit 1;
		};
		targets="Custom|$dest_expanded";
	elif [ -n "${skill_clients// /}" ]; then
		for c in $skill_clients; do
			targets="$targets
$(skill_client_name "$c")|$(skill_client_dir "$c")";
		done
	else
		# auto: install into every detected client, else default to Claude Code.
		local detected="";
		for c in $(skill_known_clients); do
			[ -d "$(skill_client_root "$c")" ] && detected="$detected $c";
		done
		if [ -z "${detected// /}" ]; then
			if [ "${skill_uninstall:-0}" -eq 1 ]; then
				echo "No supported AI clients detected; nothing to uninstall.";
				return 0;
			fi
			echo "> No supported AI clients detected; defaulting to Claude Code.";
			detected="claude";
		fi
		for c in $detected; do
			targets="$targets
$(skill_client_name "$c")|$(skill_client_dir "$c")";
		done
	fi

	local any=0 name dir dest;
	while IFS='|' read -r name dir; do
		[ -n "$name" ] || continue;
		dest="$dir/fakeapp";
		if [ "${skill_uninstall:-0}" -eq 1 ]; then
			if [ -d "$dest" ]; then
				rm -rf "$dest";
				echo "Removed fakeapp skill  -> $name: $dest";
				any=1;
			fi
			continue;
		fi
		if [ -d "$dest" ] && [ "${skill_force:-0}" -ne 1 ]; then
			echo "ERROR: skill already installed at $dest";
			echo "       re-run with --force to overwrite.";
			exit 1;
		fi
		mkdir -p "$dir";
		rm -rf "$dest";
		cp -r "$skill_src" "$dest";
		echo "Installed fakeapp skill -> $name: $dest";
		any=1;
	done <<< "$targets";

	if [ "$any" -eq 0 ]; then
		if [ "${skill_uninstall:-0}" -eq 1 ]; then
			echo "No installed fakeapp skill found.";
		else
			echo "ERROR: no install targets resolved."; exit 1;
		fi
	fi
	return 0;
}

# --- top-level dispatch -----------------------------------------------------
subcommand="ipa";
case "${1:-}" in
	skill|install-skill)
		# `install-skill` kept as a hidden backward-compatible alias for `skill`.
		subcommand="install-skill";
		shift;
		parse_install_skill_args "$@";
		;;
	*)
		parse_args "$@";
		;;
esac
export subcommand;

plist_get () {
	/usr/libexec/PlistBuddy -c "Print $1" "$2" 2>/dev/null || true;
}

plist_set_string () {
	local key="$1";
	local value="$2";
	local plist="$3";

	/usr/libexec/PlistBuddy -c "Set :$key $value" "$plist" 2>/dev/null || \
		/usr/libexec/PlistBuddy -c "Add :$key string $value" "$plist" 2>/dev/null;
}

sanitize_bundle_component () {
	local value="$1";
	value=$(printf "%s" "$value" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g; s/--*/-/g; s/^-//; s/-$//');
	[ -z "$value" ] && value="app";
	case "$value" in
		[a-z]*) ;;
		*) value="app-$value" ;;
	esac
	printf "%s" "$value";
}

validate_bundle_id () {
	local value="$1";
	[[ "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]] || return 1;
	[[ "$value" == *.* ]] || return 1;
	[[ "$value" != *..* ]] || return 1;
	return 0;
}

escape_sed_replacement () {
	printf "%s" "$1" | sed 's/[\/&]/\\&/g';
}

escape_objc_string () {
	printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g';
}

escape_pbxproj_string () {
	printf "%s" "$1" | sed 's/\\/\\\\/g; s/"/\\"/g';
}

extract_ipa () {
	echo "> Extracting IPA file";
	mkdir -p "$ipa_extract_tmp";

	# Use -o to overwrite files without prompting, -q for quiet
	unzip -o -q "$ipa_path" -d "$ipa_extract_tmp";

	# Check if unzip succeeded
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to extract IPA file";
		exit 1;
	fi

	# Check if Payload directory exists
	if [ ! -d "$ipa_extract_tmp/Payload" ]; then
		echo "ERROR: Not a valid IPA file - no Payload directory found";
		exit 1;
	fi

	# Find the .app bundle (must be a directory, not a file)
	app_bundle="";
	for candidate_app_bundle in "$ipa_extract_tmp"/Payload/*.app; do
		[ -d "$candidate_app_bundle" ] || continue;
		app_bundle="$candidate_app_bundle";
		break;
	done
	[ -z "$app_bundle" ] && {
		echo "ERROR: No .app bundle found in IPA";
		echo "This script only processes IPA files containing iOS applications.";
		exit 1;
	}

	echo "Found app bundle: $(basename $app_bundle)";

	# Extract appname from .app bundle name
	appname=$(basename "$app_bundle" .app);
	echo "App name: $appname";

	original_target_bundle_id=$(plist_get "CFBundleIdentifier" "$app_bundle/Info.plist");
	[ -z "$original_target_bundle_id" ] && {
		echo "ERROR: Cannot read CFBundleIdentifier from IPA Info.plist";
		exit 1;
	}

	if [ -n "$requested_bundle_id" ]; then
		validate_bundle_id "$requested_bundle_id" || {
			echo "ERROR: Invalid Bundle ID: $requested_bundle_id";
			echo "Bundle IDs must contain only letters, numbers, dots, or hyphens, and include at least one dot.";
			exit 1;
		}
		fake_bundle_id="$requested_bundle_id";
	else
		fake_bundle_id="$bundle_id_prefix.$(sanitize_bundle_component "$appname")";
	fi
	pdebug_bundle_id="$fake_bundle_id.PDebug";
	echo "Original Bundle ID: $original_target_bundle_id";
	echo "Fake Bundle ID for signing: $fake_bundle_id";
	[ -n "$signing_certificate" ] && echo "Signing certificate: $signing_certificate";

	# Check if the target project directory already exists
	local target_project_dir="$output_dir/$appname";
	[ -d "$target_project_dir" ] && {
		echo "WARNING: $target_project_dir exists, do you want to continue?"
		read -p "(Y)es or (N)o: " confirm_option;
		[ "$confirm_option" != "Y" ] && {
			echo  "Cancelled."
			exit 1;
		}

		rm -rf "$target_project_dir";
	}

	# Store app bundle path and appname for later use
	export EXTRACTED_APP_PATH="$app_bundle";
	export EXTRACTED_INFO_PLIST="$app_bundle/Info.plist";
	export appname="$appname";
	export ORIGINAL_TARGET_BUNDLE_ID="$original_target_bundle_id";
	export FAKE_BUNDLE_ID="$fake_bundle_id";
	export PDEBUG_BUNDLE_ID="$pdebug_bundle_id";
	export SIGNING_CERTIFICATE="$signing_certificate";

	return 0;
}

prepare_packed_files () {
	echo "> Unpacking fakesample.tgz";
	base64 -D -o "$fakesample_tgz" <<< "$fakesample_package";
	tar xzvf "$fakesample_tgz" -C "$working_tmp";
	return 0;
}

replace_files () {
	echo "> Rename fakesample files"
	while read fakefile; do
		local fakename=$(basename "$fakefile");
		[ -f "$fakefile" ] && {
			echo "- replacing $fakename";
			sed -i.bak "s/fakesample/$appname/g" "$fakefile" 2>/dev/null;
			rm -rf "$fakefile.bak";
		};
		[[ "$(basename $fakefile)" == *fakesample* ]] && {
			echo "- rename $fakename";
			mv -v "$fakefile" "$(dirname "$fakefile")/${fakename/fakesample/$appname}";
		};
	done <<< "$(find "$working_tmp/fakesample" | sort -r)";
	return 0;
}

copy_app_to_payload () {
	echo "> Copying .app bundle to Payload directory";
	local payload_dir="$working_tmp/$appname/Payload";
	mkdir -p "$payload_dir";

	# Remove placeholder files from template
	echo "> Removing placeholder files from Payload";
	find "$payload_dir" -type f -name "*.app" -size 0 -delete 2>/dev/null || true;
	find "$payload_dir" -type f -name "*DS_Store*" -delete 2>/dev/null || true;

	# Copy the extracted .app bundle
	cp -r "$EXTRACTED_APP_PATH" "$payload_dir/";
	echo ".app bundle copied to $payload_dir/$(basename $EXTRACTED_APP_PATH)";

	# Remove PlugIns and Watch directories (as done in MonkeyDev)
	local target_app_path="$payload_dir/$(basename $EXTRACTED_APP_PATH)";

	if [ -d "$target_app_path/PlugIns" ]; then
		echo "> Removing PlugIns directory (App Extensions)";
		rm -rf "$target_app_path/PlugIns" || true;
	fi

	if [ -d "$target_app_path/Watch" ]; then
		echo "> Removing Watch directory";
		rm -rf "$target_app_path/Watch" || true;
	fi

	if [ -d "$target_app_path/Extensions" ]; then
		echo "> Removing Extensions directory";
		rm -rf "$target_app_path/Extensions" || true;
	fi

	# Remove all .DS_Store files from entire Payload directory (including .app bundle)
	echo "> Removing all .DS_Store files from Payload directory";
	find "$payload_dir" -name "*DS_Store*" -type f -delete 2>/dev/null || true;

	return 0;
}

update_bundle_id_config () {
	echo "> Updating Bundle ID configuration";

	local project_file="$working_tmp/$appname/$appname.xcodeproj/project.pbxproj";
	local pdebug_config="$working_tmp/$appname/PDebug/FakeAppConfig.h";
	local payload_app_info_plist="$working_tmp/$appname/Payload/$(basename "$EXTRACTED_APP_PATH")/Info.plist";
	local escaped_fake_bundle_id=$(escape_sed_replacement "$FAKE_BUNDLE_ID");
	local escaped_pdebug_bundle_id=$(escape_sed_replacement "$PDEBUG_BUNDLE_ID");
	local escaped_original_bundle_id=$(escape_objc_string "$ORIGINAL_TARGET_BUNDLE_ID");
	local escaped_certificate="";

	[ ! -f "$project_file" ] && {
		echo "ERROR: Cannot find project file: $project_file";
		exit 1;
	}

	[ ! -f "$payload_app_info_plist" ] && {
		echo "ERROR: Cannot find Payload app Info.plist: $payload_app_info_plist";
		exit 1;
	}

	sed -i.bak \
		-e "s/PRODUCT_BUNDLE_IDENTIFIER = com\.example\.demo;/PRODUCT_BUNDLE_IDENTIFIER = $escaped_fake_bundle_id;/g" \
		-e "s/PRODUCT_BUNDLE_IDENTIFIER = com\.example\.demo\.PDebug;/PRODUCT_BUNDLE_IDENTIFIER = $escaped_pdebug_bundle_id;/g" \
		"$project_file";
	rm -f "$project_file.bak";

	if [ -n "$SIGNING_CERTIFICATE" ]; then
		escaped_certificate=$(escape_sed_replacement "$(escape_pbxproj_string "$SIGNING_CERTIFICATE")");
		sed -i.bak \
			-e "s/\"CODE_SIGN_IDENTITY\[sdk=iphoneos\*\]\" = \"[^\"]*\";/\"CODE_SIGN_IDENTITY[sdk=iphoneos*]\" = \"$escaped_certificate\";/g" \
			"$project_file";
		rm -f "$project_file.bak";
	fi

	plist_set_string "CFBundleIdentifier" "$FAKE_BUNDLE_ID" "$payload_app_info_plist";

	[ -f "$pdebug_config" ] && {
		sed -i.bak "s/FAKEAPP_ORIGINAL_BUNDLE_ID @\"\"/FAKEAPP_ORIGINAL_BUNDLE_ID @\"$escaped_original_bundle_id\"/g" "$pdebug_config";
		rm -f "$pdebug_config.bak";
	}

	echo "Project Bundle ID: $FAKE_BUNDLE_ID";
	echo "PDebug Bundle ID: $PDEBUG_BUNDLE_ID";
	echo "Runtime original Bundle ID: $ORIGINAL_TARGET_BUNDLE_ID";
	[ -n "$SIGNING_CERTIFICATE" ] && echo "Code signing identity: $SIGNING_CERTIFICATE";
}

update_info_plist () {
	echo "> Updating Info.plist from IPA";

	local project_info_plist="$working_tmp/$appname/$appname/Info.plist";

	[ ! -f "$EXTRACTED_INFO_PLIST" ] && {
		echo "WARNING: Cannot find Info.plist in IPA, skipping Info.plist update";
		return 0;
	}

	[ ! -f "$project_info_plist" ] && {
		echo "WARNING: Cannot find project Info.plist, skipping Info.plist update";
		return 0;
	}

	echo "Source Info.plist: $EXTRACTED_INFO_PLIST";
	echo "Target Info.plist: $project_info_plist";

	# Save original Bundle ID before modification
	local original_bundle_id=$(plist_get "CFBundleIdentifier" "$project_info_plist");
	echo "Original Bundle ID (will be preserved): $original_bundle_id";

	# Read executable names to determine if we should copy the entire plist
	local current_executable=$(plist_get "CFBundleExecutable" "$project_info_plist");
	local target_executable=$(plist_get "CFBundleExecutable" "$EXTRACTED_INFO_PLIST");

	# Following MonkeyDev's logic: copy entire Info.plist if executables differ
	# This preserves all keys including permissions, URL schemes, etc.
	if [[ "$current_executable" != "$target_executable" ]]; then
		echo "> Copying entire Info.plist from IPA (executables differ: $current_executable vs $target_executable)";
		cp -f "$EXTRACTED_INFO_PLIST" "$project_info_plist";
	else
		echo "> Merging Info.plist keys (executables match: $current_executable)";
		# Use PlistBuddy Merge command to merge all keys from source to target
		/usr/libexec/PlistBuddy -c "Merge '$EXTRACTED_INFO_PLIST'" "$project_info_plist" 2>/dev/null;
	fi

	# Restore original Bundle ID
	if [[ ! -z "$original_bundle_id" ]]; then
		echo "> Restoring original Bundle ID: $original_bundle_id";
		plist_set_string "CFBundleIdentifier" "$original_bundle_id" "$project_info_plist";
	fi

	# Remove UISupportedDevices if exists (as done in MonkeyDev)
	echo "> Removing UISupportedDevices";
	/usr/libexec/PlistBuddy -c "Delete :UISupportedDevices" "$project_info_plist" 2>/dev/null;

	# Update CFBundleIconFiles (as done in MonkeyDev)
	echo "> Updating CFBundleIconFiles";
	/usr/libexec/PlistBuddy -c "Delete :CFBundleIconFiles" "$project_info_plist" 2>/dev/null;
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles array" "$project_info_plist" 2>/dev/null;
	/usr/libexec/PlistBuddy -c "Add :CFBundleIconFiles: string $appname/icon.png" "$project_info_plist" 2>/dev/null;

	echo "Info.plist updated successfully";
	return 0;
}

migrate_target () {
	echo "> Moving target to: $output_dir";
	mkdir -p "$output_dir" || {
		echo "ERROR: Cannot create output directory: $output_dir";
		exit 1;
	}
	mv "$working_tmp/$appname" "$output_dir/";
}

restore_symbols () {
	# ObjC 符号还原: 用打包的 restore-symbol 解析 App 主二进制的 ObjC 元数据
	# (类名/方法名), 把 -[Class method] 写回符号表, 让 Xcode/LLDB 栈帧显示真实
	# 方法名而非裸地址。一次性烤进 Payload 主二进制, 后续 Xcode 构建照旧重签。
	# 默认开启; --no-symbols 或 FAKEAPP_NO_SYMBOLS=1 关闭; 任何失败都不致命。
	if [ -n "$no_symbols" ] || [ -n "${FAKEAPP_NO_SYMBOLS:-}" ]; then
		echo "> [symbols] disabled (--no-symbols)";
		return 0;
	fi

	local app_path="$working_tmp/$appname/Payload/$(basename "$EXTRACTED_APP_PATH")";
	local exec_name; exec_name=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app_path/Info.plist" 2>/dev/null);
	local bin="$app_path/$exec_name";
	local rs="$working_tmp/$appname/scripts/restore-symbol";

	[ -x "$rs" ] || { echo "> [symbols] skipped (restore-symbol not bundled)"; return 0; }
	[ -n "$exec_name" ] && [ -f "$bin" ] || { echo "> [symbols] skipped (executable not found)"; return 0; }

	echo "> [symbols] restoring ObjC symbols for $exec_name ...";
	local tmp="$bin.symbolized";
	if "$rs" -o "$tmp" "$bin" >/dev/null 2>&1 && [ -f "$tmp" ]; then
		chmod +x "$tmp";
		mv -f "$tmp" "$bin";
		local count; count=$(nm "$bin" 2>/dev/null | grep -cE ' [tT] ');
		echo "> [symbols] restored $exec_name: $count function symbols in symbol table";
	else
		rm -f "$tmp";
		echo "> [symbols] skipped ($exec_name: restore-symbol failed, likely unsupported binary)";
	fi
	return 0;
}

main () {
	case "${subcommand:-ipa}" in
		install-skill)
			run_install_skill;
			return 0;
			;;
	esac

	[ -z "$ipa_path" ] && {
		echo "ERROR: IPA file path required!";
		usage;
		exit 1;
	};

	[ ! -f "$ipa_path" ] && {
		echo "ERROR: IPA file not found: $ipa_path";
		exit 1;
	};

	extract_ipa;

	prepare_packed_files;

	replace_files;

	copy_app_to_payload;

	update_info_plist;

	update_bundle_id_config;

	restore_symbols;

	migrate_target;

	echo "Fake app [$appname] created with IPA integration."
	echo "Original IPA: $(basename $ipa_path)"
	echo ".app bundle: $(basename $EXTRACTED_APP_PATH)"
	echo "Project path: $output_dir/$appname"
}
