import Foundation
import Testing
@testable import SyntaxCore

@Test func rubyLanguageHighlights() {
    expectLanguageHighlights("sample.rb", aliases: ["sample.RB", "Gemfile", "Rakefile", "sample.gemspec"], source: #"""
    # café
    class Greeter
      def greet(name)
        @message = "hé, #{name}"
        puts @message
        return 42 if true
      end
    end
    """#, expected: [
        (.comment, "# café"),
        (.keyword, "class"),
        (.type, "Greeter"),
        (.keyword, "def"),
        (.function, "greet"),
        (.property, "@message"),
        (.string, "\"hé, #{"),
        (.variable, "name"),
        (.function, "puts"),
        (.number, "42"),
        (.constant, "true"),
    ])
}

@Test func rubyMultilineLiteralsAndSymbolsHighlight() {
    let source = #"""
    module Tasks
      TEXT = <<~MESSAGE
        hello
      MESSAGE
      task :build do
        /done/.match?(TEXT)
      end
    end
    """#
    expectLanguageHighlights("script.rake", source: source, expected: [
        (.type, "Tasks"),
        (.string, ":build"),
        (.string, "/done/"),
        (.function, "match?"),
    ])
    let data = Data(source.utf8)
    let highlighter = SyntaxRegistry.viewer.highlighter(for: URL(fileURLWithPath: "/script.rake"), data: data)
    #expect(highlighter.highlights(in: 0..<data.count).contains {
        $0.kind == .string && String(decoding: data[$0.byteRange], as: UTF8.self).contains("hello")
    })
}
