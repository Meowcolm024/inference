module Inference.LaTeX (compileSource, compileSourceWithImports, parseSourceWithImports, renderSourceLatex, renderLatex, renderLatexExpression) where

import Data.Char (isLetter)
import Data.List (intersperse)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.LaTeX.Templates (LatexTemplates, TemplatePart (..))
import Inference.LaTeX.Unicode (escapeTextChar, joinLatex, renderMathText)
import Inference.Modules (ModuleDiagnostic (..), NotationSourceInput (..), formatModuleDiagnostic, loadNotationScope)
import Inference.Parser (Diagnostic (..), DiagnosticKind (..), formatDiagnostic, parseSourceChunks, parseSourceWithLatexTemplates)
import Inference.Parser.Environment (RawChunk (..), scanEnvironments)
import Inference.Templates (templatesFor)

compileSource :: Text -> Either Diagnostic Text
compileSource input = do
  (document, templates) <- parseSourceWithLatexTemplates input
  renderSourceLatex templates document

compileSourceWithImports :: FilePath -> Text -> IO (Either Text Text)
compileSourceWithImports root input = do
  parsed <- parseSourceWithImports root input
  pure $ do
    (document, templates) <- parsed
    either (Left . ("stdin:" <>) . formatDiagnostic input) Right (renderSourceLatex templates document)

parseSourceWithImports :: FilePath -> Text -> IO (Either Text (SourceDocument, LatexTemplates))
parseSourceWithImports root input = case scanEnvironments input of
  Left diagnostic -> pure (Left (formatModuleDiagnostic (ModuleDiagnostic host diagnostic)))
  Right chunks -> do
    let bodies =
          [ NotationSourceInput "stdin" (sourceLine (spanStart (sectionBeginSpan markers))) body
          | RawNotation markers body <- chunks
          ]
    scope <- loadNotationScope root bodies
    pure $ do
      (notations, templates, locate) <- either (Left . formatModuleDiagnostic . withHost) Right scope
      let report diagnostic =
            "stdin:"
              <> formatDiagnostic input diagnostic {diagnosticRelated = []}
              <> foldMap (formatModuleDiagnostic . withHost . locate . related diagnostic) (diagnosticRelated diagnostic)
      document <- either (Left . report) Right (parseSourceChunks notations chunks)
      pure (document, templatesFor "latex" templates)
  where
    host = NotationSourceInput "stdin" 0 input
    withHost (ModuleDiagnostic origin diagnostic)
      | notationSourceName origin == "stdin" = ModuleDiagnostic host diagnostic
      | otherwise = ModuleDiagnostic origin diagnostic
    related diagnostic span' = diagnostic {diagnosticSpan = span', diagnosticMessage = "Competing notation declared here."}

renderSourceLatex :: LatexTemplates -> SourceDocument -> Either Diagnostic Text
renderSourceLatex templates document = do
  let notations = notationIndex templates (sourceDocumentNotations document)
  Text.concat <$> traverse (renderChunk notations) (sourceDocumentChunks document)
  where
    renderChunk _ (LatexText latex) = Right latex
    renderChunk _ (NotationSource _ body) =
      Right (if Text.null body then "\n" else Text.unlines (map ("% " <>) (Text.lines body)))
    renderChunk notations (RuleSetSource section)
      | emptyBody (sectionBody section) = Right ""
      | otherwise = renderSection notations section

renderLatex :: LatexTemplates -> Document -> Either Diagnostic Text
renderLatex templates document = do
  let notations = notationIndex templates (documentNotations document)
      sections = filter (not . emptyBody . sectionBody) (documentSections document)
  fragments <- traverse (renderSection notations) sections
  pure (Text.intercalate "\n" fragments)

renderLatexExpression :: LatexTemplates -> [Notation] -> Expr -> Either Diagnostic Text
renderLatexExpression templates notations = renderExpr (notationIndex templates notations)

type NotationIndex = Map NotationId (Notation, Maybe (NonEmpty TemplatePart))

notationIndex :: LatexTemplates -> [Notation] -> NotationIndex
notationIndex templates notations =
  Map.fromList [(identity, (notation, Map.lookup identity templates)) | notation <- notations, let identity = notationId notation]

emptyBody :: BlockBody -> Bool
emptyBody (InferenceRules rules) = null rules
emptyBody (BnfGroups groups) = null groups
emptyBody (DisplayExpression expression) = isNothing expression
emptyBody (Equations rows) = all blank rows
  where
    blank (EquationBlank _) = True
    blank (EquationLine _) = False

renderSection :: NotationIndex -> Section -> Either Diagnostic Text
renderSection notations section = do
  content <- case sectionBody section of
    InferenceRules rules -> do
      rendered <- traverse (renderRule notations) rules
      pure (Text.unlines (["\\begin{mathpar}"] ++ intersperse "" rendered ++ ["\\end{mathpar}"]))
    BnfGroups groups -> do
      rendered <- traverse (renderBnfGroup notations) groups
      pure (displayArray "l" (Text.intercalate " \\\\\n{} \\\\\n" rendered))
    DisplayExpression expression ->
      foldMap (\body -> "\\[\n" <> body <> "\n\\]\n") <$> traverse (renderExpr notations) expression
    Equations rows -> do
      rendered <- traverse (renderEquationRow notations) rows
      pure (displayArray "rcll" (Text.intercalate " \\\\\n" rendered))
  pure $ case sectionTitle section of
    Nothing -> content
    Just title ->
      "\\begin{figure}\n"
        <> content
        <> "\\caption{"
        <> Text.concatMap escapePlainTextChar title
        <> "}\n\\end{figure}\n"

displayArray :: Text -> Text -> Text
displayArray columns body =
  "\\[\n\\begin{array}{" <> columns <> "}\n" <> body <> "\n\\end{array}\n\\]\n"

renderBnfGroup :: NotationIndex -> BnfGroup -> Either Diagnostic Text
renderBnfGroup notations group = do
  productions <- traverse renderProduction (bnfProductions group)
  let heading = "\\mbox{" <> Text.concatMap escapePlainTextChar (bnfGroupName group) <> "}"
      layout =
        "\\begin{array}{rcl}\n"
          <> Text.intercalate " \\\\\n" productions
          <> "\n\\end{array}"
  pure (heading <> " \\\\\n" <> layout)
  where
    renderProduction production = do
      categories <- traverse (renderExpr notations) (productionCategories production)
      rows <- traverse renderRow (productionRows production)
      pure $ case rows of
        [] -> ""
        first : continuations ->
          Text.intercalate
            " \\\\\n"
            ((Text.intercalate "," categories <> " & ::= & " <> first) : map (" & & " <>) continuations)
    renderRow row =
      Text.intercalate " \\mid " <$> traverse (renderExpr notations) (productionAlternatives row)

renderEquationRow :: NotationIndex -> EquationRow -> Either Diagnostic Text
renderEquationRow _ (EquationBlank _) = Right "{} & {} & {} & {}"
renderEquationRow notations (EquationLine equation) = do
  left <- renderExpr notations (equationLeft equation)
  right <- renderExpr notations (equationRight equation)
  condition <- case equationGuard equation of
    Nothing -> Right ""
    Just guard -> do
      expression <- renderExpr notations (guardExpression guard)
      pure ((if guardHasIf guard then "\\mbox{if}\\;" else "") <> expression)
  pure (left <> " & = & " <> right <> " & " <> condition)

renderRule :: NotationIndex -> Rule -> Either Diagnostic Text
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

renderExpr :: NotationIndex -> Expr -> Either Diagnostic Text
renderExpr notations expression = case exprNode expression of
  Atom name -> Right (renderMathText name)
  Group inner -> do
    body <- renderExpr notations inner
    pure ("\\left(" <> body <> "\\right)")
  Application function argument -> do
    functionText <- renderExpr notations function
    argumentText <- renderExpr notations argument
    pure (functionText <> "\\," <> argumentText)
  NotationApplication identity lead arguments -> do
    (notation, template) <- case Map.lookup identity notations of
      Just declaration -> Right declaration
      Nothing -> invalid lead "Notation application refers to an unknown declaration."
    let patternParts = NonEmpty.toList (notationPattern notation)
        names = [name | Hole name _ <- patternParts]
    if length names /= length arguments
      then invalid lead "Notation application has the wrong number of arguments."
      else do
        rendered <- traverse (renderExpr notations) arguments
        let bindings = Map.fromList (zip names rendered)
        case template of
          Just parts -> joinLatex <$> traverse (renderPart lead bindings) parts
          Nothing -> do
            pieces <- traverse (renderPatternPart lead bindings) patternParts
            let boundaries = zipWith spacing (Nothing : map Just patternParts) patternParts
            pure (joinLatex (zipWith (<>) boundaries pieces))
  where
    invalid lead message = Left (Diagnostic InvalidNotationApplication lead message [])
    renderPatternPart _ _ (Literal literal) = Right (renderMathText literal)
    renderPatternPart lead bindings (Hole name _) = renderPart lead bindings (Reference name)
    spacing Nothing _ = ""
    spacing (Just previous) next
      | wordLiteral previous || wordLiteral next = "\\,"
      | otherwise = ""
    wordLiteral (Literal literal) = maybe False (isLetter . fst) (Text.uncons literal)
    wordLiteral (Hole _ _) = False
    renderPart _ _ (Fragment fragment) = Right fragment
    renderPart lead bindings (Reference name) =
      case Map.lookup name bindings of
        Just value -> Right value
        Nothing -> invalid lead ("Unknown template hole ‘" <> name <> "’.")

escapePlainTextChar :: Char -> Text
escapePlainTextChar '<' = "\\textless{}"
escapePlainTextChar '>' = "\\textgreater{}"
escapePlainTextChar '|' = "\\textbar{}"
escapePlainTextChar char = escapeTextChar char
