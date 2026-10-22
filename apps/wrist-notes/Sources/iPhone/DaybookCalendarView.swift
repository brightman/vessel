import SwiftUI

struct DaybookCalendarView: View {
    @Binding var selectedDate: Date
    let recordDates: [Date]
    var onMonthChange: (Date) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var month: Date
    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)

    init(selectedDate: Binding<Date>, recordDates: [Date], onMonthChange: @escaping (Date) -> Void = { _ in }) {
        _selectedDate = selectedDate
        self.recordDates = recordDates
        self.onMonthChange = onMonthChange
        _month = State(initialValue: Calendar.current.dateInterval(of: .month, for: selectedDate.wrappedValue)?.start ?? selectedDate.wrappedValue)
    }
    private var monthStart: Date { calendar.dateInterval(of: .month, for: month)?.start ?? month }
    private var leadingDays: Int { (calendar.component(.weekday, from: monthStart) + 5) % 7 }
    private var dayCount: Int { calendar.range(of: .day, in: .month, for: month)?.count ?? 0 }
    private var recordedDays: Set<Date> { Set(recordDates.map { calendar.startOfDay(for: $0) }) }

    var body: some View {
        DaybookSheetLayout(title: "回看某一天", onClose: { dismiss() }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(calendar.component(.year, from: month), format: .number.grouping(.never))年\(calendar.component(.month, from: month))月")
                        .font(.system(size: 20, weight: .medium))
                    Spacer(minLength: 0)
                    Button { moveMonth(-1) } label: { DaybookIcon("ChevronLeft", size: 16).frame(width: 30, height: 30) }.accessibilityLabel("上个月")
                    Button { moveMonth(1) } label: { DaybookIcon("ChevronRight", size: 16).frame(width: 30, height: 30) }
                        .disabled(calendar.isDate(month, equalTo: .now, toGranularity: .month)).accessibilityLabel("下个月")
                }.padding(.top, 10).padding(.bottom, 17)
                LazyVGrid(columns: columns, spacing: 5) {
                    ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { day in
                        Text(day).font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).frame(maxWidth: .infinity).padding(.bottom, 10)
                    }
                    ForEach(0..<(leadingDays + dayCount), id: \.self) { cell in
                        if cell < leadingDays { Color.clear.frame(height: 39) }
                        else if let date = calendar.date(byAdding: .day, value: cell - leadingDays, to: monthStart) { dayCell(date) }
                    }
                }
                Text("圆点表示这天有记录。今天是 \(DaybookFormat.day(.now))。")
                    .font(.system(size: 10)).foregroundStyle(DaybookStyle.secondary).padding(.top, 17).padding(.bottom, 3)
            }
        }
        .onAppear { onMonthChange(month) }
        .onChange(of: month) { _, value in onMonthChange(value) }
    }
    private func dayCell(_ date: Date) -> some View {
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let hasRecords = recordedDays.contains(calendar.startOfDay(for: date))
        let future = date > calendar.startOfDay(for: .now)
        return Button { selectedDate = date; dismiss() } label: {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 13)).frame(width: 39, height: 39)
                .foregroundStyle(selected ? DaybookStyle.white : DaybookStyle.ink)
                .background(selected ? DaybookStyle.accent : .clear, in: Circle())
                .overlay(alignment: .bottom) {
                    if hasRecords { Circle().fill(selected ? DaybookStyle.white : DaybookStyle.accent).frame(width: 3, height: 3).padding(.bottom, 4) }
                }.frame(maxWidth: .infinity).opacity(future ? 0.45 : 1)
        }.disabled(future).accessibilityLabel("\(DaybookFormat.day(date))\(hasRecords ? "，有记录" : "")")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func moveMonth(_ offset: Int) {
        if let target = calendar.date(byAdding: .month, value: offset, to: monthStart) { month = target }
    }
}
