	cask "clipmemory" do
 	version "2.1.5"
	  sha256 "3f785a138251052017726e7a85c1ebf06aa2ad857909a4561c43e1b81af874bf"

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
