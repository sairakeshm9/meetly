import MeetingCore
import SwiftUI

struct AnswerTableView: View {
    @Environment(\.surfaceOpacity) private var surfaceOpacity
    let table: MarkdownAnswerTable
    let fontSize: Double
    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(table.headers.enumerated()), id: \.offset) { _, cell in
                        Text(AnswerTypography.emphasized(cell)).bold().padding(9)
                            .frame(width: 160, alignment: .leading)
                            .background(Color.primary.opacity(0.08 * surfaceOpacity))
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(AnswerTypography.emphasized(cell)).padding(9)
                                .frame(width: 160, alignment: .leading)
                                .background(
                                    Color.primary.opacity(
                                        (index.isMultiple(of: 2) ? 0.025 : 0.05) * surfaceOpacity))
                        }
                    }
                }
            }.font(.system(size: fontSize)).textSelection(.enabled)
        }.fixedSize(horizontal: false, vertical: true)
    }
}
