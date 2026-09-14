import AppKit
import SwiftUI
import ScopeGit
import ScopeTasks

/// Diff of a binary image: the old version (`git show <base>:<path>`) against the working tree file. Both
/// sides are probed independently because the parser folds added and deleted binaries into one `.binary`
/// status — whichever side is missing tells which it was. With both, *Onion skin* stacks them under an
/// opacity slider and *Side by side* puts them next to each other.
struct ImageDiffView: View {
    @Environment(AppModel.self) private var model
    let repo: TaskRepo
    let ref: DeltaFileRef
    let file: DiffFile
    /// The ref the delta was computed against (`Delta.base`); `nil` means no old side can be looked up.
    let base: String?

    @State private var loaded: Loaded?
    @State private var mode: Mode = .onionSkin
    @State private var opacity = 0.5

    private enum Mode: String, CaseIterable, Identifiable {
        case onionSkin = "Onion skin"
        case sideBySide = "Side by side"
        var id: String { rawValue }
    }

    private enum Loaded {
        case images(old: DecodedImage?, new: DecodedImage?)
        case failed(String)
    }

    private struct Key: Hashable {
        let ref: DeltaFileRef
        let oldPath: String?
        let base: String?
    }

    var body: some View {
        VStack(spacing: 0) {
            switch loaded {
            case nil:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(message)
            case .images(nil, nil):
                placeholder("Image not available on either side.")
            case .images(let old?, let new?):
                comparison(old: old, new: new)
            case .images(let old, let new):
                single(old ?? new!, label: new == nil ? "Deleted" : "Added")
            }
        }
        .task(id: Key(ref: ref, oldPath: file.oldPath, base: base)) { await load() }
    }

    // MARK: Layouts

    private func single(_ image: DecodedImage, label: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(label == "Added" ? DeltaCounts.added : DeltaCounts.removed)
                Text(image.caption).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            Divider()
            ImageCanvas(image: image)
        }
    }

    private func comparison(old: DecodedImage, new: DecodedImage) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                if mode == .onionSkin {
                    Text("Before").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    Slider(value: $opacity, in: 0...1).controlSize(.small).frame(maxWidth: 200)
                    Text("After").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                if old.pixelSize != new.pixelSize {
                    Text("\(old.dimensions) → \(new.dimensions)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                }
            }
            .padding(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 14))
            Divider()
            switch mode {
            case .onionSkin:
                OnionSkinCanvas(old: old, new: new, opacity: opacity)
            case .sideBySide:
                HStack(spacing: 0) {
                    labelled("Before", old, tint: DeltaCounts.removed)
                    Divider()
                    labelled("After", new, tint: DeltaCounts.added)
                }
            }
        }
    }

    private func labelled(_ label: String, _ image: DecodedImage, tint: Color) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(label).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                Text(image.caption).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            ImageCanvas(image: image)
        }
        .frame(maxWidth: .infinity)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Spacer()
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
    }

    // MARK: Loading

    private func load() async {
        loaded = nil
        let git = model.env.git
        let sandbox = repo.sandboxURL
        let path = file.path
        let oldPath = file.oldPath ?? file.path
        let base = base
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(Data?, Data?), any Error> in
            do {
                var old: Data?
                if let base {
                    let client = await git.client(for: sandbox)
                    old = try await ImageFiles.blob(oldPath, at: base, in: sandbox, using: client)
                }
                let new = try ImageFiles.read(at: sandbox.appending(path: path, directoryHint: .notDirectory))
                return .success((old, new))
            } catch {
                return .failure(error)
            }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (old, new)):
            loaded = .images(old: old.flatMap(DecodedImage.init), new: new.flatMap(DecodedImage.init))
        case .failure(let error as BaseError):
            if case .fileTooLarge(_, let bytes) = error {
                loaded = .failed("Image is larger than \(ImageFiles.maxBytes / 1_048_576) MiB (\(bytes) bytes) — not shown.")
            } else {
                loaded = .failed(String(describing: error))
            }
        case .failure(let error):
            loaded = .failed(String(describing: error))
        }
    }
}
