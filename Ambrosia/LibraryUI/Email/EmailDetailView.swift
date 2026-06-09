import SwiftUI
import SwiftData

// MARK: - EmailDetailView

/// Right pane of the email split view.
/// Shows full book metadata when a book is selected; placeholder when none is selected.
struct EmailDetailView: View {
    let book: CalibreBook?
    let bookState: BookState?
    let modelContext: ModelContext
    let libraryRoot: URL?

    var body: some View {
        if let book {
            BookDetailContent(
                book: book,
                bookState: bookState,
                modelContext: modelContext,
                libraryRoot: libraryRoot
            )
        } else {
            noSelectionPlaceholder
        }
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "doc.text")
                .font(.system(size: 40))
                .foregroundStyle(.quaternary)
            Text("Select a book")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - BookDetailContent

private struct BookDetailContent: View {
    let book: CalibreBook
    let bookState: BookState?
    let modelContext: ModelContext
    let libraryRoot: URL?

    // AO3 buckets computed once
    private let buckets: AO3TagBuckets

    init(book: CalibreBook, bookState: BookState?, modelContext: ModelContext, libraryRoot: URL?) {
        self.book        = book
        self.bookState   = bookState
        self.modelContext = modelContext
        self.libraryRoot  = libraryRoot
        self.buckets     = AO3TagBuckets.from(tags: book.tags)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Cover + title block
                HStack(alignment: .top, spacing: 14) {
                    coverThumbnail
                    VStack(alignment: .leading, spacing: 5) {
                        Text(book.displayTitle)
                            .font(.title2).bold()
                            .fixedSize(horizontal: false, vertical: true)
                        metaLine
                    }
                }

                Divider()

                // Tags
                if hasTags {
                    tagsBlock
                }

                // Stats row
                statsRow

                // Reading progress
                if let pct = bookState?.totalReadPercent, pct > 0 {
                    progressRow(pct)
                }

                // Description
                if let comment = book.displayComment {
                    Text(comment)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                HStack {
                    Spacer()
                    Button {
                        AppDelegate.shared?.openReaderWindow(book: book, modelContext: modelContext)
                    } label: {
                        Label("Open Book", systemImage: "book.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
                .padding(.bottom, 20)
            }
            .padding(20)
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var coverThumbnail: some View {
        if let root = libraryRoot, let url = book.coverURL(libraryRoot: root) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 80, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .shadow(radius: 3)
                default:
                    coverPlaceholder
                }
            }
        } else {
            coverPlaceholder
        }
    }

    private var coverPlaceholder: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Color.accentColor.opacity(0.15))
            .frame(width: 80, height: 110)
            .overlay(
                Text(book.displayTitle.prefix(2).uppercased())
                    .font(.title2.bold())
                    .foregroundStyle(Color.accentColor)
            )
    }

    private var metaLine: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !book.authors.isEmpty {
                Text(book.displayAuthors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let series = book.displaySeries {
                Text(series)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var hasTags: Bool {
        !buckets.ratings.isEmpty || !buckets.warnings.isEmpty
            || !buckets.categories.isEmpty || !buckets.regular.isEmpty
    }

    private var tagsBlock: some View {
        CachedFlowLayout(spacing: 4) {
            ForEach(buckets.ratings, id: \.self)    { tag in tagPill(tag, .orange) }
            ForEach(buckets.categories, id: \.self) { tag in tagPill(tag, .blue)   }
            ForEach(buckets.warnings, id: \.self)   { tag in tagPill(tag, .red)    }
            ForEach(buckets.regular, id: \.self)    { tag in tagPill(tag, nil)     }
        }
    }

    private func tagPill(_ label: String, _ color: Color?) -> some View {
        return Text(label)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((color ?? .secondary).opacity(0.15))
            .foregroundStyle(color ?? .secondary)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var statsRow: some View {
        let wc = book.displayWordCount
        let k  = book.displayKudos
        if !wc.isEmpty || !k.isEmpty {
            HStack(spacing: 16) {
                if !wc.isEmpty { Label(wc, systemImage: "text.word.spacing").font(.caption).foregroundStyle(.secondary) }
                if !k.isEmpty  { Label(k,  systemImage: "heart").font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
        }
    }

    private func progressRow(_ pct: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(String(format: "%.0f%% read", pct * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                        .frame(height: 4)
                    Capsule().fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(min(pct, 1.0)), height: 4)
                }
            }
            .frame(height: 4)
        }
    }
}
