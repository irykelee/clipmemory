cask "clipmemory" do
  version "2.0.0"
  sha256 "ce43fdc67b624e3f327aaca2176db18c8c3554b30defd274651dfe883d42fca0"

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
