cask "clipmemory" do
  version "2.0.5"
  sha256 "4e7f1661529c4a80beb3a579d5da7dc3d340616616554288216ed9e48bcc6662"

  url "https://github.com/irykelee/clipmemory/releases/download/v#{version}/ClipMemory.tar.gz"
  name "ClipMemory"
  desc "Clipboard history manager for macOS with encryption and Quick Bar"
  homepage "https://github.com/irykelee/clipmemory"

  depends_on macos: ">= :ventura"

  app "ClipMemory.app"

  zap trash: [
    "~/Library/Application Support/ClipMemory",
    "~/Library/Preferences/com.clipmemory.app.plist",
  ]
end
