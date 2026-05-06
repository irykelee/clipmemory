class Clipmemory < Formula
  desc "本地剪贴板历史管理器 - 永久记忆你的每一次复制"
  homepage "https://github.com/irykelee/clipmemory"
  url "https://github.com/irykelee/clipmemory/releases/download/1.0.2/ClipMemory.tar.gz"
  sha256 "8886acb5078c4a6b04eaaa613c1ca22ee89aaafc4281b9eb439359d02d8f1fc0"
  version "1.0.2"
  depends_on macOS: ">= :catalina"

  def install
    prefix.install "ClipMemory.app"
  end
end
