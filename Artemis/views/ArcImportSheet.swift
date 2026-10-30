import SwiftUI

/// "What do you want to bring?" — the move from Arc, itemised.
///
/// Each row is a thing Arc has and Artemis can take, with the real count beside
/// it, so nothing is transferred on a vague promise. Passwords say what they
/// cost before they're chosen.
struct ArcImportSheet: View {
    @Environment(TabManager.self) private var tabManager
    let model: ArcImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch model.phase {
            case .choosing: chooser
            case .working(let step): progress(step)
            case .done(let landed): summary(landed)
            case .failed(let reason): failure(reason)
            }
        }
        .padding(18)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }

    // MARK: - Choosing

    @ViewBuilder
    private var chooser: some View {
        Text("Move in from Arc")
            .font(.system(size: 15, weight: .semibold))
        Text("Arc is only read, so nothing there changes. A login already saved here for the same site and username takes Arc's password.")
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)

        @Bindable var model = model
        VStack(spacing: 2) {
            if model.survey.spaces > 0 {
                row(
                    "square.stack", "Spaces & tabs",
                    "\(model.survey.spaces) spaces · \(model.survey.tabs) tabs · "
                        + "\(model.survey.folders) folders",
                    isOn: $model.selection.spaces)
            }
            if model.survey.favourites > 0 {
                row(
                    "star", "Favourites", "\(model.survey.favourites) pinned to the top",
                    isOn: $model.selection.favourites)
            }
            if model.survey.archived > 0 {
                row(
                    "archivebox", "Archive",
                    "\(model.survey.archived) tabs Arc archived for you",
                    isOn: $model.selection.archive)
            }
            if model.survey.history > 0 {
                row(
                    "clock.arrow.circlepath", "History",
                    "\(formatted(model.survey.history)) pages — the newest 4,000 come across",
                    isOn: $model.selection.history)
            }
            if model.survey.cookies > 0 {
                row(
                    "person.badge.key", "Cookies",
                    "\(formatted(model.survey.cookies)) from \(model.survey.cookieSites) sites — "
                        + "you stay signed in",
                    isOn: $model.selection.cookies)
            }
            if model.survey.logins > 0 {
                row(
                    "key", "Saved passwords",
                    "\(model.survey.logins) logins, into Artemis Passwords in your keychain",
                    isOn: $model.selection.logins)
                if model.selection.logins {
                    row(
                        "doc.text", "Also save a plain-text file",
                        "A CSV in Downloads for another password manager",
                        isOn: $model.selection.loginsFile)
                }
            }
        }

        if model.needsKey {
            note(
                model.selection.logins && model.selection.loginsFile
                    ? "macOS will ask for Arc's key. The password file is plain text — import it, "
                        + "then delete it."
                    : "macOS will ask for Arc's key before "
                        + (!model.selection.logins
                            ? "cookies" : model.selection.cookies ? "cookies and passwords" : "passwords")
                        + " can be read.")
        }

        HStack {
            Button("Not Now") { model.cancel(in: tabManager) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.6))
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button { model.run(into: tabManager) } label: {
                Text("Move Over")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        Capsule().fill(
                            model.canImport
                                ? Color.accentColor.opacity(0.9) : Color.primary.opacity(0.12)))
                    .foregroundStyle(model.canImport ? .white : .primary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canImport)
        }
        .padding(.top, 2)
    }

    private func row(
        _ symbol: String, _ title: String, _ detail: String, isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(isOn.wrappedValue ? Color.accentColor : .primary.opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Image(systemName: symbol)
                            .font(.system(size: 11))
                            .foregroundStyle(.primary.opacity(0.5))
                            .frame(width: 14)
                        Text(title).font(.system(size: 13, weight: .medium))
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 20)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.primary.opacity(isOn.wrappedValue ? 0.06 : 0)))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.5))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 8)
    }

    // MARK: - Running, and after

    @ViewBuilder
    private func progress(_ step: String) -> some View {
        Text("Moving in from Arc")
            .font(.system(size: 15, weight: .semibold))
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(step)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.6))
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func summary(_ landed: [String]) -> some View {
        Text("Moved in")
            .font(.system(size: 15, weight: .semibold))
        VStack(alignment: .leading, spacing: 4) {
            ForEach(landed, id: \.self) { line in
                HStack(spacing: 8) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(line).font(.system(size: 12))
                }
            }
        }
        done("Done")
    }

    @ViewBuilder
    private func failure(_ reason: String) -> some View {
        Text("Partly moved in")
            .font(.system(size: 15, weight: .semibold))
        Text(reason)
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
        done("Close")
    }

    private func done(_ title: String) -> some View {
        HStack {
            Spacer()
            Button { model.cancel(in: tabManager) } label: {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.accentColor.opacity(0.9)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 2)
    }

    private func formatted(_ count: Int) -> String {
        count.formatted(.number.grouping(.automatic))
    }
}
