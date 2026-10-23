import SwiftUI

struct TagSelectField: View {
    let title: String
    let field: AO3FacetField
    let tagField: AO3FilterPopupState.StringTagField
    @Bindable var state: AO3FilterPopupState
    let facetController: AO3FilterFacetController
    let onTagChanged: () -> Void

    @State private var showingPicker: Bool = false

    private var activeTags: [(name: String, isIncluded: Bool)] {
        var tags: [(name: String, isIncluded: Bool)] = []
        let included: Set<String>
        let excluded: Set<String>
        switch tagField {
        case .fandom:
            included = state.includedFandoms
            excluded = state.excludedFandoms
        case .relationship:
            included = state.includedRelationships
            excluded = state.excludedRelationships
        case .character:
            included = state.includedCharacters
            excluded = state.excludedCharacters
        case .freeform:
            included = state.includedFreeforms
            excluded = state.excludedFreeforms
        case .author:
            included = state.includedAuthors
            excluded = state.excludedAuthors
        }
        for item in included.sorted() {
            tags.append((item, true))
        }
        for item in excluded.sorted() {
            tags.append((item, false))
        }
        return tags
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.headline)

                if !activeTags.isEmpty {
                    Text("\(activeTags.count)")
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                Button {
                    showingPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                        Text("Add")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $showingPicker, arrowEdge: .trailing) {
                    TagPickerPopover(
                        title: title,
                        field: field,
                        tagField: tagField,
                        state: state,
                        facetController: facetController,
                        onTagChanged: onTagChanged
                    )
                }
            }

            if activeTags.isEmpty {
                Text("None selected")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 2)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(activeTags, id: \.name) { tag in
                        TagChip(
                            name: tag.name,
                            isIncluded: tag.isIncluded,
                            onRemove: {
                                state.removeTag(tag.name, field: tagField)
                                onTagChanged()
                            },
                            onCycle: {
                                state.cycleTag(tag.name, field: tagField)
                                onTagChanged()
                            }
                        )
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct TagChip: View {
    let name: String
    let isIncluded: Bool
    let onRemove: () -> Void
    let onCycle: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onCycle) {
                HStack(spacing: 4) {
                    Image(systemName: isIncluded ? "checkmark" : "minus")
                        .font(.system(size: 9, weight: .bold))
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(isIncluded ? Color.accentColor : Color.red)
            }
            .buttonStyle(.plain)
            .padding(.leading, 2)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isIncluded ? Color.accentColor.opacity(0.12) : Color.red.opacity(0.12))
        .foregroundColor(isIncluded ? .accentColor : .red)
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(isIncluded ? Color.accentColor.opacity(0.3) : Color.red.opacity(0.3), lineWidth: 0.5)
        )
    }
}
