cask "proclens" do
  version "0.1.2"
  sha256 "d3360f7341d883c01eb676ec76f64624ace57a2c5a2f78da2ebe8e504a297d9f"

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
