import SwiftUI

// MARK: - Reading Goal & Insights View

enum InsightsHorizon: String, CaseIterable, Identifiable {
    case last7Days = "Last 7 Days"
    case last30Days = "Last 30 Days"
    case thisYear = "This Year"
    case allTime = "All Time"

    var id: String { rawValue }
}

enum InsightsMetric: String, CaseIterable, Identifiable {
    case words = "Words"
    case works = "Works"

    var id: String { rawValue }
}

/// Modern macOS reading dashboard conforming to Apple HIG.
/// Combines goal pacing, reading velocity, streaks, day-by-day activity heatmap,
/// monthly reading volume, and StoryGraph reading analytics ported from Nectar.
struct ReadingGoalView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(LibrarySession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var onDismiss: (() -> Void)?

    @State private var isEditingGoal = false
    @State private var activeGoal: ReadingGoal?
    @State private var historyEntries: [ReadingHistoryEntry] = []
    @State private var bookTitles: [Int: String] = [:]
    @State private var historyReadCount: Int?

    // StoryGraph analytics state
    @State private var insightsHorizon: InsightsHorizon = .last30Days
    @State private var insightsMetric: InsightsMetric = .words
    @State private var insights = ReadingStatsInsights()

    // Goal editor state
    @State private var targetInput = 12
    @State private var periodStart = Calendar.current.date(
        from: Calendar.current.dateComponents([.year, .month], from: Date())
    ) ?? Date()
    @State private var periodEnd: Date = {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        return cal.date(byAdding: DateComponents(month: 1, day: -1), to: start) ?? start
    }()

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            contentBody
        }
        .frame(minWidth: 680, minHeight: 520)
        .task {
            await loadData()
        }
        .onChange(of: insightsHorizon) { _, _ in
            Task { await loadData() }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack {
            Image(systemName: "target")
                .foregroundStyle(Color.accentColor)
                .font(.title3)
            Text("Reading Goals & Insights")
                .font(.headline)

            Spacer()

            Button("Done") {
                doDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Content Body

    private var contentBody: some View {
        ScrollView {
            VStack(spacing: 18) {
                heroGoalCard
                if isEditingGoal {
                    goalEditorSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                scoperBar
                metricsPlatterGrid
                fandomBreakdownCard
                relationshipsCard
                tropesCard
                trendsSection
                recentSessionsCard
            }
            .padding(20)
        }
    }

    private var scoperBar: some View {
        HStack(spacing: 12) {
            Picker("Period", selection: $insightsHorizon) {
                ForEach(InsightsHorizon.allCases) { horizon in
                    Text(horizon.rawValue).tag(horizon)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Spacer()

            Picker("Metric", selection: $insightsMetric) {
                ForEach(InsightsMetric.allCases) { metric in
                    Text(metric.rawValue).tag(metric)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var heroGoalCard: some View {
        let booksRead = historyReadCount ?? 0
        let target = activeGoal?.targetBooksCount ?? targetInput
        let progress = target > 0 ? min(1.0, Double(booksRead) / Double(target)) : 0.0
        let pct = Int((progress * 100).rounded())

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(activeGoal == nil ? "Annual Reading Challenge" : "Active Reading Goal")
                            .font(.caption.bold())
                            .foregroundStyle(Color.accentColor)
                            .textCase(.uppercase)
                        if activeGoal == nil {
                            Text("• Default")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\(booksRead) of \(target) works completed")
                        .font(.title2.bold())
                    Text(goalPacingText(booksRead: booksRead, target: target))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // Circular Progress Ring
                ZStack {
                    Circle()
                        .stroke(Color.accentColor.opacity(0.15), lineWidth: 9)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            LinearGradient(
                                colors: [Color.accentColor, Color.accentColor.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 9, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(pct)%")
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                        Text("done")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 68, height: 68)
                .animation(reduceMotion ? nil : .spring(), value: progress)
            }

            ProgressView(value: progress)
                .tint(Color.accentColor)

            HStack {
                if let goal = activeGoal {
                    Text("\(dateFormatter.string(from: goal.periodStart)) – \(dateFormatter.string(from: goal.periodEnd))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditingGoal.toggle()
                    }
                } label: {
                    Label(
                        isEditingGoal ? "Hide Editor" : (activeGoal == nil ? "Set Goal" : "Adjust Goal"),
                        systemImage: isEditingGoal ? "chevron.up" : "pencil"
                    )
                    .font(.caption)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private func goalPacingText(booksRead: Int, target: Int) -> String {
        guard let goal = activeGoal else {
            let left = max(0, target - booksRead)
            return "\(left) work\(left == 1 ? "" : "s") remaining to reach goal"
        }

        let now = Date()
        guard now >= goal.periodStart else { return "Goal starts in the future" }
        let totalSpan = goal.periodEnd.timeIntervalSince(goal.periodStart)
        let elapsed = now.timeIntervalSince(goal.periodStart)
        guard totalSpan > 0 else { return "\(max(0, target - booksRead)) works remaining" }

        let timeFraction = min(1.0, elapsed / totalSpan)
        let expectedRead = Double(target) * timeFraction
        let diff = Double(booksRead) - expectedRead

        let daysRemaining = max(0, Int(goal.periodEnd.timeIntervalSince(now) / 86400))

        if diff >= 1.0 {
            return "🔥 \(Int(diff)) works ahead of pace • \(daysRemaining) days left"
        } else if diff <= -1.0 {
            return "⏳ \(abs(Int(diff))) works behind pace • \(daysRemaining) days left"
        } else {
            return "✨ Exactly on track • \(daysRemaining) days left"
        }
    }

    private let paletteColors: [Color] = [
        .purple,
        .blue,
        .teal,
        .pink,
        .orange,
        .green,
        .indigo
    ]

    private var metricsPlatterGrid: some View {
        let words = (insightsHorizon == .allTime) ? totalWordsRead : insights.totalWords
        let wph = insights.wordsPerHour > 0 ? insights.wordsPerHour : (totalActiveHours > 0 ? Double(totalWordsRead) / totalActiveHours : 0.0)
        let hours = (insightsHorizon == .allTime) ? totalActiveHours : (insights.activeSeconds / 3600.0)
        let streak = currentStreakDays

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            metricCard(
                title: "Words Read (\(insightsHorizon.rawValue))",
                value: formatWords(words),
                icon: "character.book.closed.fill",
                color: .accentColor
            )
            metricCard(
                title: "Reading Velocity",
                value: String(format: "%.0f w/h", wph),
                icon: "speedometer",
                color: .orange
            )
            metricCard(
                title: "Active Time",
                value: String(format: "%.1f hrs", hours),
                icon: "clock.fill",
                color: .blue
            )
            metricCard(
                title: "Current Streak",
                value: streak > 0 ? "\(streak) days" : "0 days",
                icon: "flame.fill",
                color: .red
            )
        }
    }

    private struct PieSlice: Shape {
        let startAngle: Angle
        let endAngle: Angle

        func path(in rect: CGRect) -> Path {
            var path = Path()
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(rect.width, rect.height) / 2
            path.move(to: center)
            path.addArc(
                center: center,
                radius: radius,
                startAngle: startAngle - .degrees(90),
                endAngle: endAngle - .degrees(90),
                clockwise: false
            )
            path.closeSubpath()
            return path
        }
    }

    private struct FandomWedge: Identifiable {
        let id: Int
        let name: String
        let value: Int
        let color: Color
        let start: Angle
        let end: Angle
        let percentage: Double
    }

    private var fandomWedges: [FandomWedge] {
        let items = insights.topFandoms
        guard !items.isEmpty else { return [] }
        let rawSlices: [(name: String, value: Int)] = items.map {
            ($0.name, insightsMetric == .words ? $0.words : $0.works)
        }
        let topSlices: [(name: String, value: Int)]
        if rawSlices.count > 4 {
            let top4 = Array(rawSlices.prefix(4))
            let otherValue = rawSlices.dropFirst(4).reduce(0) { $0 + $1.value }
            topSlices = otherValue > 0 ? top4 + [("Other", otherValue)] : top4
        } else {
            topSlices = rawSlices
        }
        let total = max(1, topSlices.reduce(0) { $0 + $1.value })
        var cumulative = 0.0
        return topSlices.enumerated().map { index, slice in
            let fraction = Double(slice.value) / Double(total)
            let start = Angle(degrees: cumulative * 360)
            cumulative += fraction
            let end = Angle(degrees: cumulative * 360)
            let color = paletteColors[index % paletteColors.count]
            return FandomWedge(
                id: index,
                name: slice.name,
                value: slice.value,
                color: color,
                start: start,
                end: end,
                percentage: fraction * 100.0
            )
        }
    }

    private var fandomBreakdownCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Fandoms")
                        .font(.headline)
                    Text(insightsMetric == .words ? "Share of total words read" : "Share of completed works")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if fandomWedges.isEmpty {
                Text("No fandom reading data recorded for this time period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                HStack(spacing: 24) {
                    ZStack {
                        ForEach(fandomWedges) { wedge in
                            PieSlice(startAngle: wedge.start, endAngle: wedge.end)
                                .fill(wedge.color)
                        }
                        Circle()
                            .fill(Color(NSColor.windowBackgroundColor))
                            .frame(width: 52, height: 52)
                    }
                    .frame(width: 104, height: 104)

                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(fandomWedges) { wedge in
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(wedge.color)
                                    .frame(width: 8, height: 8)
                                Text(wedge.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Spacer()
                                Text(insightsMetric == .words ? formatWords(wedge.value) : "\(wedge.value) \(wedge.value == 1 ? "work" : "works")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0f%%", wedge.percentage))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 36, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var relationshipsCard: some View {
        let rels = insights.topRelationships
        let maxValue = rels.map { insightsMetric == .words ? $0.words : $0.works }.max() ?? 1

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Ships & Relationships")
                        .font(.headline)
                    Text("Ranked by frequency in reading history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if rels.isEmpty {
                Text("No relationship metadata recorded for this time period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 10) {
                    ForEach(Array(rels.prefix(5))) { rel in
                        let value = insightsMetric == .words ? rel.words : rel.works
                        let fraction = maxValue > 0 ? min(1.0, Double(value) / Double(maxValue)) : 0.0

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(rel.name)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)

                                Text(rel.isRomantic ? "Romantic (/)" : "Platonic (&)")
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(
                                        rel.isRomantic ? Color.pink.opacity(0.12) : Color.blue.opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: 4)
                                    )
                                    .foregroundStyle(rel.isRomantic ? Color.pink : Color.blue)

                                Spacer()

                                Text(insightsMetric == .words ? formatWords(value) : "\(value) \(value == 1 ? "work" : "works")")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(Color.secondary.opacity(0.12))
                                        .frame(height: 6)
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(rel.isRomantic ? Color.pink : Color.blue)
                                        .frame(width: max(4, geo.size.width * fraction), height: 6)
                                }
                            }
                            .frame(height: 6)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var tropesCard: some View {
        let tags = insights.topTags

        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Top Tropes & Themes")
                        .font(.headline)
                    Text("Most frequent story tags in works read")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if tags.isEmpty {
                Text("No tag metadata recorded for this time period.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(Array(tags.prefix(12))) { tag in
                        HStack(spacing: 5) {
                            Text(tag.name)
                                .font(.caption.weight(.medium))
                            let label = insightsMetric == .words ? formatWords(tag.words) : "\(tag.works)"
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private func metricCard(title: String, value: String, icon: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.bold())
                    .foregroundStyle(.primary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private var recentSessionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent Reading Activity")
                    .font(.headline)
                Spacer()
                Text("\(historyEntries.count) sessions recorded")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if historyEntries.isEmpty {
                Text("No recent reading sessions recorded. Open a book to start tracking reading progress.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(historyEntries.prefix(5))) { entry in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.7))
                                .frame(width: 6, height: 6)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(bookTitle(for: entry.calibreID))
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text(entry.sessionStart, style: .date)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    if let words = entry.wordsRead, words > 0 {
                                        Text("•").foregroundStyle(.tertiary)
                                        Text("\(formatWords(words))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Spacer()
                            if let endPct = entry.percentEnd {
                                Text("\(Int(endPct * 100))%")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                            }
                        }
                        .padding(.vertical, 6)
                        if entry.id != historyEntries.prefix(5).last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Trends & Heatmap Section

    private var trendsSection: some View {
        VStack(spacing: 16) {
            heatmapCard
            monthlyVolumeCard
        }
    }

    private var heatmapCard: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let dayWords = dailyWordCounts

        // 12 weeks of days (84 days)
        let totalDays = 84
        let days: [Date] = (0..<totalDays).compactMap { offset in
            calendar.date(byAdding: .day, value: -(totalDays - 1 - offset), to: today)
        }

        let maxWords = dayWords.values.max() ?? 1

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Daily Reading Activity")
                        .font(.headline)
                    Text("Last 12 weeks of reading sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 4) {
                    Text("Less").font(.caption2).foregroundStyle(.secondary)
                    ForEach(0..<5) { level in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(heatColor(fraction: Double(level) / 4.0))
                            .frame(width: 9, height: 9)
                    }
                    Text("More").font(.caption2).foregroundStyle(.secondary)
                }
            }

            // Grid: 12 columns x 7 rows
            HStack(spacing: 3) {
                ForEach(0..<12, id: \.self) { col in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { row in
                            let index = col * 7 + row
                            if index < days.count {
                                let day = days[index]
                                let key = dayKey(for: day)
                                let words = dayWords[key] ?? 0
                                let fraction = maxWords > 0 ? min(1.0, Double(words) / Double(maxWords)) : 0.0

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(heatColor(fraction: fraction, hasActivity: words > 0))
                                    .frame(width: 13, height: 13)
                                    .help("\(dateFormatter.string(from: day)): \(formatWords(words))")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 6)
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    private func heatColor(fraction: Double, hasActivity: Bool = true) -> Color {
        if !hasActivity || fraction <= 0 {
            return Color.secondary.opacity(0.12)
        }
        if fraction < 0.25 {
            return Color.accentColor.opacity(0.35)
        } else if fraction < 0.5 {
            return Color.accentColor.opacity(0.6)
        } else if fraction < 0.75 {
            return Color.accentColor.opacity(0.8)
        } else {
            return Color.accentColor
        }
    }

    private var monthlyVolumeCard: some View {
        let monthlyData = monthlyWordBreakdown
        let maxMonthly = monthlyData.values.max() ?? 1

        return VStack(alignment: .leading, spacing: 12) {
            Text("Monthly Reading Volume (\(Calendar.current.component(.year, from: Date())))")
                .font(.headline)

            HStack(alignment: .bottom, spacing: 8) {
                ForEach(1...12, id: \.self) { month in
                    let words = monthlyData[month] ?? 0
                    let heightFraction = maxMonthly > 0 ? min(1.0, Double(words) / Double(maxMonthly)) : 0.0
                    let barHeight = max(6.0, 100.0 * heightFraction)

                    VStack(spacing: 4) {
                        Text(words > 0 ? formatShortWords(words) : "")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(height: 10)

                        RoundedRectangle(cornerRadius: 3)
                            .fill(words > 0 ? Color.accentColor : Color.secondary.opacity(0.15))
                            .frame(height: barHeight)

                        Text(monthShortName(month))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 140)
            .padding(.top, 8)
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Goal Editor Section

    private var goalEditorSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(activeGoal == nil ? "Create a Reading Goal" : "Edit Reading Goal")
                .font(.title3.bold())

            Text("Set your target number of books and timeline. Progress is automatically calculated as you read works in your library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            // Presets
            HStack(spacing: 8) {
                Button("This Month") {
                    setPreset(months: 1)
                }
                .buttonStyle(.bordered)

                Button("Next 3 Months") {
                    setPreset(months: 3)
                }
                .buttonStyle(.bordered)

                Button("Full Year") {
                    setPreset(months: 12)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.small)

            Divider()

            // Form inputs
            VStack(spacing: 12) {
                HStack {
                    Label("Target Works:", systemImage: "books.vertical.fill")
                    Spacer()
                    Stepper("\(targetInput) works", value: $targetInput, in: 1...9999)
                        .fixedSize()
                }

                HStack {
                    Label("Start Date:", systemImage: "calendar.badge.clock")
                    Spacer()
                    DatePicker("", selection: $periodStart, displayedComponents: .date)
                        .labelsHidden()
                }

                HStack {
                    Label("End Date:", systemImage: "flag.checkered")
                    Spacer()
                    DatePicker("", selection: $periodEnd, in: periodStart..., displayedComponents: .date)
                        .labelsHidden()
                }
            }
            .padding(14)
            .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                if let goal = activeGoal {
                    Button("Delete Goal", role: .destructive) {
                        deleteGoal(goal)
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button("Cancel") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isEditingGoal = false
                    }
                }
                .buttonStyle(.bordered)

                Button(activeGoal == nil ? "Save Goal" : "Update Goal") {
                    saveGoal()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(periodEnd < periodStart)
            }
        }
        .padding(16)
        .background(Color(NSColor.windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(NSColor.separatorColor).opacity(0.4), lineWidth: 0.5))
    }

    // MARK: - Computations & Data Helpers

    private var totalWordsRead: Int {
        historyEntries.compactMap(\.wordsRead).reduce(0, +)
    }

    private var totalActiveHours: Double {
        let totalSeconds = historyEntries.reduce(0.0) { sum, entry in
            sum + max(0, entry.sessionEnd.timeIntervalSince(entry.sessionStart))
        }
        return totalSeconds / 3600.0
    }

    private var dailyWordCounts: [String: Int] {
        var counts: [String: Int] = [:]
        for entry in historyEntries {
            let key = dayKey(for: entry.sessionStart)
            counts[key, default: 0] += entry.wordsRead ?? 0
        }
        return counts
    }

    private var currentStreakDays: Int {
        let counts = dailyWordCounts
        let calendar = Calendar.current
        var current = 0
        var checkDate = calendar.startOfDay(for: Date())

        // If today has activity, start from today; else start from yesterday
        let todayKey = dayKey(for: checkDate)
        if (counts[todayKey] ?? 0) == 0 {
            checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
        }

        while true {
            let key = dayKey(for: checkDate)
            if let words = counts[key], words > 0 {
                current += 1
                checkDate = calendar.date(byAdding: .day, value: -1, to: checkDate) ?? checkDate
            } else {
                break
            }
        }
        return current
    }

    private var monthlyWordBreakdown: [Int: Int] {
        let calendar = Calendar.current
        let currentYear = calendar.component(.year, from: Date())
        var counts: [Int: Int] = [:]
        for entry in historyEntries {
            let entryYear = calendar.component(.year, from: entry.sessionStart)
            if entryYear == currentYear {
                let month = calendar.component(.month, from: entry.sessionStart)
                counts[month, default: 0] += entry.wordsRead ?? 0
            }
        }
        return counts
    }

    private func dayKey(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }

    private func monthShortName(_ month: Int) -> String {
        let formatter = DateFormatter()
        return formatter.shortMonthSymbols[max(0, min(11, month - 1))]
    }

    private func formatWords(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func formatShortWords(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000.0)
        }
        if count >= 1_000 {
            return String(format: "%.0fk", Double(count) / 1_000.0)
        }
        return "\(count)"
    }

    private func bookTitle(for calibreID: Int) -> String {
        bookTitles[calibreID] ?? "Work #\(calibreID)"
    }

    private func setPreset(months: Int) {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: Date())) ?? Date()
        let end = cal.date(byAdding: DateComponents(month: months, day: -1), to: start) ?? start
        periodStart = start
        periodEnd = end
    }

    private func doDismiss() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    // MARK: - Database Logic

    private func resolveHorizonDates(_ horizon: InsightsHorizon) -> (Date?, Date?) {
        let now = Date()
        let cal = Calendar.current
        switch horizon {
        case .last7Days:
            let start = cal.date(byAdding: .day, value: -7, to: now)
            return (start, now)
        case .last30Days:
            let start = cal.date(byAdding: .day, value: -30, to: now)
            return (start, now)
        case .thisYear:
            let comps = cal.dateComponents([.year], from: now)
            let start = cal.date(from: comps)
            return (start, now)
        case .allTime:
            return (nil, nil)
        }
    }

    private func loadData() async {
        guard let metaDB = session.metaDB else { return }
        let goal = await metaDB.currentReadingGoal()
        let history = (try? await metaDB.recentReadingHistory(limit: 500)) ?? []

        let uniqueBookIDs = Array(Set(history.map(\.calibreID)))
        var titles: [Int: String] = [:]
        if let library = session.library, !uniqueBookIDs.isEmpty {
            let books = await library.booksForIDs(uniqueBookIDs)
            for book in books {
                titles[book.id] = book.displayTitle
            }
        }

        let (startDate, endDate) = resolveHorizonDates(insightsHorizon)
        let newInsights = (try? await metaDB.readingStatsInsights(start: startDate, end: endDate)) ?? ReadingStatsInsights()

        await MainActor.run {
            self.activeGoal = goal
            self.historyEntries = history
            self.bookTitles = titles
            self.insights = newInsights
            if let goal {
                self.targetInput = goal.targetBooksCount
                self.periodStart = goal.periodStart
                self.periodEnd = goal.periodEnd
            }
        }
        await refreshHistoryProgress()
    }

    private func refreshHistoryProgress() async {
        guard let goal = activeGoal, let metaDB = session.metaDB else {
            await MainActor.run { historyReadCount = nil }
            return
        }
        let start = goal.periodStart
        let end = Calendar.current.date(
            bySettingHour: 23, minute: 59, second: 59, of: goal.periodEnd
        ) ?? goal.periodEnd

        let count = (try? await metaDB.completedBooksCount(start: start, end: end)) ?? 0
        await MainActor.run {
            self.historyReadCount = count
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
            await loadData()
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isEditingGoal = false
                }
            }
        }
    }

    private func deleteGoal(_ goal: ReadingGoal) {
        Task {
            guard let metaDB = session.metaDB else { return }
            try? await metaDB.deleteReadingGoal(id: goal.id)
            await MainActor.run {
                self.activeGoal = nil
                self.historyReadCount = nil
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.isEditingGoal = false
                }
            }
        }
    }
}
