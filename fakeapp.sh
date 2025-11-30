#!/bin/bash
# @Author: Ethan
# @Date:   2025-11-30
# @Last Modified by:   Ethan
# @Last Modified time: 2025-11-30
# Enhanced version that accepts IPA file path and modifies Info.plist based on IPA content

working_tmp=$(mktemp -t fakeapp -d);
fakesample_tgz=$working_tmp/fakesample.tgz;
ipa_extract_tmp=$working_tmp/ipa_extract;

trap 'rm -rf $working_tmp' EXIT SIGHUP SIGINT SIGQUIT;

ipa_path="$1";
[ -z "$ipa_path" ] && {
	echo "Usage: fakeapp2.sh IPA_FILE_PATH";
	echo "ERROR: IPA file path required!";
	exit 1;
};

[ ! -f "$ipa_path" ] && {
	echo "ERROR: IPA file not found: $ipa_path";
	exit 1;
};

extract_ipa () {
	echo "> Extracting IPA file";
	mkdir -p $ipa_extract_tmp;

	# Use -o to overwrite files without prompting, -q for quiet
	unzip -o -q "$ipa_path" -d $ipa_extract_tmp;

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
	app_bundle=$(find $ipa_extract_tmp/Payload -type d -name "*.app" -maxdepth 1 | head -1);
	[ -z "$app_bundle" ] && {
		echo "ERROR: No .app bundle found in IPA";
		echo "This script only processes IPA files containing iOS applications.";
		exit 1;
	}

	echo "Found app bundle: $(basename $app_bundle)";

	# Extract appname from .app bundle name
	appname=$(basename "$app_bundle" .app);
	echo "App name: $appname";

	# Check if appname directory already exists
	[ -d "$appname" ] && {
		echo "WARNING: $appname exists, do you want to continue?"
		read -p "(Y)es or (N)o: " confirm_option;
		[ "$confirm_option" != "Y" ] && {
			echo  "Cancelled."
			exit 1;
		}

		rm -rf "$appname";
	}

	# Store app bundle path and appname for later use
	export EXTRACTED_APP_PATH="$app_bundle";
	export EXTRACTED_INFO_PLIST="$app_bundle/Info.plist";
	export appname="$appname";

	return 0;
}

prepare_packed_files () {
	echo "> Unpacking fakesample.tgz";
	base64 -D -o $fakesample_tgz <<< "$fakesample_package";
	tar xzvf $fakesample_tgz -C $working_tmp;
	return 0;
}

replace_files () {
	echo "> Rename fakesample files"
	while read fakefile; do
		local fakename=$(basename $fakefile);
		[ -f $fakefile ] && {
			echo "- replacing $fakename";
			sed -i.bak "s/fakesample/$appname/g" $fakefile 2>/dev/null;
			rm -rf $fakefile.bak;
		};
		[[ "$(basename $fakefile)" == *fakesample* ]] && {
			echo "- rename $fakename";
			mv -v $fakefile $(dirname "$fakefile")/${fakename/fakesample/$appname};
		};
	done <<< "$(find $working_tmp/fakesample | sort -r)";
	return 0;
}

copy_app_to_payload () {
	echo "> Copying .app bundle to Payload directory";
	local payload_dir="$working_tmp/$appname/Payload";
	mkdir -p "$payload_dir";

	# Remove placeholder files from template
	echo "> Removing placeholder files from Payload";
	find "$payload_dir" -type f -name "*.app" -size 0 -delete 2>/dev/null || true;
	find "$payload_dir" -type f -name ".DS_Store" -delete 2>/dev/null || true;

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

	# Remove all .DS_Store files from the copied .app bundle
	echo "> Removing .DS_Store files from .app bundle";
	find "$target_app_path" -name ".DS_Store" -type f -delete 2>/dev/null || true;

	return 0;
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
	local original_bundle_id=$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "$project_info_plist" 2>/dev/null);
	echo "Original Bundle ID (will be preserved): $original_bundle_id";

	# Read executable names to determine if we should copy the entire plist
	local current_executable=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$project_info_plist" 2>/dev/null);
	local target_executable=$(/usr/libexec/PlistBuddy -c "Print CFBundleExecutable" "$EXTRACTED_INFO_PLIST" 2>/dev/null);

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
		/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $original_bundle_id" "$project_info_plist" 2>/dev/null;
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
	echo "> Moving target"
	mv $working_tmp/$appname ./;
}

main () {
	extract_ipa;

	prepare_packed_files;

	replace_files;

	copy_app_to_payload;

	update_info_plist;

	migrate_target;

	echo "Fake app [$appname] created with IPA integration."
	echo "Original IPA: $(basename $ipa_path)"
	echo ".app bundle: $(basename $EXTRACTED_APP_PATH)"
}
