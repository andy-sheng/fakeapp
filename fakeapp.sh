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
  fakeapp help | --help | -h

OPTIONS:
  -b, --bundle-id BUNDLE_ID     Bundle ID for signing the generated app.
                                Default: ${bundle_id_prefix}.<appname>
  -c, --certificate IDENTITY    Xcode code signing identity for device builds
                                (e.g. "Apple Development: Name (TEAMID)").
  -o, --output DIR              Output directory for the generated project.
                                Default: current directory. Created if missing.
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

parse_args "$@";

[ -z "$ipa_path" ] && {
	echo "ERROR: IPA file path required!";
	usage;
	exit 1;
};

[ ! -f "$ipa_path" ] && {
	echo "ERROR: IPA file not found: $ipa_path";
	exit 1;
};

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

main () {
	extract_ipa;

	prepare_packed_files;

	replace_files;

	copy_app_to_payload;

	update_info_plist;

	update_bundle_id_config;

	migrate_target;

	echo "Fake app [$appname] created with IPA integration."
	echo "Original IPA: $(basename $ipa_path)"
	echo ".app bundle: $(basename $EXTRACTED_APP_PATH)"
	echo "Project path: $output_dir/$appname"
}
