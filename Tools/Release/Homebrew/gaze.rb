# Homebrew cask for Gaze. Lives in a tap repository named `homebrew-gaze`
# (github.com/pearleseed/homebrew-gaze, file Casks/gaze.rb), so people install with:
#
#     brew install --cask pearleseed/gaze/gaze
#
# Gaze releases are not notarized, so macOS Gatekeeper would block the first
# launch. The postflight clears the quarantine flag on install and on every
# upgrade, matching the manual `xattr` step in the README.
cask "gaze" do
  version "0.1.13"

  on_arm do
    sha256 :no_check
    url "https://github.com/pearleseed/Gaze/releases/download/v#{version}/Gaze-#{version}-14-arm64.dmg"
  end

  on_intel do
    sha256 :no_check
    url "https://github.com/pearleseed/Gaze/releases/download/v#{version}/Gaze-#{version}-14-x86_64.dmg"
  end

  name "Gaze"
  desc "Face ID-style face unlock"
  homepage "https://github.com/pearleseed/Gaze"

  auto_updates true
  depends_on macos: :tahoe

  app "Gaze.app"

  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Gaze.app"],
                          writable_paths: ["Gaze.app"], writable_base: :appdir
  end

  uninstall quit: "com.pearleseed.Gaze"

  zap trash: [
    "~/Library/Application Support/Gaze",
    "~/Library/Caches/com.pearleseed.Gaze",
    "~/Library/Group Containers/group.com.pearleseed.Gaze",
    "~/Library/Preferences/com.pearleseed.Gaze.plist",
  ]
end
