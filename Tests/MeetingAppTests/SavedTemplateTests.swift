import MeetingCore
import XCTest

@testable import MeetingAssist

@MainActor
final class SavedTemplateTests: XCTestCase {
    private func defaults() -> (String, UserDefaults) {
        let name = "MeetlySavedTemplateTests-" + UUID().uuidString
        return (name, UserDefaults(suiteName: name)!)
    }
    func testNamedTemplatesRemainSelectableAfterRestartAndBuiltinSwitch() {
        let (name, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertTrue(model.saveCustomAnswerTemplate("  Two bullets.  ", name: "Brief custom"))
        let firstID = model.templateSelection
        model.templateSelection = AnswerTemplate.custom.rawValue
        XCTAssertTrue(model.customAnswerTemplate.isEmpty)
        XCTAssertTrue(model.saveCustomAnswerTemplate("An analogy and example.", name: "Analogy"))
        XCTAssertEqual(model.savedAnswerTemplates.count, 2)
        let secondID = model.templateSelection
        model.templateSelection = AnswerTemplate.brief.rawValue
        XCTAssertEqual(model.answerTemplate, .brief)
        model.templateSelection = firstID
        XCTAssertEqual(model.customAnswerTemplate, "Two bullets.")
        let restored = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(restored.templateSelection, firstID)
        XCTAssertEqual(restored.savedAnswerTemplates.map(\.name), ["Brief custom", "Analogy"])
        restored.templateSelection = secondID
        XCTAssertEqual(restored.customAnswerTemplate, "An analogy and example.")
        XCTAssertEqual(restored.answerTemplate, .custom)
    }
    func testEditingSelectedTemplateUpdatesWithoutDuplicatingAndRejectsEmpty() {
        let (name, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertTrue(model.saveCustomAnswerTemplate("Original", name: "One"))
        let id = model.templateSelection
        XCTAssertTrue(model.saveCustomAnswerTemplate("Updated", name: "Renamed"))
        XCTAssertEqual(model.savedAnswerTemplates.count, 1)
        XCTAssertEqual(model.templateSelection, id)
        XCTAssertFalse(model.saveCustomAnswerTemplate("  ", name: "Empty"))
        let restored = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(restored.savedAnswerTemplates.first?.name, "Renamed")
        XCTAssertEqual(restored.customAnswerTemplate, "Updated")
        restored.templateSelection = "missing-id"
        XCTAssertEqual(restored.templateSelection, id)
    }
    func testLegacyCustomFormatMigratesOnceAndPreservesSelection() {
        let (name, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("Use SUMMARY and ANALOGY.", forKey: "customAnswerTemplate")
        defaults.set(AnswerTemplate.custom.rawValue, forKey: "answerTemplate")
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(model.savedAnswerTemplates.count, 1)
        XCTAssertEqual(model.savedAnswerTemplates.first?.name, "My saved template")
        XCTAssertEqual(model.customAnswerTemplate, "Use SUMMARY and ANALOGY.")
        XCTAssertEqual(model.templateSelection, model.savedAnswerTemplates.first?.id)
        let restored = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(restored.savedAnswerTemplates, model.savedAnswerTemplates)
        XCTAssertEqual(restored.templateSelection, model.templateSelection)
    }
    func testCorruptListFallsBackToLegacyAndBlankNameGetsUsableTitle() {
        let (name, defaults) = defaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("broken".utf8), forKey: "savedAnswerTemplates")
        defaults.set("Legacy", forKey: "customAnswerTemplate")
        let model = MeetingModel(appearanceDefaults: defaults)
        XCTAssertEqual(model.savedAnswerTemplates.first?.instructions, "Legacy")
        model.templateSelection = AnswerTemplate.custom.rawValue
        XCTAssertTrue(model.saveCustomAnswerTemplate(String(repeating: "x", count: 2100)))
        XCTAssertEqual(model.savedAnswerTemplates.last?.name, "Custom template 2")
        XCTAssertEqual(model.customAnswerTemplate.count, 2000)
    }
}
