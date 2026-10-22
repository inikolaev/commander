import SwiftTreeSitter
import TreeSitterRuby

extension SyntaxLanguageDefinition {
    static let ruby = SyntaxLanguageDefinition(
        id: "ruby", fileExtensions: ["rb", "rake", "gemspec"],
        fileNames: ["Gemfile", "Rakefile", "Guardfile", "Capfile", "Vagrantfile", "Brewfile"],
        aliases: ["rb"],
        syntax: { .ruby }
    )
}

extension TreeSitterSyntaxDefinition {
    static let ruby = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_ruby()),
        highlightQuery: #"""
        (identifier) @variable
        [(instance_variable) (class_variable) (global_variable)] @property
        (constant) @constant
        (class name: (constant) @type)
        (module name: (constant) @type)
        (method name: (identifier) @function)
        (singleton_method name: (identifier) @function)
        (call method: (identifier) @function)
        [(string) (bare_string) (subshell) (heredoc_body) (heredoc_beginning)
         (simple_symbol) (delimited_symbol) (hash_key_symbol) (bare_symbol)
         (regex)] @string
        (interpolation (identifier) @variable)
        [(integer) (float)] @number
        [(nil) (true) (false) (self) (file) (line) (encoding)] @constant
        (comment) @comment
        ["alias" "and" "begin" "break" "case" "class" "def" "do" "else"
         "elsif" "end" "ensure" "for" "if" "in" "module" "next" "or"
         "rescue" "retry" "return" "then" "unless" "until" "when"
         "while" "yield" "not" "redo" "undef"] @keyword
        """#,
        captures: codeCaptures
    )
}
