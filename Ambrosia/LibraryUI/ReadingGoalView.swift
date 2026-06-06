import SwiftUI
import SwiftData

// MARK: - Reading Goal sheet

/// Sheet that displays reading progress and lets the user set a goal.
///
/// Progress is counted by looking at `BookState` records where
/// `lastOpenedDate` falls within [periodStart, periodEnd] and
/// `totalReadPercent >= 0.8` (≥ 80% read counts as "finished").
///
/// Session time tracking: `ReaderWindowController` stores
/// `sessionStartDate` at window load and diffs on `windowWillClose`.
struct ReadingGoalView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var goals: [ReadingGoal]

    // New goal input state
    @State private var targetInput = 12
    @State private var periodStart = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date()))!
    @State private var periodEnd: Date = {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
        return cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
    }()
    @State private var isEditing = false

    var activeGoal: ReadingGoal? { goals.first }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 20) {
                    if let goal = activeGoal {
                        progressSection(goal: goal)
                        Divider()
                    }
                    goalEditorSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 360, minHeight: 300)
        .onAppear { prepopulateEditor() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Text("Reading Goal").font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func progressSection(goal: ReadingGoal) -> some View {
        let booksRead = booksReadCount(for: goal)
        let progress = goal.targetBooksCount > 0
            ? min(1.0, Double(booksRead) / Double(goal.targetBooksCount)) : 0.0
        let pct = Int(progress * 100)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Goal")
                        .font(.caption).foregroundStyle(.secondary).textCase(.uppercase)
                    Text("\(goal.targetBooksCount) books")
                        .font(.title2.bold())
                    Text("\(formatter.string(from: goal.periodStart)) – \(formatter.string(from: goal.periodEnd))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                // Ring-style progress indicator
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 8)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(pct)%")
                        .font(.caption.bold())
                }
                .frame(width: 60, height: 60)
                .animation(.spring(), value: progress)
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(booksRead)")
                    .font(.title3.bold())
                    .foregroundStyle(Color.accentColor)
                Text("of \(goal.targetBooksCount) books read")
                    .font(.subheadline).foregroundStyle(.secondary)
            }

            ProgressView(value: progress)
                .tint(Color.accentColor)

            if !isEditing {
                HStack {
                    Spacer()
                    Button("Edit Goal") { isEditing = true }
                        .buttonStyle(.borderless).font(.callout)
                    Button("Delete Goal", role: .destructive) {
                        modelContext.delete(goal)
                        try? modelContext.save()
                        isEditing = false
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var goalEditorSection: some View {
        if isEditing || activeGoal == nil {
            VStack(alignment: .leading, spacing: 16) {
                Text(activeGoal == nil ? "Set a Reading Goal" : "Edit Goal")
                    .font(.headline)

                HStack {
                    Text("Target books:")
                    Spacer()
                    Stepper("\(targetInput) books", value: $targetInput, in: 1...9999)
                        .fixedSize()
                }

                HStack {
                    Text("Start date:")
                    Spacer()
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden()
                }

                HStack {
                    Text("End date:")
                    Spacer()
                    DatePicker("", selection: $periodEnd,
                               in: periodStart...,
                               displayedComponents: .date)
                        .labelsHidden()
                }

                HStack {
                    if isEditing {
                        Button("Cancel") { isEditing = false }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(activeGoal == nil ? "Create Goal" : "Save Goal") {
                        saveGoal()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(periodEnd < periodStart)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Image(systemName: "info.circle").foregroundStyle(.secondary).font(.caption)
            Text("A book counts as read when ≥ 80% of it has been opened during the goal period.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Logic

    /// Count BookState records where lastOpenedDate is within the goal period
    /// and totalReadPercent >= 0.8.
    private func booksReadCount(for goal: ReadingGoal) -> Int {
        let start = goal.periodStart
        let end   = goal.periodEnd
        let desc  = FetchDescriptor<BookState>()
        let all   = (try? modelContext.fetch(desc)) ?? []
        return all.filter { state in
            state.lastOpenedDate >= start
                && state.lastOpenedDate <= end
                && state.totalReadPercent >= 0.8
        }.count
    }

    private func saveGoal() {
        if let existing = activeGoal {
            existing.targetBooksCount = targetInput
            existing.periodStart      = periodStart
            existing.periodEnd        = periodEnd
        } else {
            let goal = ReadingGoal(
                targetBooksCount: targetInput,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
            modelContext.insert(goal)
        }
        try? modelContext.save()
        isEditing = false
    }

    private func prepopulateEditor() {
        if let goal = activeGoal {
            targetInput = goal.targetBooksCount
            periodStart = goal.periodStart
            periodEnd   = goal.periodEnd
        }
    }
}
