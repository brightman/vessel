import Foundation

@main struct AppReleaseInfoSmoke {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundle = Bundle(url: url)!
        let value = AppReleaseInfo(bundle: bundle)
        precondition(value.versionLabel == "1.2.3（42）")
        precondition(value.builtAt != nil && abs(value.builtAt!.timeIntervalSinceNow) < 120)
        precondition(value.releaseLabel(locale: Locale(identifier: "zh-CN"))!.hasSuffix("UTC"))
        precondition(AppReleaseInfo(bundle: bundle).builtAt == value.builtAt, "Loading metadata never generates a launch timestamp")
        print("Release metadata: packaged version/build, UTC timestamp and stable reads passed")
    }
}
