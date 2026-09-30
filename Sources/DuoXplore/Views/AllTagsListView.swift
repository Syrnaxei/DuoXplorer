import SwiftUI

/// 「所有标签」页左列：标签选择列表（按名称本地化排序，同 Finder）
struct AllTagsListView: View {
    @Binding var selection: FinderTag?

    private var sortedTags: [FinderTag] {
        FinderTag.all.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(sortedTags, id: \.name) { tag in
                row(for: tag)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 8)
    }

    private func row(for tag: FinderTag) -> some View {
        let isSelected = selection == tag
        return HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: tag.color))
                .frame(width: 10, height: 10)
            Text(tag.name)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? Color(nsColor: .alternateSelectedControlTextColor) : .primary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { selection = tag }
        .padding(.horizontal, 6)
    }
}
