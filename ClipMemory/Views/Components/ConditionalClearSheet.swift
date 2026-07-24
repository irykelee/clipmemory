import SwiftUI

/// "按条件删除"弹窗：类型（全部/文本/图片/链接/富文本）× 时间范围（全部/今天/昨天/更早）
/// 二维筛选删除，实时数量预览，确认后统一进回收站（跳过收藏条目）。
struct ConditionalClearSheet: View {
    @ObservedObject var store: ClipboardStore
    @Environment(\.dismiss) private var dismiss

    @State private var selectedType: ClipboardItemType?
    @State private var selectedRange: ClipboardStore.ClearRange = .all

    /// H-14 (2026-07-24 audit): the sheet's body previously consumed
    /// `matchingCount` twice (the count-preview `Text` line and the destructive
    /// button's `.disabled` modifier). Each body render evaluated the O(n)
    /// `store.items.filter` twice with identical inputs. Cache the result
    /// in a `let` inside body so SwiftUI evaluates it once per render
    /// instead of twice. Future optimization: promote to `@State` with
    /// `.onChange(of: store.items.count)` to skip recomputation entirely
    /// when the store changes but the type/range selection hasn't —
    /// out of scope for this fix.
    private var matchingCount: Int {
        store.items.filter { item in
            !item.isPinned
                && (selectedType == nil || item.type == selectedType)
                && store.isDate(item.createdAt, inClearRange: selectedRange)
        }.count
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(L10n.clearConditionalTitle)
                .font(.system(size: sz(14), weight: .semibold))

            Form {
                Picker(L10n.clearConditionalType, selection: $selectedType) {
                    Text(L10n.filterAll).tag(ClipboardItemType?.none)
                    Text(L10n.filterText).tag(ClipboardItemType?.some(.text))
                    Text(L10n.filterImage).tag(ClipboardItemType?.some(.image))
                    Text(L10n.filterLink).tag(ClipboardItemType?.some(.link))
                    Text(L10n.filterRichText).tag(ClipboardItemType?.some(.richText))
                }
                Picker(L10n.clearConditionalRange, selection: $selectedRange) {
                    ForEach(ClipboardStore.ClearRange.allCases, id: \.self) { range in
                        Text(rangeLabel(range)).tag(range)
                    }
                }
            }
            .formStyle(.grouped)

            // H-14: compute once, reuse. `let` declaration inside a view
            // builder is supported in SwiftUI (works on macOS 13+).
            let count = matchingCount

            Text(L10n.clearConditionalConfirm(count))
                .font(.system(size: sz(12)))
                .foregroundColor(.secondary)

            HStack(spacing: 12) {
                Button(L10n.buttonCancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L10n.buttonClear, role: .destructive) {
                    store.clearItems(type: selectedType, range: selectedRange)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(count == 0)
            }
        }
        .padding(20)
        .frame(width: 340)
    }

    private func rangeLabel(_ range: ClipboardStore.ClearRange) -> String {
        switch range {
        case .all: return L10n.filterAll
        case .today: return L10n.groupToday
        case .yesterday: return L10n.groupYesterday
        case .older: return L10n.groupOlder
        }
    }
}
