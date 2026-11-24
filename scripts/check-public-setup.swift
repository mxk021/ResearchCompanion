import Foundation

/// Validate the production setup rules against the release bundle and the
/// isolated profile created by check-first-install.mjs.
@main
private enum ResearchPublicSetupCheck {
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5,
              let bundle = Bundle(url: URL(fileURLWithPath: arguments[2])),
              let archive = ResearchSetup.packagedArchive(in: bundle),
              archive.lastPathComponent == arguments[3] else {
            throw Failure("The public setup view cannot find the packaged bridge.")
        }
        let setup = ResearchSetup(desktop: nil, home: URL(fileURLWithPath: arguments[1]), archive: archive)
        guard String(describing: setup.bridgeState()) == arguments[4] else {
            throw Failure("Expected \(arguments[4]), got \(setup.bridgeState()).")
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }
}
