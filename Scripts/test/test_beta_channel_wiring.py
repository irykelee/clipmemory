#!/usr/bin/env python3
"""ID-BETA-0001：**beta 通道的接线守卫**（静态、只读、不联网）。

## 它守什么

beta 通道的安全性押在**三根线**上，任一根断了都会变成「beta 直推全体用户」：

| # | 线 | 断了会怎样 |
|---|---|---|
| 1 | **App 侧**：`SPUUpdaterDelegate.allowedChannels(for:)` 真的被实现、且转发到**纯函数** | 勾了 beta 也看不到（或反过来：没勾也能看到） |
| 2 | **纯函数**的默认半边是**空集**（= 只看默认通道） | **默认就把 beta 推给全体用户** ⇒ 最危险 |
| 3 | **发布侧**：appcast 条目带 `<sparkle:channel>beta</sparkle:channel>`、Release 标 prerelease、**不动 Homebrew tap** | beta 被当成正式版发布 ⇒ brew 用户拿到 beta |

⇒ ⇒ 第 1 根线**测不到**：`FeedURLProvider` 是 `private final class` ⇒ ⇒ 单元测试
够不着它 ⇒ ⇒ 所以本守卫**静态**钉住「delegate 存在 + 转发到纯函数」⇒ ⇒ 纯函数
那半边由 `UpdateBetaChannelTests`（单元测试）负责 ⇒ ⇒ 两边合起来才有牙。

## 用法

  python3 Scripts/test/test_beta_channel_wiring.py             # 查仓库
  python3 Scripts/test/test_beta_channel_wiring.py --self-test # 自检（合成夹具）

退出码：0 = 通过；1 = 查出问题；2 = **没检查**（缺文件 ⇒ 不假装检查过）。
"""
import os
import re
import sys

APP_SWIFT = os.path.join("ClipMemory", "Services", "UpdateService.swift")
KEY_SWIFT = os.path.join("ClipMemory", "Services", "UserDefaultsKey.swift")
VIEW_SWIFT = os.path.join("ClipMemory", "Views", "Settings", "UpdateAboutSettingsView.swift")
RELEASE_SH = os.path.join("Scripts", "release.sh")
APPCAST_SH = os.path.join("Scripts", "update_appcast.sh")
WORKFLOW = os.path.join(".github", "workflows", "release.yml")
ROLLBACK_SH = os.path.join("Scripts", "rollback-release.sh")


# ── 判据 ────────────────────────────────────────────────────────────
# 每条 = (编号, 相对路径, 说明, 必含的正则, 必不含的正则或 None)
CHECKS = [
    # ① App 侧：delegate 真的实现了 Sparkle 的协议方法
    ("A1", APP_SWIFT, "delegate 必须实现 allowedChannels(for:)（Sparkle 2 的协议方法）",
     r"func\s+allowedChannels\s*\(\s*for\s+updater:\s*SPUUpdater\s*\)\s*->\s*Set<String>", None),
    # ② delegate 只做转发 ⇒ 判定逻辑只有一处 ⇒ 纯函数测到的就是线上跑的
    ("A2", APP_SWIFT, "delegate 必须转发到纯函数 allowedChannels(forBetaEnabled:)",
     r"UpdateService\.allowedChannels\s*\(\s*forBetaEnabled:", None),
    # ③ 纯函数：默认半边 = 空集（**安全的关键**）
    ("A3", APP_SWIFT, "纯函数必须存在，且默认（关）时返回**空集**",
     r"static\s+func\s+allowedChannels\s*\(\s*forBetaEnabled\s+\w+\s*:\s*Bool\s*\)\s*->\s*Set<String>", None),
    ("A4", APP_SWIFT, "纯函数实现必须是 `enabled ? [betaChannelName] : []`（关 ⇒ 空集）",
     r"enabled\s*\?\s*\[\s*betaChannelName\s*\]\s*:\s*\[\s*\]", None),
    # ④ 通道名与 appcast 里的字面量一致
    ("A5", APP_SWIFT, "通道名常量必须是 \"beta\"（必须与 appcast 的 <sparkle:channel> 逐字相同）",
     r'static\s+let\s+betaChannelName\s*=\s*"beta"', None),
    # ⑤ 设置项持久化
    ("A6", KEY_SWIFT, "UserDefaultsKey 必须有 updateBetaChannel",
     r"case\s+updateBetaChannel\s*=", None),
    ("A7", APP_SWIFT, "betaChannelEnabled 的读点必须是 `bool(forKey:)`（未设置 ⇒ **false** ⇒ 默认关）",
     r"bool\(forKey:\s*betaChannelKey\)", None),
    # ⑥ 设置页有那个开关
    ("A8", VIEW_SWIFT, "设置页必须有 beta 开关（读 UpdateService.betaChannelEnabled）",
     r"UpdateService\.betaChannelEnabled", None),
    # ⑦ 发布侧：appcast 写入通道
    ("B1", APPCAST_SH, "appcast 写入脚本必须能写 <sparkle:channel> 元素",
     r"<sparkle:channel>", None),
    ("B2", APPCAST_SH, "appcast 写入脚本必须有 channel 参数（默认空 ⇒ 稳定条目不带通道）",
     r'local\s+channel="\$\{6:-\}"', None),
    # ⑧ 发布脚本：beta 模式
    ("C1", RELEASE_SH, "release.sh 必须支持 --beta",
     r"--beta\)", None),
    ("C2", RELEASE_SH, "release.sh 必须有 beta 感知的版本比较（version_base）",
     r"version_base\(\)", None),
    ("C3", RELEASE_SH, "beta 模式必须**跳过** README 同步（预发布不进正式 changelog）",
     r"IS_BETA\s*-eq\s*1.*\n.*SKIP_README_SYNC=1", None),
    # ⑨ workflow：beta 接线
    ("D1", WORKFLOW, "workflow 必须有 Detect release channel 步骤",
     r"Detect\s+release\s+channel", None),
    ("D2", WORKFLOW, "workflow 必须把 beta 的 channel 传给 appcast 写入脚本",
     r'"beta"', None),
    ("D3", WORKFLOW, "workflow 必须给 beta Release 标 prerelease",
     r"prerelease:\s*\$\{\{\s*steps\.channel\.outputs\.is_beta\s*\}\}", None),
    ("D4", WORKFLOW, "workflow 必须在 beta 时**跳过** Homebrew tap 更新",
     r"is_beta\s*!=\s*'true'", None),
    ("D5", WORKFLOW, "workflow 必须把 beta 的 shortVersion（base）传给 appcast",
     r"steps\.channel\.outputs\.base_version", None),
    # ⑩ 回滚：beta 回滚**不动 tap**（beta 发布时没改过它 ⇒ 恢复会把 tap 退到更老版本）
    ("E1", ROLLBACK_SH, "回滚脚本必须在 beta 时**跳过** tap 恢复",
     r"if \[\[ \"\$VERSION\" == \*-beta\.\* \]\]; then\n.*不动 tap", None),
]


def _read(root, rel):
    path = os.path.join(root, rel)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8", errors="replace") as handle:
        return handle.read()


def check_text(texts):
    """texts = {相对路径: 内容} ⇒ ⇒ 返回问题列表。"""
    problems = []
    for cid, rel, desc, must, must_not in CHECKS:
        text = texts.get(rel)
        if text is None:
            problems.append(f"{cid}  {rel}  —— {desc}：文件不存在")
            continue
        if not re.search(must, text, re.M):
            problems.append(f"{cid}  {rel}  —— {desc}：判据不成立（缺 {must!r}）")
        if must_not and re.search(must_not, text, re.M):
            problems.append(f"{cid}  {rel}  —— {desc}：判据不成立（不该出现 {must_not!r}）")
    return problems


def check_repo(root="."):
    texts = {}
    missing = []
    for _cid, rel, _desc, _must, _must_not in CHECKS:
        if rel in texts:
            continue
        content = _read(root, rel)
        if content is None:
            missing.append(rel)
        else:
            texts[rel] = content
    if missing:
        print("❌ 缺少被检查的文件（不假装检查过）：", file=sys.stderr)
        for rel in sorted(set(missing)):
            print(f"   - {rel}", file=sys.stderr)
        return None
    return check_text(texts)


# ── 自检：合成夹具 ⇒ 每条判据**真的要红** ──────────────────────────
GOOD = {
    APP_SWIFT: (
        "final class FeedURLProvider: NSObject, SPUUpdaterDelegate {\n"
        "    func allowedChannels(for updater: SPUUpdater) -> Set<String> {\n"
        "        UpdateService.allowedChannels(forBetaEnabled: UpdateService.betaChannelEnabled)\n"
        "    }\n"
        "}\n"
        "final class UpdateService {\n"
        "    static let betaChannelName = \"beta\"\n"
        "    static var betaChannelEnabled: Bool {\n"
        "        get { Self.defaults.bool(forKey: betaChannelKey) }\n"
        "    }\n"
        "    static func allowedChannels(forBetaEnabled enabled: Bool) -> Set<String> {\n"
        "        enabled ? [betaChannelName] : []\n"
        "    }\n"
        "}\n"
    ),
    KEY_SWIFT: "enum UserDefaultsKey { case updateBetaChannel = \"UpdateBetaChannelEnabled\" }\n",
    VIEW_SWIFT: "Toggle(L10n.settingsUpdateBetaChannel, isOn: Binding(get: { UpdateService.betaChannelEnabled }))\n",
    APPCAST_SH: '    local channel="${6:-}"\n    print "      <sparkle:channel>"\n',
    RELEASE_SH: (
        "            --beta)              IS_BETA=1 ;;\n"
        "version_base() { printf '%s' \"${1%%-beta.*}\"; }\n"
        "    if [[ $IS_BETA -eq 1 ]]; then\n"
        "        SKIP_README_SYNC=1\n"
        "    fi\n"
    ),
    ROLLBACK_SH: (
        'if [[ "$VERSION" == *-beta.* ]]; then\n'
        '    log "⏭ beta 版回滚：**不动 tap**"\n'
        "else\n"
        'log "恢复 tap Cask 到 v${PREV}..."\n'
        "fi\n"
    ),
    WORKFLOW: (
        "      - name: Detect release channel (ID-BETA-0001)\n"
        "        id: channel\n"
        "            echo \"base_version=${VERSION%%-beta.*}\"\n"
        "      - name: appcast\n"
        "            ./Scripts/update_appcast.sh appcast.xml \"$VERSION\" tar \"$SIG\" \"url\" \"beta\" \"${{ steps.channel.outputs.base_version }}\"\n"
        "          prerelease: ${{ steps.channel.outputs.is_beta }}\n"
        "        if: github.event_name == 'push' && steps.channel.outputs.is_beta != 'true'\n"
    ),
}


def self_test():
    problems = []
    # ① 正向控制：合成夹具**全部成立** ⇒ 不该报红
    found = check_text(GOOD)
    if found:
        problems.append("正向控制失败（合成夹具本该全绿）：")
        problems.extend("   - " + p for p in found)
    # ② 反向控制：每条判据**单独**破坏 ⇒ 必须报红 ⇒ 否则那条判据没牙
    for cid, rel, desc, must, must_not in CHECKS:
        broken = dict(GOOD)
        if must_not:
            broken[rel] = broken[rel] + "\n" + must_not + "\n"
        else:
            broken[rel] = broken[rel] + "\n// deliberately broken by the self-test\n"
            # 破坏方式 = 删掉判据要求的那段（用一行注释占位不算 ⇒ 改成真的删）
            broken[rel] = re.sub(must, "/* removed by self-test */", broken[rel], count=1)
        found = check_text(broken)
        if not any(f.startswith(cid + " ") for f in found):
            problems.append(f"反向控制失败：{cid} 被破坏后**没有**报红 ⇒ 这条判据没有牙齿（{desc}）")
    if problems:
        print("❌ 自检失败：", file=sys.stderr)
        for p in problems:
            print("   " + p, file=sys.stderr)
        return 1
    print(f"✅ 自检通过：{len(CHECKS)} 条判据，正向控制全绿 + 反向控制**每条都红**")
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if "--self-test" in argv:
        return self_test()
    found = check_repo(".")
    if found is None:
        return 2
    if found:
        print("❌ beta 通道接线有问题：", file=sys.stderr)
        for p in found:
            print("   - " + p, file=sys.stderr)
        return 1
    print(f"✅ beta 通道接线正常：{len(CHECKS)} 条判据全部成立"
          "（app 端默认关 + 发布侧带通道 + 不动 tap）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
