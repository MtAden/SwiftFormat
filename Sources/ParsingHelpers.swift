//
//  ParsingHelpers.swift
//  SwiftFormat
//
//  Created by Nick Lockwood on 08/04/2019.
//  Copyright © 2019 Nick Lockwood. All rights reserved.
//

import Foundation

// MARK: shared helper methods

extension Formatter {
    /// Returns the index of the first token of the line containing the specified index
    public func startOfLine(at index: Int) -> Int {
        var index = index
        while let token = token(at: index - 1) {
            if case .linebreak = token {
                break
            }
            index -= 1
        }
        return index
    }

    /// Returns the index of the linebreak token at the end of the line containing the specified index
    public func endOfLine(at index: Int) -> Int {
        var index = index
        while let token = token(at: index) {
            if case .linebreak = token {
                break
            }
            index += 1
        }
        return index
    }

    /// Returns the space at the start of the line containing the specified index
    func indentForLine(at index: Int) -> String {
        if case let .space(string)? = token(at: startOfLine(at: index)) {
            return string
        }
        return ""
    }

    /// Returns the length (in characters) of the specified token
    func tokenLength(_ token: Token) -> Int {
        switch token {
        case let .space(string), let .stringBody(string), let .commentBody(string):
            let tabWidth = options.useTabs ? options.tabWidth : options.indent.count
            guard tabWidth > 1 else {
                return string.count
            }
            return string.reduce(0) { count, character in
                count + (character == "\t" ? tabWidth : 1)
            }
        case .linebreak:
            return 0
        default:
            return token.string.count
        }
    }

    /// Returns the length (in characters) of the line at the specified index
    func lineLength(at index: Int) -> Int {
        var length = 0
        for token in tokens[startOfLine(at: index) ..< endOfLine(at: index)] {
            length += token.string.count
        }
        return length
    }

    /// Returns the length (in characters) up to (but not including) the specified token index
    func lineLength(upTo index: Int) -> Int {
        var length = 0
        for token in tokens[startOfLine(at: index) ..< index] {
            length += token.string.count
        }
        return length
    }

    /// Returns the length (in characters) of the specified token range
    func lineLength(from start: Int, upTo end: Int) -> Int {
        return tokens[start ..< end].reduce(0) { total, token in
            total + tokenLength(token)
        }
    }

    /// Returns white space made up of indent characters equvialent to the specified width
    func spaceEquivalentToWidth(_ width: Int) -> String {
        if options.useTabs, options.tabWidth > 0 {
            let tabs = width / options.tabWidth
            let remainder = width % options.tabWidth
            return String(repeating: "\t", count: tabs) + String(repeating: " ", count: remainder)
        }
        return String(repeating: " ", count: width)
    }

    /// Returns white space made up of indent characters equvialent to the specified token range
    func spaceEquivalentToTokens(from start: Int, upTo end: Int) -> String {
        if options.useTabs, options.tabWidth > 0 {
            return spaceEquivalentToWidth(lineLength(from: start, upTo: end))
        }
        return tokens[start ..< end].reduce(into: "") { result, token in
            if case let .space(string) = token {
                result += string
            } else {
                result += String(repeating: " ", count: tokenLength(token))
            }
        }
    }

    func specifiersForType(at index: Int, contains: (Int, Token) -> Bool) -> Bool {
        let allSpecifiers = _FormatRules.allSpecifiers
        var index = index
        while var prevIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, before: index) {
            switch tokens[prevIndex] {
            case let token where contains(prevIndex, token):
                return true
            case .endOfScope(")"):
                guard let startIndex = self.index(of: .startOfScope("("), before: prevIndex),
                    let index = self.index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex, if: {
                        $0.isAttribute || _FormatRules.aclSpecifiers.contains($0.string)
                    }) else {
                    return false
                }
                prevIndex = index
            case let .keyword(name), let .identifier(name):
                if !allSpecifiers.contains(name), !name.hasPrefix("@") {
                    return false
                }
            default:
                return false
            }
            index = prevIndex
        }
        return false
    }

    func specifiersForType(at index: Int, contains: String) -> Bool {
        return specifiersForType(at: index, contains: { $1.string == contains })
    }

    // first index of specifier list
    func startOfSpecifiers(at index: Int) -> Int {
        var startIndex = index
        _ = specifiersForType(at: index, contains: { i, _ in
            startIndex = i
            return false
        })
        return startIndex
    }

    // get type of declaratiob starting at index of declaration keyword
    func declarationType(at index: Int) -> String? {
        guard case let .keyword(keyword)? = token(at: index) else {
            return nil
        }
        switch keyword {
        case "let", "var", "func", "init", "subscript", "struct", "enum":
            return keyword
        case "class":
            if let nextIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, after: index, if: {
                $0.isKeyword
            }) {
                return declarationType(at: nextIndex)
            }
            return keyword
        default:
            return nil
        }
    }

    // gather declared name(s), starting at index of declaration keyword
    func namesInDeclaration(at index: Int) -> Set<String>? {
        guard case let .keyword(keyword)? = token(at: index) else {
            return nil
        }
        switch keyword {
        case "let", "var":
            var index = index + 1
            var names = Set<String>()
            processDeclaredVariables(at: &index, names: &names)
            return names
        case "func", "class", "struct", "enum":
            guard let name = next(.identifier, after: index) else {
                return nil
            }
            return [name.string]
        default:
            return nil
        }
    }

    // gather declared variable names, starting at index after let/var keyword
    func processDeclaredVariables(at index: inout Int, names: inout Set<String>) {
        while let token = self.token(at: index) {
            switch token {
            case .identifier where
                last(.nonSpaceOrCommentOrLinebreak, before: index)?.isOperator(".") == false:
                let name = token.unescaped()
                if name != "_" {
                    names.insert(name)
                }
                inner: while let nextIndex = self.index(of: .nonSpaceOrCommentOrLinebreak, after: index) {
                    switch tokens[nextIndex] {
                    case .keyword("as"), .keyword("is"), .keyword("try"):
                        break
                    case .startOfScope("<"), .startOfScope("["), .startOfScope("("),
                         .startOfScope where token.isStringDelimiter:
                        guard let endIndex = endOfScope(at: nextIndex) else {
                            return // error
                        }
                        index = endIndex
                        continue
                    case .keyword, .startOfScope("{"), .endOfScope("}"), .startOfScope(":"):
                        return
                    case .delimiter(","):
                        index = nextIndex
                        break inner
                    default:
                        break
                    }
                    index = nextIndex
                }
            default:
                break
            }
            index += 1
        }
    }

    func isStartOfClosure(at i: Int, in _: Token? = nil) -> Bool {
        assert(tokens[i] == .startOfScope("{"))

        if isConditionalStatement(at: i) {
            return false
        }
        guard var prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i) else {
            return true
        }
        switch tokens[prevIndex] {
        case .startOfScope("("), .startOfScope("["), .startOfScope("{"),
             .operator(_, .infix), .operator(_, .prefix), .delimiter,
             .keyword("return"), .keyword("in"), .keyword("where"):
            return true
        case .operator(_, .none),
             .keyword("deinit"), .keyword("catch"), .keyword("else"),
             .keyword("repeat"), .keyword("throws"), .keyword("rethrows"):
            return false
        case .endOfScope(")"):
            guard let startOfScope = index(of: .startOfScope("("), before: prevIndex),
                let prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startOfScope) else {
                return true
            }
            switch tokens[prev] {
            case .identifier:
                prevIndex = prev
            case .operator("?", .postfix), .operator("!", .postfix):
                guard token(at: prev - 1)?.isIdentifier == true else {
                    return true
                }
                prevIndex = prev - 1
            default:
                return true
            }
            fallthrough
        case .identifier:
            if let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i),
                isAccessorKeyword(at: nextIndex) || isAccessorKeyword(at: prevIndex) {
                return false
            }
            guard let prevKeywordIndex = indexOfLastSignificantKeyword(at: prevIndex) else {
                return true
            }
            switch tokens[prevKeywordIndex].string {
            case "var":
                if lastIndex(of: .operator("=", .infix), in: prevKeywordIndex + 1 ..< i) != nil {
                    return true
                }
                var index = prevKeywordIndex
                while let nextIndex = self.index(of: .nonSpaceOrComment, after: index),
                    nextIndex < i {
                    switch tokens[nextIndex] {
                    case .operator("=", .infix):
                        return true
                    case .linebreak:
                        guard let nextIndex =
                            self.index(of: .nonSpaceOrCommentOrLinebreak, after: nextIndex) else {
                            return true
                        }
                        if isEndOfStatement(at: index), isStartOfStatement(at: nextIndex) {
                            return true
                        }
                        index = nextIndex
                    default:
                        index = nextIndex
                    }
                }
                return false
            case "func", "class", "protocol", "enum":
                return false
            default:
                return true
            }
        case .keyword:
            return false
        case .operator("?", .postfix), .operator("!", .postfix),
             .endOfScope("]"), .endOfScope(">"):
            return false
        default:
            return true
        }
    }

    func isInClosureArguments(at i: Int) -> Bool {
        var i = i
        while let token = self.token(at: i) {
            switch token {
            case .keyword("in"):
                guard let scopeIndex = index(of: .startOfScope, before: i) else {
                    return false
                }
                return isStartOfClosure(at: scopeIndex)
            case .startOfScope("("), .startOfScope("["), .startOfScope("<"),
                 .endOfScope(")"), .endOfScope("]"), .endOfScope(">"):
                break
            case .keyword, .startOfScope, .endOfScope:
                return false
            default:
                break
            }
            i += 1
        }
        return false
    }

    func isAccessorKeyword(at i: Int, checkKeyword: Bool = true) -> Bool {
        guard !checkKeyword ||
            ["get", "set", "willSet", "didSet"].contains(token(at: i)?.string ?? ""),
            var prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i) else {
            return false
        }
        if tokens[prevIndex] == .endOfScope("}"),
            let startIndex = index(of: .startOfScope("{"), before: prevIndex),
            let prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex) {
            prevIndex = prev
            if tokens[prevIndex] == .endOfScope(")"),
                let startIndex = index(of: .startOfScope("("), before: prevIndex),
                let prev = index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex) {
                prevIndex = prev
            }
            return isAccessorKeyword(at: prevIndex)
        } else if tokens[prevIndex] == .startOfScope("{") {
            switch lastSignificantKeyword(at: prevIndex) {
            case "var"?, "subscript"?:
                return true
            default:
                return false
            }
        }
        return false
    }

    func isConditionalStatement(at i: Int) -> Bool {
        guard let index = indexOfLastSignificantKeyword(at: i) else {
            return false
        }
        switch tokens[index].string {
        case "let", "var":
            switch last(.nonSpaceOrCommentOrLinebreak, before: index) {
            case .delimiter(",")?:
                return true
            case let .keyword(name)?:
                return ["if", "guard", "while", "for", "case", "catch"].contains(name)
            default:
                return false
            }
        case "if", "guard", "while", "for", "case", "where", "switch":
            return true
        default:
            return false
        }
    }

    func lastSignificantKeyword(at i: Int) -> String? {
        return indexOfLastSignificantKeyword(at: i).map { tokens[$0].string }
    }

    func indexOfLastSignificantKeyword(at i: Int) -> Int? {
        guard let index = tokens[i].isKeyword ? i : index(of: .keyword, before: i),
            lastIndex(of: .endOfScope("}"), in: index ..< i) == nil else {
            return nil
        }
        switch tokens[index].string {
        case let name where name.hasPrefix("#") || name.hasPrefix("@"):
            fallthrough
        case "in", "as", "is", "try":
            return indexOfLastSignificantKeyword(at: index - 1)
        default:
            return index
        }
    }

    func isEndOfStatement(at i: Int, in scope: Token? = nil) -> Bool {
        guard let token = self.token(at: i) else { return true }
        switch token {
        case .endOfScope("case"), .endOfScope("default"):
            return false
        case let .keyword(string):
            // TODO: handle context-specific keywords
            // associativity, convenience, dynamic, didSet, final, get, infix, indirect,
            // lazy, left, mutating, none, nonmutating, open, optional, override, postfix,
            // precedence, prefix, Protocol, required, right, set, Type, unowned, weak, willSet
            switch string {
            case "let", "func", "var", "if", "as", "import", "try", "guard", "case",
                 "for", "init", "switch", "throw", "where", "subscript", "is",
                 "while", "associatedtype", "inout":
                return false
            case "in":
                return lastSignificantKeyword(at: i) != "for"
            case "return":
                guard let nextToken = next(.nonSpaceOrCommentOrLinebreak, after: i) else {
                    return true
                }
                switch nextToken {
                case .keyword, .endOfScope("case"), .endOfScope("default"):
                    return true
                default:
                    return false
                }
            default:
                return true
            }
        case .delimiter(","):
            guard let scope = scope ?? currentScope(at: i) else {
                return false
            }
            // For arrays or argument lists, we already indent
            return ["<", "[", "(", "case", "default"].contains(scope.string)
        case .delimiter(":"):
            guard let scope = scope ?? currentScope(at: i) else {
                return false
            }
            // For arrays or argument lists, we already indent
            return ["case", "default", "("].contains(scope.string)
        case .operator(_, .infix), .operator(_, .prefix):
            return false
        case .operator("?", .postfix), .operator("!", .postfix):
            switch self.token(at: i - 1) {
            case .keyword("as")?, .keyword("try")?:
                return false
            default:
                return true
            }
        default:
            return true
        }
    }

    func isStartOfStatement(at i: Int, in scope: Token? = nil) -> Bool {
        guard let token = self.token(at: i) else { return true }
        switch token {
        case let .keyword(string) where [ // TODO: handle "in"
            "where", "dynamicType", "rethrows", "throws",
        ].contains(string):
            return false
        case .keyword("as"), .keyword("in"):
            // For case statements, we already indent
            return currentScope(at: i)?.string == "case"
        case .keyword("is"):
            guard let lastToken = last(.nonSpaceOrCommentOrLinebreak, before: i) else {
                return false
            }
            return [.endOfScope("case"), .keyword("case"), .delimiter(",")].contains(lastToken)
        case .delimiter(","):
            guard let scope = scope ?? currentScope(at: i) else {
                return false
            }
            // For arrays, dictionaries, cases, or argument lists, we already indent
            return ["<", "[", "(", "case"].contains(scope.string)
        case .delimiter, .operator(_, .infix), .operator(_, .postfix):
            return false
        default:
            return true
        }
    }

    func isSubscriptOrFunctionCall(at i: Int) -> Bool {
        guard case let .startOfScope(string)? = token(at: i), ["[", "("].contains(string),
            let prevToken = last(.nonSpaceOrComment, before: i) else {
            return false
        }
        switch prevToken {
        case .identifier, .operator(_, .postfix),
             .endOfScope("]"), .endOfScope(")"), .endOfScope("}"),
             .endOfScope where prevToken.isStringDelimiter:
            return true
        default:
            return false
        }
    }

    // Detect if currently inside a String literal
    func isStringLiteral(at index: Int) -> Bool {
        for token in tokens[..<index].reversed() {
            switch token {
            case .stringBody:
                return true
            case .endOfScope where token.isStringDelimiter, .linebreak:
                return false
            default:
                continue
            }
        }
        return false
    }

    // Detect if code is inside a ViewBuilder
    func isInViewBuilder(at i: Int) -> Bool {
        var i = i
        while let startIndex = index(of: .startOfScope("{"), before: i) {
            guard let prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: startIndex) else {
                return false
            }
            if tokens[prevIndex] == .identifier("View"),
                let prevToken = last(.nonSpaceOrCommentOrLinebreak, before: prevIndex),
                [.delimiter(":"), .identifier("some")].contains(prevToken) {
                return true
            }
            i = prevIndex
        }
        return false
    }

    // Detect if identifier requires backtick escaping
    func backticksRequired(at i: Int, ignoreLeadingDot: Bool = false) -> Bool {
        guard let token = token(at: i), token.isIdentifier else {
            return false
        }
        let unescaped = token.unescaped()
        if !unescaped.isSwiftKeyword {
            switch unescaped {
            case "super", "self", "nil", "true", "false":
                if options.swiftVersion < "4" {
                    return true
                }
            case "Self", "Any":
                if let prevToken = last(.nonSpaceOrCommentOrLinebreak, before: i),
                    [.delimiter(":"), .operator("->", .infix)].contains(prevToken) {
                    // TODO: check for other cases where it's safe to use unescaped
                    return false
                }
            case "Type":
                if currentScope(at: i) == .startOfScope("{") {
                    // TODO: check it's actually inside a type declaration, otherwise backticks aren't needed
                    return true
                }
                if last(.nonSpaceOrCommentOrLinebreak, before: i)?.isOperator(".") == true {
                    return true
                }
                return false
            case "get", "set", "willSet", "didSet":
                return isAccessorKeyword(at: i, checkKeyword: false)
            default:
                return false
            }
        }
        if let prevIndex = index(of: .nonSpaceOrCommentOrLinebreak, before: i),
            tokens[prevIndex].isOperator(".") {
            if options.swiftVersion >= "5" || self.token(at: prevIndex - 1)?.isOperator("\\") != true {
                return ignoreLeadingDot
            }
            return true
        }
        guard !["let", "var"].contains(unescaped) else {
            return true
        }
        return !isArgumentPosition(at: i)
    }

    // Is token at argument position
    func isArgumentPosition(at i: Int) -> Bool {
        assert(tokens[i].isIdentifierOrKeyword)
        guard let nextIndex = index(of: .nonSpaceOrCommentOrLinebreak, after: i) else {
            return false
        }
        let nextToken = tokens[nextIndex]
        if currentScope(at: i) == .startOfScope("("),
            nextToken == .delimiter(":") || (nextToken.isIdentifier &&
                next(.nonSpaceOrCommentOrLinebreak, after: nextIndex) == .delimiter(":")) {
            return true
        }
        return false
    }

    func isCommentedCode(at i: Int) -> Bool {
        if token(at: i) == .startOfScope("//"), currentScope(at: i) != nil,
            token(at: i - 1)?.isSpace != true {
            switch token(at: i + 1) {
            case nil, .linebreak?:
                return true
            case let .space(space)? where space.hasPrefix(options.indent):
                return true
            default:
                break
            }
        }
        return false
    }
}

extension _FormatRules {
    // Short date formater. Used by fileHeader rule
    static var shortDateFormatter: (Date) -> String = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return { formatter.string(from: $0) }
    }()

    // Year formater. Used by fileHeader rule
    static var yearFormatter: (Date) -> String = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return { formatter.string(from: $0) }
    }()

    // Current year. Used by fileHeader rule
    static var currentYear: String = {
        yearFormatter(Date())
    }()

    // Shared import rules implementation
    typealias ImportRange = (String, Range<Int>)
    static func parseImports(_ formatter: Formatter) -> [[ImportRange]] {
        var importStack = [[ImportRange]]()
        var importRanges = [ImportRange]()
        formatter.forEach(.keyword("import")) { i, _ in

            func pushStack() {
                importStack.append(importRanges)
                importRanges.removeAll()
            }

            // Get start of line
            var startIndex = formatter.index(of: .linebreak, before: i) ?? 0
            // Check for attributes
            var previousKeywordIndex = formatter.index(of: .keyword, before: i)
            while let previousIndex = previousKeywordIndex {
                var nextStart: Int? // workaround for Swift Linux bug
                if formatter.tokens[previousIndex].isAttribute {
                    if previousIndex < startIndex {
                        nextStart = formatter.index(of: .linebreak, before: previousIndex) ?? 0
                    }
                    previousKeywordIndex = formatter.index(of: .keyword, before: previousIndex)
                    startIndex = nextStart ?? startIndex
                } else if previousIndex >= startIndex {
                    // Can't handle another keyword on same line as import
                    return
                } else {
                    break
                }
            }
            // Gather comments
            var prevIndex = formatter.index(of: .linebreak, before: startIndex) ?? 0
            while startIndex > 0,
                formatter.next(.nonSpace, after: prevIndex)?.isComment == true,
                formatter.next(.nonSpaceOrComment, after: prevIndex)?.isLinebreak == true {
                startIndex = prevIndex
                prevIndex = formatter.index(of: .linebreak, before: startIndex) ?? 0
            }
            // Get end of line
            let endIndex = formatter.index(of: .linebreak, after: i) ?? formatter.tokens.count
            // Get name
            if let firstPartIndex = formatter.index(of: .identifier, after: i) {
                var name = formatter.tokens[firstPartIndex].string
                var partIndex = firstPartIndex
                loop: while let nextPartIndex = formatter.index(of: .nonSpaceOrCommentOrLinebreak, after: partIndex) {
                    switch formatter.tokens[nextPartIndex] {
                    case .operator(".", .infix):
                        name += "."
                    case let .identifier(string):
                        name += string
                    default:
                        break loop
                    }
                    partIndex = nextPartIndex
                }
                importRanges.append((name, startIndex ..< endIndex as Range))
            } else {
                // Error
                pushStack()
                return
            }
            if formatter.next(.spaceOrCommentOrLinebreak, after: endIndex)?.isLinebreak == true {
                // Blank line after - consider this the end of a block
                pushStack()
                return
            }
            if var nextTokenIndex = formatter.index(of: .nonSpaceOrCommentOrLinebreak, after: endIndex) {
                while formatter.tokens[nextTokenIndex].isAttribute {
                    guard let nextIndex = formatter.index(of: .nonSpaceOrLinebreak, after: nextTokenIndex) else {
                        // End of imports
                        pushStack()
                        return
                    }
                    nextTokenIndex = nextIndex
                }
                if formatter.tokens[nextTokenIndex] != .keyword("import") {
                    // End of imports
                    pushStack()
                    return
                }
            }
        }
        // End of imports
        importStack.append(importRanges)
        return importStack
    }

    // All specifiers
    static let allSpecifiers = Set(specifierOrder)

    // ACL specifiers
    static let aclSpecifiers = ["private", "fileprivate", "internal", "public"]

    // Swift specifier keywords, in preferred order
    static let specifierOrder = [
        "private", "fileprivate", "internal", "public", "open",
        "private(set)", "fileprivate(set)", "internal(set)", "public(set)",
        "final", "dynamic", // Can't be both
        "optional", "required",
        "convenience",
        "override",
        "indirect",
        "lazy",
        "weak", "unowned",
        "static", "class",
        "mutating", "nonmutating",
        "prefix", "postfix",
    ]
}
