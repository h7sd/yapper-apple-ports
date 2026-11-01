import SwiftUI
import CoreText
import Testing
@testable import YapperNative

@MainActor @Suite struct OriginalVisualResourceTests {
    @Test func `Original Inter resolves a real variable font including the source 650 weight`() throws {
        OriginalYapper.registerFonts()
        let font = OriginalYapper.uiFont(15, numericWeight: 650)
        #expect(font.familyName == "Inter", "Resolved font: \(font.fontName)")
        let variations = try #require(CTFontCopyVariation(font as CTFont) as? [NSNumber: NSNumber])
        #expect(variations[NSNumber(value: 0x77676874)]?.doubleValue == 650)
        #expect(OriginalYapper.resource("Inter-OFL", extension: "txt", subdirectory: "Licenses") != nil)
    }

    @Test func `All exported vector paths parse and retain the source coordinate space`() {
        #expect(OriginalIconCatalog.icons.count == 121)
        for (key, icon) in OriginalIconCatalog.icons {
            #expect(!icon.shapes.isEmpty, "Missing shapes: \(key)")
            for shape in icon.shapes {
                #expect(!shape.path.isEmpty, "Unparsed source path: \(key)")
                let bounds = shape.path.boundingRect
                #expect(bounds.minX >= -1 && bounds.minY >= -1 && bounds.maxX <= 25 && bounds.maxY <= 25, "Broken coordinates: \(key)")
            }
        }
        let home = OriginalIconCatalog.icons["GR"]?.shapes.first?.path.boundingRect
        #expect(home == CGRect(x: 3, y: 2.5, width: 18, height: 19))
        let circle = OriginalIconCatalog.icons["HP"]?.shapes.first?.path.boundingRect
        #expect(circle == CGRect(x: 2, y: 2, width: 20, height: 20))
    }
}
