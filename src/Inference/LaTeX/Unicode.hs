module Inference.LaTeX.Unicode (renderMathText, joinLatex, escapeTextChar) where

import Data.Char (isAsciiLower, isAsciiUpper)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text

-- Adjacent chunks must not extend the name of a LaTeX control word.
joinLatex :: (Foldable parts) => parts Text -> Text
joinLatex = foldr append ""
  where
    append piece suffix
      | Just (first, _) <- Text.uncons suffix,
        asciiLetter first,
        Just (_, lastChar) <- Text.unsnoc piece,
        asciiLetter lastChar,
        let beforeWord = Text.dropWhileEnd asciiLetter piece,
        odd (Text.length (Text.takeWhileEnd (== '\\') beforeWord)) =
          piece <> " " <> suffix
      | otherwise = piece <> suffix
    asciiLetter char = isAsciiLower char || isAsciiUpper char

data Script = Subscript Char | Superscript Char

renderMathText :: Text -> Text
renderMathText = joinLatex . chunks . Text.unpack
  where
    chunks [] = []
    chunks (first : rest) =
      let (scripts, remaining) = readScripts rest
          base = case Map.lookup first scriptCharacters of
            Just script -> "{}" <> renderScripts (script : scripts)
            Nothing -> mathChar first <> renderScripts scripts
       in base : chunks remaining
    readScripts (char : rest)
      | Just script <- Map.lookup char scriptCharacters =
          let (scripts, remaining) = readScripts rest
           in (script : scripts, remaining)
    readScripts remaining = ([], remaining)
    renderScripts scripts =
      suffix "_" [char | Subscript char <- scripts] <> suffix "^" [char | Superscript char <- scripts]
    suffix _ [] = ""
    suffix marker chars = marker <> "{" <> joinLatex (map mathChar chars) <> "}"

scriptCharacters :: Map Char Script
scriptCharacters =
  Map.fromList
    ( sub "₀₁₂₃₄₅₆₇₈₉₊₋₌₍₎" "0123456789+-=()"
        ++ sub "ₐₑₕᵢⱼₖₗₘₙₒₚᵣₛₜᵤᵥₓ" "aehijklmnoprstuvx"
        ++ sub "ᵦᵧᵨᵩᵪ" "βγρφχ"
        ++ sup "⁰¹²³⁴⁵⁶⁷⁸⁹⁺⁻⁼⁽⁾" "0123456789+-=()"
        ++ sup "ᵃᵇᶜᵈᵉᶠᵍʰⁱʲᵏˡᵐⁿᵒᵖʳˢᵗᵘᵛʷˣʸᶻ" "abcdefghijklmnoprstuvwxyz"
        ++ sup "ᴬᴮᴰᴱᴳᴴᴵᴶᴷᴸᴹᴺᴼᴾᴿᵀᵁⱽᵂ" "ABDEGHIJKLMNOPRTUVW"
        ++ sup "ᵅᵝᵞᵟᵋᶿᶥᵠᵡᶲ" "αβγδεθιφχϕ"
    )
  where
    sub chars base = zip chars (map Subscript base)
    sup chars base = zip chars (map Superscript base)

mathChar :: Char -> Text
mathChar char = Map.findWithDefault (escapeTextChar char) char mathCharacters

mathCharacters :: Map Char Text
mathCharacters =
  Map.fromList
    ( commands "αβγδεζηθ" "alpha beta gamma delta varepsilon zeta eta theta"
        ++ commands "ικλμνξ" "iota kappa lambda mu nu xi"
        ++ commands "πρστυφχψω" "pi rho sigma tau upsilon phi chi psi omega"
        ++ commands "ΓΔΘΛΞΠΣΥΦΨΩ" "Gamma Delta Theta Lambda Xi Pi Sigma Upsilon Phi Psi Omega"
        ++ commands "ϵϑϕϖϱς" "epsilon vartheta varphi varpi varrho varsigma"
        ++ zip "ΑΒΕΖΗΙΚΜΝΟΡΤΧο−" (map Text.singleton "ABEZHIKMNOPTXo-")
        ++ commands "∅∞∀∃∈∉∧∨¬⊤⊥" "emptyset infty forall exists in notin land lor neg top bot"
        ++ commands "×±≤≥≠≡≈∼" "times pm leq geq neq equiv approx sim"
        ++ commands "→←↔⇒⇐⇔↦" "to leftarrow leftrightarrow Rightarrow Leftarrow Leftrightarrow mapsto"
        ++ commands "∪∩⊆⊂⊇⊃∑∏∫" "cup cap subseteq subset supseteq supset sum prod int"
        ++ commands "⊢⊣⊨" "vdash dashv models"
        ++ commands "↪↑↓↕⟶⟹" "hookrightarrow uparrow downarrow updownarrow longrightarrow Longrightarrow"
        ++ commands "⟨⟩⌈⌉⌊⌋·⋅∓≃≅∝∂∇∖" "langle rangle lceil rceil lfloor rfloor cdot cdot mp simeq cong propto partial nabla setminus"
    )
  where
    commands chars names = zip chars (map (Text.cons '\\') (Text.words names))

escapeTextChar :: Char -> Text
escapeTextChar = \case
  '\\' -> "\\textbackslash{}"
  '~' -> "\\textasciitilde{}"
  '^' -> "\\textasciicircum{}"
  char | char `elem` ("#$%&_{}" :: String) -> Text.cons '\\' (Text.singleton char)
  char -> Text.singleton char
