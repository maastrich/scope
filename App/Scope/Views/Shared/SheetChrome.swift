import SwiftUI

// A sheet's own chrome, in place of `Form` / `.formStyle(.grouped)` / `Section` / `LabeledContent`.
//
// The same move the settings window made (`SettingsChrome.swift`), for the same reason: a grouped form draws
// inset rounded boxes, a system label column and bezelled fields, and no control inside it can make the sheet
// stop reading as System Settings. A sheet is a heading, a column of labelled fields, and a button bar under a
// hairline.

/// The sheet itself: a heading, the content — which scrolls once it is taller than the sheet may grow — and
/// the button bar. Anything between the content and the bar (`notice`) stays put while the content scrolls,
/// which is where an error has to be to get read.
struct SheetChrome<Content: View, Notice: View, Actions: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @ViewBuilder var notice: Notice
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.scopeTitle)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .padding(EdgeInsets(top: 16, leading: 20, bottom: 12, trailing: 20))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            notice
            HStack(spacing: 8) {
                actions
            }
            .padding(.horizontal, 20)
            .frame(height: 50)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .top) { Rectangle().fill(Surface.stroke).frame(height: 1) }
        }
        .background(Surface.elevated)
    }
}

/// A group of rows that belong together, with the caption that explains them underneath.
struct SheetGroup<Content: View>: View {
    var caption: String?
    @ViewBuilder var content: Content

    init(caption: String? = nil, @ViewBuilder content: () -> Content) {
        self.caption = caption
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
            if let caption, !caption.isEmpty {
                SheetCaption(text: caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Helper text under a field or a group.
struct SheetCaption: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.scopeCaption)
            .foregroundStyle(Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Replaces `LabeledContent` and the label a grouped form gave a `TextField`: the label in a fixed column so
/// the fields under each other share an edge, the control taking the rest.
struct SheetRow<Control: View>: View {
    var label: String
    @ViewBuilder var control: Control

    init(_ label: String, @ViewBuilder control: () -> Control) {
        self.label = label
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.scopeBody)
                .foregroundStyle(Ink.secondary)
                .frame(width: 72, alignment: .leading)
            control
                .font(.scopeBody)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 24)
    }
}

/// A warning with the one action that answers it: a branch already checked out, a task that already exists.
struct SheetNotice<Action: View>: View {
    var text: String
    var systemImage: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(text, systemImage: systemImage)
                .font(.scopeCaption)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Fill.quiet, in: RoundedRectangle(cornerRadius: Radius.md, style: .continuous))
    }
}
