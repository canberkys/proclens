cask "proclens" do
  version "0.1.0"
  sha256 "REPLACE_WITH_SHA256_FROM_build_release_ProcLens_VERSION_dmg_sha256"

  url "https://github.com/canberkys/proclens/releases/download/v#{version}/ProcLens-#{version}.dmg"
  name "ProcLens"
  desc "Native sysadmin-grade Task Manager for macOS"
  homepage "https://github.com/canberkys/proclens"

  depends_on macos: ">= :sonoma"

  app "ProcLens.app"

  uninstall quit:      "com.canberkki.ProcLens",
            launchctl: "com.canberkki.ProcLens.helper"

  zap trash: [
    "~/Library/Application Support/ProcLens",
    "~/Library/Caches/com.canberkki.ProcLens",
    "~/Library/HTTPStorages/com.canberkki.ProcLens",
    "~/Library/Preferences/com.canberkki.ProcLens.plist",
    "~/Library/Saved Application State/com.canberkki.ProcLens.savedState",
  ]
end
