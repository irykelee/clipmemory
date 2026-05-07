class Clipmemory < Formula
  desc "本地剪贴板历史管理器 - 永久记忆你的每一次复制"
  homepage "https://github.com/irykelee/clipmemory"
  url "https://github.com/irykelee/clipmemory/releases/download/1.2.0/ClipMemory.tar.gz"
  sha256 "d584b502f8462257b1257a1ebb4d4198d2a02bc801edeb3c55ed703b7546bff6"
  version "1.2.0"
  depends_on macOS: ">= :catalina"

  def install
    prefix.install "ClipMemory.app"
  end
end
