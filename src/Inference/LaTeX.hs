module Inference.LaTeX (compileSource, renderLatex) where

import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List (intersperse)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser (Diagnostic (..), DiagnosticKind (..), parseSource)

compileSource :: Text -> Either Diagnostic Text
compileSource input = do
  document <- parseSource input
  let notations = notationIndex (sourceDocumentNotations document)
  Text.concat <$> traverse (renderChunk notations) (sourceDocumentChunks document)
  where
    renderChunk _ (LatexText latex) = Right latex
    renderChunk _ (NotationSource _ body) =
      Right (if Text.null body then "\n" else Text.unlines (map ("% " <>) (Text.lines body)))
    renderChunk notations (RuleSetSource section)
      | null (sectionRules section) = Right ""
      | otherwise = renderSection notations section

renderLatex :: Document -> Either Diagnostic Text
renderLatex document = do
  let notations = notationIndex (documentNotations document)
      sections = filter (not . null . sectionRules) (documentSections document)
  fragments <- traverse (renderSection notations) sections
  pure (Text.intercalate "\n" fragments)

notationIndex :: [Notation] -> Map NotationId Notation
notationIndex notations = Map.fromList [(notationId notation, notation) | notation <- notations]

renderSection :: Map NotationId Notation -> Section -> Either Diagnostic Text
renderSection notations section = do
  rules <- traverse (renderRule notations) (sectionRules section)
  let mathpar = Text.unlines (["\\begin{mathpar}"] ++ intersperse "" rules ++ ["\\end{mathpar}"])
  pure $ case sectionTitle section of
    Nothing -> mathpar
    Just title ->
      "\\begin{figure}\n"
        <> mathpar
        <> "\\caption{"
        <> Text.concatMap escapePlainTextChar title
        <> "}\n\\end{figure}\n"

renderRule :: Map NotationId Notation -> Rule -> Either Diagnostic Text
renderRule notations rule = do
  premises <- traverse (renderExpr notations) (rulePremises rule)
  conclusion <- renderExpr notations (ruleConclusion rule)
  let command = case ruleLabel rule of
        Nothing -> "\\inferrule"
        Just label -> "\\inferrule*[right={" <> Text.concatMap escapePlainTextChar label <> "}]"
      premiseText = case premises of
        [] -> " " -- mathpartir omits the rule bar for an empty argument.
        _ -> Text.intercalate " \\\\\n   " premises
  pure (command <> "\n  {" <> premiseText <> "}\n  {" <> conclusion <> "}")

renderExpr :: Map NotationId Notation -> Expr -> Either Diagnostic Text
renderExpr notations expression = case exprNode expression of
  Atom name -> Right (renderAtom name)
  Group inner -> do
    body <- renderExpr notations inner
    pure ("\\left(" <> body <> "\\right)")
  Application function argument -> do
    functionText <- renderExpr notations function
    argumentText <- renderExpr notations argument
    pure (functionText <> "\\," <> argumentText)
  NotationApplication identity lead arguments -> do
    notation <- case Map.lookup identity notations of
      Just declaration -> Right declaration
      Nothing -> invalid lead "Notation application refers to an unknown declaration."
    let names = [name | Hole name _ <- NonEmpty.toList (notationPattern notation)]
    if length names /= length arguments
      then invalid lead "Notation application has the wrong number of arguments."
      else do
        rendered <- traverse (renderExpr notations) arguments
        let bindings = Map.fromList (zip names rendered)
        joinLatex <$> traverse (renderPart lead bindings) (notationTemplate notation)
  where
    invalid lead message = Left (Diagnostic InvalidNotationApplication lead message [])
    renderPart _ _ (Fragment fragment) = Right fragment
    renderPart lead bindings (Reference name) =
      case Map.lookup name bindings of
        Just value -> Right value
        Nothing -> invalid lead ("Unknown template hole ‘" <> name <> "’.")

-- A substituted argument must not extend the name of a LaTeX control word.
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

renderAtom :: Text -> Text
renderAtom = joinLatex . chunks . Text.unpack
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
    )
  where
    commands chars names = zip chars (map (Text.cons '\\') (Text.words names))

escapePlainTextChar :: Char -> Text
escapePlainTextChar '<' = "\\textless{}"
escapePlainTextChar '>' = "\\textgreater{}"
escapePlainTextChar '|' = "\\textbar{}"
escapePlainTextChar char = escapeTextChar char

escapeTextChar :: Char -> Text
escapeTextChar = \case
  '\\' -> "\\textbackslash{}"
  '~' -> "\\textasciitilde{}"
  '^' -> "\\textasciicircum{}"
  char | char `elem` ("#$%&_{}" :: String) -> Text.cons '\\' (Text.singleton char)
  char -> Text.singleton char
