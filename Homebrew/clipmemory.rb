class Clipmemory < Formula
  desc "本地剪贴板历史管理器 - 永久记忆你的每一次复制"
  homepage "https://github.com/irykelee/clipmemory"
  url "https://github.com/irykelee/clipmemory/releases/download/#{version}/ClipMemory.tar.gz"
  sha256 "待填写"
  version "1.0.0"
  depends_on macOS: ">= :catalina"

  def install
    prefix.install "ClipMemory.app"
  end
end
