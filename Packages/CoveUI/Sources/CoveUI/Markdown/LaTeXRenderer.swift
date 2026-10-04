import Foundation

/// Converts common LaTeX math to readable Unicode text so formulas display
/// offline without a web view (e.g. `\frac{a}{b}` → `(a)/(b)`, `x^2` → `x²`,
/// `\alpha` → `α`). Anything it doesn't recognise is kept verbatim, so the
/// output is never worse than the source.
public enum LaTeXRenderer {
    public static func render(_ latex: String) -> String {
        var s = latex
        // Environments and spacing
        for (pattern, replacement) in [
            ("\\left", ""), ("\\right", ""), ("\\displaystyle", ""), ("\\,", " "), ("\\;", " "), ("\\:", " "),
            ("\\!", ""), ("\\quad", "  "), ("\\qquad", "    "), ("\\\\", "\n"), ("&", " "),
            ("\\begin{aligned}", ""), ("\\end{aligned}", ""), ("\\begin{align}", ""), ("\\end{align}", ""),
            ("\\begin{cases}", "{ "), ("\\end{cases}", ""), ("\\{", "{"), ("\\}", "}"),
        ] {
            s = s.replacingOccurrences(of: pattern, with: replacement)
        }
        s = replaceCommandWithArgs(s, command: "\\frac", arity: 2) { "(\($0[0]))/(\($0[1]))" }
        s = replaceCommandWithArgs(s, command: "\\dfrac", arity: 2) { "(\($0[0]))/(\($0[1]))" }
        s = replaceCommandWithArgs(s, command: "\\sqrt", arity: 1) { "√(\($0[0]))" }
        for wrapper in ["\\text", "\\mathrm", "\\mathbf", "\\mathit", "\\operatorname", "\\textbf", "\\mathcal", "\\boldsymbol"] {
            s = replaceCommandWithArgs(s, command: wrapper, arity: 1) { $0[0] }
        }
        s = replaceCommandWithArgs(s, command: "\\hat", arity: 1) { $0[0] + "\u{0302}" }
        s = replaceCommandWithArgs(s, command: "\\bar", arity: 1) { $0[0] + "\u{0304}" }
        s = replaceCommandWithArgs(s, command: "\\vec", arity: 1) { $0[0] + "\u{20D7}" }

        // Symbols: longest names first so \leq wins over \le.
        for (name, symbol) in symbols.sorted(by: { $0.key.count > $1.key.count }) {
            s = replaceSymbol(s, name: name, with: symbol)
        }
        s = scripts(s, marker: "^", map: superscripts)
        s = scripts(s, marker: "_", map: subscripts)
        // Remaining grouping braces are presentation only.
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Helpers

    /// Reads a `{…}` group (or a single character) starting at `index`.
    private static func readArgument(_ chars: [Character], from index: inout Int) -> String? {
        while index < chars.count, chars[index] == " " { index += 1 }
        guard index < chars.count else { return nil }
        if chars[index] == "{" {
            var depth = 0
            let start = index + 1
            while index < chars.count {
                if chars[index] == "{" { depth += 1 }
                if chars[index] == "}" {
                    depth -= 1
                    if depth == 0 {
                        let arg = String(chars[start..<index])
                        index += 1
                        return arg
                    }
                }
                index += 1
            }
            return nil
        }
        let arg = String(chars[index])
        index += 1
        return arg
    }

    private static func replaceCommandWithArgs(_ input: String, command: String, arity: Int, transform: ([String]) -> String) -> String {
        var chars = Array(input)
        let cmd = Array(command)
        var i = 0
        while i + cmd.count <= chars.count {
            let matches = Array(chars[i..<i + cmd.count]) == cmd
            let boundary = i + cmd.count == chars.count || !chars[i + cmd.count].isLetter
            if matches && boundary {
                var cursor = i + cmd.count
                var args: [String] = []
                for _ in 0..<arity {
                    guard let arg = readArgument(chars, from: &cursor) else { break }
                    // Arguments may themselves contain the command.
                    args.append(replaceCommandWithArgs(arg, command: command, arity: arity, transform: transform))
                }
                if args.count == arity {
                    let replacement = Array(transform(args))
                    chars.replaceSubrange(i..<cursor, with: replacement)
                    i += replacement.count
                    continue
                }
            }
            i += 1
        }
        return String(chars)
    }

    private static func replaceSymbol(_ input: String, name: String, with symbol: String) -> String {
        guard input.contains(name) else { return input }
        var output = ""
        var rest = Substring(input)
        while let range = rest.range(of: name) {
            let after = rest[range.upperBound...].first
            output += rest[..<range.lowerBound]
            if let after, after.isLetter {
                output += rest[range]
            } else {
                output += symbol
            }
            rest = rest[range.upperBound...]
        }
        return output + rest
    }

    private static func scripts(_ input: String, marker: Character, map: [Character: Character]) -> String {
        let chars = Array(input)
        var output = ""
        var i = 0
        while i < chars.count {
            if chars[i] == marker {
                var cursor = i + 1
                if let arg = readArgument(chars, from: &cursor) {
                    let mapped = arg.map { map[$0] }
                    if mapped.allSatisfy({ $0 != nil }) {
                        output += String(mapped.compactMap { $0 })
                    } else {
                        output += String(marker) + (arg.count > 1 ? "(\(arg))" : arg)
                    }
                    i = cursor
                    continue
                }
            }
            output.append(chars[i])
            i += 1
        }
        return output
    }

    static let superscripts: [Character: Character] = [
        "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
        "+": "⁺", "-": "⁻", "=": "⁼", "(": "⁽", ")": "⁾", "n": "ⁿ", "i": "ⁱ", "x": "ˣ", "y": "ʸ", "a": "ᵃ", "b": "ᵇ",
        "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "k": "ᵏ", "m": "ᵐ", "t": "ᵗ", "T": "ᵀ", "*": "*", "′": "′",
    ]

    static let subscripts: [Character: Character] = [
        "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
        "+": "₊", "-": "₋", "=": "₌", "(": "₍", ")": "₎", "a": "ₐ", "e": "ₑ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "n": "ₙ",
        "m": "ₘ", "o": "ₒ", "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "x": "ₓ", "u": "ᵤ", "v": "ᵥ",
    ]

    static let symbols: [String: String] = [
        "\\alpha": "α", "\\beta": "β", "\\gamma": "γ", "\\delta": "δ", "\\epsilon": "ε", "\\varepsilon": "ε", "\\zeta": "ζ",
        "\\eta": "η", "\\theta": "θ", "\\vartheta": "ϑ", "\\iota": "ι", "\\kappa": "κ", "\\lambda": "λ", "\\mu": "μ", "\\nu": "ν",
        "\\xi": "ξ", "\\pi": "π", "\\rho": "ρ", "\\sigma": "σ", "\\tau": "τ", "\\upsilon": "υ", "\\phi": "φ", "\\varphi": "φ",
        "\\chi": "χ", "\\psi": "ψ", "\\omega": "ω", "\\Gamma": "Γ", "\\Delta": "Δ", "\\Theta": "Θ", "\\Lambda": "Λ", "\\Xi": "Ξ",
        "\\Pi": "Π", "\\Sigma": "Σ", "\\Phi": "Φ", "\\Psi": "Ψ", "\\Omega": "Ω",
        "\\sum": "∑", "\\prod": "∏", "\\int": "∫", "\\iint": "∬", "\\oint": "∮", "\\partial": "∂", "\\nabla": "∇", "\\infty": "∞",
        "\\pm": "±", "\\mp": "∓", "\\times": "×", "\\div": "÷", "\\cdot": "·", "\\cdots": "⋯", "\\ldots": "…", "\\dots": "…",
        "\\leq": "≤", "\\le": "≤", "\\geq": "≥", "\\ge": "≥", "\\neq": "≠", "\\ne": "≠", "\\approx": "≈", "\\equiv": "≡",
        "\\sim": "∼", "\\propto": "∝", "\\ll": "≪", "\\gg": "≫",
        "\\in": "∈", "\\notin": "∉", "\\subset": "⊂", "\\subseteq": "⊆", "\\supset": "⊃", "\\cup": "∪", "\\cap": "∩",
        "\\emptyset": "∅", "\\forall": "∀", "\\exists": "∃", "\\neg": "¬", "\\land": "∧", "\\lor": "∨",
        "\\to": "→", "\\rightarrow": "→", "\\leftarrow": "←", "\\Rightarrow": "⇒", "\\Leftarrow": "⇐", "\\iff": "⇔",
        "\\leftrightarrow": "↔", "\\mapsto": "↦", "\\implies": "⇒",
        "\\mathbb{R}": "ℝ", "\\mathbb{N}": "ℕ", "\\mathbb{Z}": "ℤ", "\\mathbb{Q}": "ℚ", "\\mathbb{C}": "ℂ",
        "\\lim": "lim", "\\log": "log", "\\ln": "ln", "\\sin": "sin", "\\cos": "cos", "\\tan": "tan", "\\exp": "exp",
        "\\max": "max", "\\min": "min", "\\det": "det", "\\langle": "⟨", "\\rangle": "⟩", "\\circ": "∘", "\\degree": "°",
        "\\prime": "′", "\\hbar": "ℏ", "\\ell": "ℓ",
    ]
}
