cask "proclens" do
  version "0.1.1"
  sha256 "a9eea0cc3e3eef9f0914e305c51d8a4df2bedde8170f1e4df25bfc4cc3580b17"

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
