import Foundation

/// UI-independent core: providers, parsers, aggregators, models.
public enum TokenGlanceCore {
    /// The app version comes from the bundle (set from the VERSION file by scripts/bundle-app.sh).
    public static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
