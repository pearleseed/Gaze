import Foundation

/// Builds the shell scripts that install and remove Gaze's sudo PAM module.
/// Pure string building, kept apart from SudoApproval so a test can run the
/// exact script against a temporary folder instead of the real system paths.
struct SudoInstallScript {
	struct Paths {
		var moduleFolder = "/Library/Security/Gaze"
		var modulePath: String { moduleFolder + "/pam_gaze.so" }
		var requirementPath: String { moduleFolder + "/pam_gaze.requirement" }
		var sudoLocalPath = "/etc/pam.d/sudo_local"
		var sudoLocalTemplate = "/etc/pam.d/sudo_local.template"
		/// Whether to set root ownership; off only for tests run as a normal user.
		var setRootOwner = true
	}

	static let authLine = "auth sufficient \(Paths().modulePath)"
	static let legacyModulePath = "/usr/local/lib/pam/pam_gaze.so"
	static let legacyRequirementPath = "/usr/local/lib/pam/pam_gaze.requirement"
	static let pamWriteDenied = 77

	/// Copies the module, writes the listener requirement and puts the auth
	/// line at the top of sudo_local, keeping every other line. The copied
	/// module is cleared of extended attributes (quarantine, provenance) so
	/// sudo loads it the same as any other root-owned file.
	static func install(source: String, requirement: String, paths: Paths = Paths()) -> String {
		return """
		\(policyFunctions(paths: paths))
		stage_policy
		printf '%s\\n' \(q(authLine)) > "$tmp"
		if [ -f "$policy" ]; then
		  keep_other_rules "$policy" >> "$tmp"
		elif [ -f \(q(paths.sudoLocalTemplate)) ]; then
		  keep_other_rules \(q(paths.sudoLocalTemplate)) >> "$tmp"
		fi
		\(checkModuleFolder(paths: paths, create: true))
		staged_module=$(mktemp -d \(q(paths.moduleFolder))/.gaze.XXXXXX)
		cp \(q(source)) "$staged_module/pam_gaze.so"
		xattr -c "$staged_module/pam_gaze.so" 2>/dev/null || true
		printf '%s\\n' \(q(requirement)) > "$staged_module/pam_gaze.requirement"
		\(paths.setRootOwner ? "chown root:wheel \"$staged_module\"/pam_gaze.*" : ":")
		chmod 0444 "$staged_module"/pam_gaze.*
		for name in pam_gaze.requirement pam_gaze.so; do
		  f="$module_folder/$name"
		  if [ -L "$f" ] || { [ -e "$f" ] && [ ! -f "$f" ]; }; then
		    printf 'Invalid Gaze PAM file: %s\\n' "$f" >&2
		    exit 1
		  fi
		  if [ -f "$f" ]; then ln "$f" "$staged_module/previous-$name"; fi
		done
		rollback_module=yes
		mv -f "$staged_module/pam_gaze.requirement" \(q(paths.requirementPath))
		mv -f "$staged_module/pam_gaze.so" \(q(paths.modulePath))
		publish_policy
		rollback_module=no
		"""
	}

	static func uninstall(paths: Paths = Paths()) -> String {
		return """
		\(policyFunctions(paths: paths))
		stage_policy
		\(checkModuleFolder(paths: paths, create: false))
		if [ -f "$policy" ]; then
		  keep_other_rules "$policy" > "$tmp"
		  if ! cmp -s "$tmp" "$policy"; then publish_policy; fi
		fi
		rm -f \(q(paths.modulePath)) \(q(paths.requirementPath))
		"""
	}

	private static func policyFunctions(paths: Paths) -> String {
		let dir = (paths.sudoLocalPath as NSString).deletingLastPathComponent
		return """
		set -e
		export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
		umask 077
		policy=\(q(paths.sudoLocalPath))
		module_folder=\(q(paths.moduleFolder))
		lock= staged_module= rollback_module=no
		cleanup() {
		  set +e
		  if [ "$rollback_module" = yes ]; then
		    for name in pam_gaze.requirement pam_gaze.so; do
		      previous="$staged_module/previous-$name"
		      if [ -f "$previous" ]; then
		        # BSD mv can leave both links when the destination already has this inode.
		        if [ ! "$previous" -ef "$module_folder/$name" ]; then mv -f "$previous" "$module_folder/$name"; fi
		      else
		        rm -f "$module_folder/$name"
		      fi
		    done
		  fi
		  rm -f "$tmp"
		  if [ -n "$staged_module" ]; then rm -rf "$staged_module"; fi
		  if [ -n "$lock" ]; then rm -f "$lock"; fi
		}
		stage_policy() {
		  tmp=$(mktemp \(q(dir))/.sudo_local.XXXXXX 2>&1) || policy_error "$tmp"
		  trap cleanup EXIT
		  lock_path=\(q(dir))/.sudo_local.gaze.lock
		  if ! shlock -p "$$" -f "$lock_path"; then
		    printf 'Could not lock the sudo PAM configuration. Try again.\\n' >&2
		    exit 1
		  fi
		  lock=$lock_path
		  if [ -L "$policy" ] || { [ -e "$policy" ] && [ ! -f "$policy" ]; }; then
		    printf 'Expected a regular sudo PAM configuration at %s.\\n' "$policy" >&2
		    exit 1
		  fi
		}
		policy_error() {
		  printf '%s\\n' "$1" >&2
		  case "$1" in
		    *'Operation not permitted'*|*'Permission denied'*) exit \(pamWriteDenied) ;;
		    *) exit 1 ;;
		  esac
		}
		keep_other_rules() {
		  awk -v module=\(q(Paths().modulePath)) -v legacy=\(q(legacyModulePath)) \\
		    '!($1 == "auth" && ($3 == module || $3 == legacy)) && !/^# Added by Gaze/' "$1"
		}
		publish_policy() {
		  \(paths.setRootOwner ? "chown root:wheel \"$tmp\"" : ":")
		  chmod 0444 "$tmp"
		  if ! error=$(mv -f "$tmp" "$policy" 2>&1); then policy_error "$error"; fi
		}
		"""
	}

	private static func checkModuleFolder(paths: Paths, create: Bool) -> String {
		let folder = q(paths.moduleFolder)
		guard paths.setRootOwner else { return create ? "mkdir -p \(folder)" : ":" }
		let parent = (paths.moduleFolder as NSString).deletingLastPathComponent
		return """
		trusted_directory() {
		  if [ -d "$1" ] && [ ! -L "$1" ]; then
		    case "$(stat -f '%u %Lp' "$1")" in
		      '0 '[0-7][0145][0145]) if [ "$(ls -bde "$1" | wc -l)" -eq 1 ]; then return; fi ;;
		    esac
		  fi
		  printf 'Gaze requires a root-owned directory without write access for other users: %s\\n' "$1" >&2
		  exit 1
		}
		trusted_directory \(q((parent as NSString).deletingLastPathComponent))
		trusted_directory \(q(parent))
		\(create ? "if [ ! -e \(folder) ] && [ ! -L \(folder) ]; then mkdir -m 0755 \(folder); fi" : ":")
		if [ -e \(folder) ] || [ -L \(folder) ]; then trusted_directory \(folder); fi
		"""
	}

	static func terminalCommand(_ shellScript: String) -> String {
		"/usr/bin/sudo -k /bin/sh -c " + q(shellScript)
	}

	/// Wraps a shell script in an AppleScript `do shell script` command.
	static func appleScript(_ shellScript: String, administrator: Bool = true) -> String {
		let escaped = shellScript
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "\"", with: "\\\"")
			.replacingOccurrences(of: "\n", with: "\\n")
		return "do shell script \"\(escaped)\"" + (administrator ? " with administrator privileges" : "")
	}

	/// Whether sudo_local text holds Gaze's auth line, ignoring spacing.
	static func routesThroughGaze(_ sudoLocal: String, modulePath: String = Paths().modulePath) -> Bool {
		sudoLocal.split(separator: "\n").contains {
			$0.split(whereSeparator: \.isWhitespace) == ["auth", "sufficient", Substring(modulePath)]
		}
	}

	private static func q(_ value: String) -> String {
		"'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
	}
}
