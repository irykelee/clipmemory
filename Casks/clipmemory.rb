	cask "clipmemory" do
	  version "2.1.0"
	  sha256 "eaa27fcdc38bbe889c140b65c25a6fb66482cc7d96d5fc43eeb75659a6f2f099"

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
