import SwiftTreeSitter
import TreeSitterJava

extension SyntaxLanguageDefinition {
    static let java = SyntaxLanguageDefinition(
        id: "java", fileExtensions: ["java"],
        syntax: { .java }
    )
}

extension TreeSitterSyntaxDefinition {
    static let java = TreeSitterSyntaxDefinition(
        language: Language(language: tree_sitter_java()),
        highlightQuery: #"""
        (identifier) @variable
        (type_identifier) @type
        [(boolean_type) (integral_type) (floating_point_type) (void_type)] @type
        (class_declaration name: (identifier) @type)
        (interface_declaration name: (identifier) @type)
        (enum_declaration name: (identifier) @type)
        (constructor_declaration name: (identifier) @function)
        (method_declaration name: (identifier) @function)
        (method_invocation name: (identifier) @function)
        [(string_literal) (character_literal)] @string
        [(decimal_integer_literal) (hex_integer_literal) (octal_integer_literal) (binary_integer_literal)
         (decimal_floating_point_literal) (hex_floating_point_literal)] @number
        [(true) (false) (null_literal)] @constant
        [(line_comment) (block_comment)] @comment
        ["abstract" "assert" "break" "case" "catch" "class" "continue" "default" "do"
         "else" "enum" "extends" "final" "finally" "for" "if" "implements" "import"
         "instanceof" "interface" "new" "package" "private" "protected" "public" "return"
         "static" "switch" "synchronized" "throw" "throws" "try" "while" "record" "sealed"] @keyword
        """#,
        captures: codeCaptures
    )
}
