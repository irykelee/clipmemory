	cask "clipmemory" do
 	version "2.2.4"
	  # SHA256 placeholder — recomputed in Task 7 after `Scripts/package.sh`
	  # produces `Releases/ClipMemory.tar.gz` for v2.2.4. Do not hand-fabricate.
	  sha256 "PLACEHOLDER_RECOMPUTED_BY_TASK_7"

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
