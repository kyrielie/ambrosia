import SwiftUI

// MARK: - Reading Goal sheet

/// Sheet that displays reading progress and lets the user set a goal.
///
/// Progress is counted by looking at `reading_history` records and `book_state`
/// records in ambrosia_meta.db where the reading session or lastOpenedDate
/// falls within [periodStart, periodEnd] and totalReadPercent >= 0.98.
struct ReadingGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibrarySession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var activeGoal: ReadingGoal?

    // New goal input state
    @State private var targetInput = 12
    @State private var periodStart = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())) ?? Date()
    @State private var periodEnd: Date = {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
    }()
    @State private var isEditing = false
    @State private var historyReadCount: Int?

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
        .onAppear {
            loadGoal()
        }
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
        let booksRead = historyReadCount ?? 0
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
                .animation(reduceMotion ? nil : .spring(), value: progress)
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
                        deleteGoal(goal)
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
            Text("A book counts as read when at least 98% has been read during the goal period.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: - Logic

    private func loadGoal() {
        Task {
            guard let metaDB = session.metaDB else { return }
            let goal = await metaDB.currentReadingGoal()
            await MainActor.run {
                self.activeGoal = goal
                if let goal {
                    self.targetInput = goal.targetBooksCount
                    self.periodStart = goal.periodStart
                    self.periodEnd = goal.periodEnd
                }
                self.refreshHistoryProgress()
            }
        }
    }

    private func saveGoal() {
        Task {
            guard let metaDB = session.metaDB else { return }
            try? await metaDB.saveReadingGoal(
                targetBooksCount: targetInput,
                periodStart: periodStart,
                periodEnd: periodEnd
            )
            await MainActor.run {
                self.isEditing = false
                self.loadGoal()
            }
        }
    }

    private func deleteGoal(_ goal: ReadingGoal) {
        Task {
            guard let metaDB = session.metaDB else { return }
            try? await metaDB.deleteReadingGoal(id: goal.id)
            await MainActor.run {
                self.activeGoal = nil
                self.isEditing = false
                self.historyReadCount = nil
            }
        }
    }

    private func refreshHistoryProgress() {
        guard let goal = activeGoal else {
            historyReadCount = nil
            return
        }
        let start = goal.periodStart
        let end = Calendar.current.date(
            bySettingHour: 23,
            minute: 59,
            second: 59,
            of: goal.periodEnd
        ) ?? goal.periodEnd
        Task {
            guard let metaDB = session.metaDB else {
                await MainActor.run { historyReadCount = nil }
                return
            }
            do {
                let count = try await metaDB.completedBooksCount(start: start, end: end)
                await MainActor.run { historyReadCount = count }
            } catch {
                await MainActor.run { historyReadCount = nil }
            }
        }
    }
}
