	cask "clipmemory" do
	  version "2.1.0"
	  sha256 "e36a14ce4765f11b4c7ecd30a02eca62a909fb5c5753e20840ffdf9a2ac44fe4"

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
