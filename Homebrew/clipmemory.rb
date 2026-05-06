class Clipmemory < Formula
  desc "本地剪贴板历史管理器 - 永久记忆你的每一次复制"
  homepage "https://github.com/irykelee/clipmemory"
  url "https://github.com/irykelee/clipmemory/releases/download/1.0.1/ClipMemory.tar.gz"
  sha256 "1d40200a7d67a94ccf5294637f05034ba3f57381e10378f6acaecc2d66dbdffb"
  version "1.0.1"
  depends_on macOS: ">= :catalina"

  def install
    prefix.install "ClipMemory.app"
  end
end
