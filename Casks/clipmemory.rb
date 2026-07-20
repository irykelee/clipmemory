	cask "clipmemory" do
 	version "2.5.7"
	  sha256 "5798651ad794ad63388c7cf00e31c70c26673c1402c010d95de178566be6875d"

	  url "https://github.com/irykelee/clipmemory/releases/download/v#{version}/ClipMemory.tar.gz"
	  name "ClipMemory"
	  desc "Clipboard history manager for macOS with encryption and Quick Bar"
	  homepage "https://github.com/irykelee/clipmemory"

	  depends_on macos: :ventura

	  auto_updates true

	  app "ClipMemory.app"

	  zap trash: [
	    "~/Library/Application Support/ClipMemory",
	    "~/Library/Preferences/com.clipmemory.app.plist",
	  ],
	  # C1: the root encryption key lives in the Keychain, not in files —
	  # remove it too so zap leaves no key material behind.
	  script: {
	    executable: "/usr/bin/security",
	    args: ["delete-generic-password", "-s", "com.clipmemory.app", "-a", "root-encryption-key"],
	    must_succeed: false,
	  }
	end
