import Foundation

public enum SpeechScrollPolicy {
    public static func shouldScroll(
        enabled: Bool, manualPause: Bool, readAloud: Bool, uncertain: Bool,
        passageMinY: Double?, viewportHeight: Double
    ) -> Bool {
        guard enabled, !manualPause, !readAloud, !uncertain, viewportHeight > 0, let y = passageMinY else {
            return false
        }
        return y < -2 || y > viewportHeight * 0.65
    }
}
