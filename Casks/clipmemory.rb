cask "clipmemory" do
  version "2.0.1"
  sha256 "82a21dc76e0e80f7dfe8404c1bad424270115c5d0166bcd6ad6eebafa3bba72b"

  url "https://github.com/irykelee/clipmemory/releases/download/v#{version}/ClipMemory.tar.gz"
  name "ClipMemory"
  desc "Local clipboard history manager with AES-256 encryption, sensitive data detection, and multi-language support (7 languages)"
  homepage "https://github.com/irykelee/clipmemory"

  depends_on macos: ">= :ventura"

  app "ClipMemory.app"

  zap trash: [
    "~/Library/Application Support/ClipMemory",
    "~/Library/Preferences/com.clipmemory.app.plist",
  ]
end
