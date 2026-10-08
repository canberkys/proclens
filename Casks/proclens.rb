cask "proclens" do
  version "0.1.0"
  sha256 "97e01d98aac377bb24143fa7b5959f955969eb28310a85186ee028cb25b4defb"

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
