module Inference.Parser
  ( parseSource,
    parseSourceWithLatexTemplates,
    parseSourceWithTemplates,
    parseSourceChunks,
    parseNotationBlock,
    parseNotationBlockWithLatexTemplates,
    parseNotationBlockWithTemplates,
    parseInlineExpression,
    parseRuleSection,
    parseBlockSection,
    parseBlockAttributes,
    formatDiagnostic,
    Diagnostic (..),
    DiagnosticKind (..),
  )
where

import Control.Applicative (many)
import Control.Monad (void)
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Inference.AST
import Inference.LaTeX.Templates (LatexTemplates)
import Inference.Parser.Body (parseBnf, parseEquations)
import Inference.Parser.Environment (RawChunk (..), scanEnvironments)
import Inference.Parser.Expression (parseExpression)
import Inference.Parser.Notation (NotationTable, buildNotationTable, isDeclaration, parseNotation)
import Inference.Parser.Options (parseBlockAttributes)
import Inference.Parser.Source
import Inference.Templates (BackendTemplates, templatesFor)
import Text.Megaparsec (Parsec, bundleErrors, eof, errorOffset, notFollowedBy, runParser, takeWhileP, (<|>))
import Text.Megaparsec.Char (eol)

data RawRule = RawRule SourceSpan (Maybe Text) [Located Text] (Located Text)

-- Delimiter and body spans refer to the original document, including LaTeX.
parseSource :: Text -> Either Diagnostic SourceDocument
parseSource = fmap fst . parseSourceWithTemplates

parseSourceWithLatexTemplates :: Text -> Either Diagnostic (SourceDocument, LatexTemplates)
parseSourceWithLatexTemplates input = fmap (fmap (templatesFor "latex")) (parseSourceWithTemplates input)

parseSourceWithTemplates :: Text -> Either Diagnostic (SourceDocument, BackendTemplates)
parseSourceWithTemplates input = do
  chunks <- scanEnvironments input
  declarations <- traverse (uncurry bodyLines) [(markers, body) | RawNotation markers body <- chunks]
  (notations, templates) <- parseDeclarations (concat declarations)
  document <- parseSourceChunks notations chunks
  pure (document, templates)

bodyLines :: SectionMarkers -> Text -> Either Diagnostic [Located Text]
bodyLines markers = sourceLinesAt (sourceLine (spanStart (sectionBeginSpan markers)) + 1)

parseSourceChunks :: [Notation] -> [RawChunk] -> Either Diagnostic SourceDocument
parseSourceChunks notations chunks =
  SourceDocument notations <$> traverse (parseChunk (buildNotationTable notations)) chunks
  where
    parseChunk _ (RawLatex latex) = Right (LatexText latex)
    parseChunk _ (RawNotation markers body) = Right (NotationSource markers body)
    parseChunk table (RawRuleSet markers options body) = do
      parsed <- bodyLines markers body >>= parseBody table (optionsKind options)
      pure (RuleSetSource (Section (optionsTitle options) (Just markers) parsed))

parseNotationBlock :: Text -> Either Diagnostic [Notation]
parseNotationBlock = fmap fst . parseNotationBlockWithTemplates

parseNotationBlockWithLatexTemplates :: Text -> Either Diagnostic ([Notation], LatexTemplates)
parseNotationBlockWithLatexTemplates input =
  fmap (fmap (templatesFor "latex")) (parseNotationBlockWithTemplates input)

parseNotationBlockWithTemplates :: Text -> Either Diagnostic ([Notation], BackendTemplates)
parseNotationBlockWithTemplates input = sourceLines input >>= parseDeclarations

parseDeclarations :: [Located Text] -> Either Diagnostic ([Notation], BackendTemplates)
parseDeclarations lines' = do
  declarations <- collect 1 lines'
  let templates =
        Map.fromListWith
          Map.union
          [ (backend, Map.singleton (notationId notation) parts)
          | (notation, overrides) <- declarations,
            (backend, parts) <- Map.toList overrides
          ]
  pure (map fst declarations, templates)
  where
    collect _ [] = Right []
    collect nextId (line : rest)
      | Text.null (locatedValue line) = collect nextId rest
      | isTemplateLine line =
          Left (Diagnostic MisplacedTemplate (location line) "Indent backend template clauses immediately below their notation declaration." [])
      | otherwise = do
          let (clauses, remaining) = collectClauses (position line) rest
          declaration <- parseNotation (NotationId nextId) line clauses
          (declaration :) <$> collect (nextId + 1) remaining
    position = spanStart . location
    isTemplateLine line =
      let (name, suffix) = Text.span identifierContinue (locatedValue line)
       in not (Text.null name) && "=>" `Text.isPrefixOf` Text.stripStart suffix
    collectClauses declaration = go (sourceLine declaration + 1)
      where
        go expected (line : rest)
          | let start = position line,
            sourceLine start == expected,
            sourceColumn start > sourceColumn declaration,
            not (Text.null (locatedValue line) || isDeclaration (locatedValue line)) =
              let (clauses, remaining) = go (expected + 1) rest
               in (line : clauses, remaining)
        go _ remaining = ([], remaining)

-- Inline code has a single expression and uses the document's declarations.
parseInlineExpression :: [Notation] -> Text -> Either Diagnostic Expr
parseInlineExpression notations input = do
  let first = SourcePosition 1 1
      (line, remainder) = Text.break (\c -> c == '\n' || c == '\r') input
  if Text.null remainder
    then parseExpression (buildNotationTable notations) (trimLocated (Located (lineSpan first 0 (Text.length line)) line))
    else Left (Diagnostic UnexpectedToken (pointSpan (advance first (Text.length line))) "Expected a single-line inline expression." [])

-- The caller supplies the section boundary and the document-wide notation.
parseRuleSection :: [Notation] -> Maybe Text -> Text -> Either Diagnostic Section
parseRuleSection notations title = parseBlockSection notations (BlockOptions InferenceKind title)

parseBlockSection :: [Notation] -> BlockOptions -> Text -> Either Diagnostic Section
parseBlockSection notations options input = do
  let table = buildNotationTable notations
  body <- sourceLines input >>= parseBody table (optionsKind options)
  pure (Section (optionsTitle options) Nothing body)

parseBody :: NotationTable -> BlockKind -> [Located Text] -> Either Diagnostic BlockBody
parseBody table = \case
  BnfKind -> fmap BnfGroups . parseBnf table
  EquationKind -> fmap Equations . parseEquations table
  InferenceKind -> \lines' -> do
    traverse_ rejectDash lines'
    InferenceRules <$> parseRuleLines table lines'
  where
    rejectDash line = case dashLabel line of
      Just (marker, _) -> Left (Diagnostic ReservedDashLine marker "Dash labels are reserved for BNF groups. Use a Unicode ‘─’ rule bar." [])
      Nothing -> Right ()

parseRuleLines :: NotationTable -> [Located Text] -> Either Diagnostic [Rule]
parseRuleLines table lines' = collectRules lines' >>= traverse (parseRule table)

parseRule :: NotationTable -> RawRule -> Either Diagnostic Rule
parseRule table (RawRule source label premises conclusion) =
  Rule source label <$> traverse (parseExpression table) premises <*> parseExpression table conclusion

sourceLines :: Text -> Either Diagnostic [Located Text]
sourceLines = sourceLinesAt 1

sourceLinesAt :: Int -> Text -> Either Diagnostic [Located Text]
sourceLinesAt firstLine input =
  case runParser (many physicalLine <* eof) "document" input of
    Right lines' -> Right (zipWith trimLine [firstLine ..] lines')
    Left bundle ->
      let offset = errorOffset (NonEmpty.head (bundleErrors bundle))
          (prefix, finalLine) = Text.breakOnEnd "\n" (Text.take offset input)
          start = SourcePosition (Text.count "\n" prefix + firstLine) (Text.length finalLine + 1)
       in Left (Diagnostic InvalidLineEnding (lineSpan start 0 1) "Expected LF or CRLF." [])
  where
    physicalLine :: Parsec Void Text Text
    physicalLine = notFollowedBy eof *> takeWhileP Nothing (\c -> c /= '\n' && c /= '\r') <* (void eol <|> eof)
    trimLine number line =
      let (indent, content) = Text.span isSpace line
          trimmed = Text.dropWhileEnd isSpace content
       in Located (lineSpan (SourcePosition number 1) (Text.length indent) (Text.length trimmed)) trimmed

collectRules :: [Located Text] -> Either Diagnostic [RawRule]
collectRules [] = Right []
collectRules (line : rest)
  | blank line = collectRules rest
  | isDeclaration (locatedValue line) =
      Left (Diagnostic MalformedDeclaration (location line) "Place notation declarations in an ‘inference-notation’ block." [])
  | otherwise = do
      let (ruleLines, remaining) = break blank rest
      rule <- collectRule line ruleLines
      (rule :) <$> collectRules remaining
  where
    blank = Text.null . locatedValue

collectRule :: Located Text -> [Located Text] -> Either Diagnostic RawRule
collectRule first rest =
  case break isSeparator (first : rest) of
    (premises, separator : remaining) -> do
      label <- parseSeparator separator
      case remaining of
        [] -> problem MissingConclusion (pointSpan (spanEnd (location separator))) "Expected a conclusion after the rule separator."
        conclusion : extra
          | isSeparator conclusion ->
              problem MissingConclusion (location conclusion) "Expected a conclusion before the next separator."
          | next : _ <- extra ->
              problem ExpectedBlankLine (location next) "Expected a blank line after the rule conclusion."
          | otherwise ->
              Right (RawRule (cover (location first) (location conclusion)) label premises conclusion)
    (_, []) ->
      let lastLine = foldl' (\_ line -> line) first rest
       in problem MissingSeparator (pointSpan (spanEnd (location lastLine))) "Expected a rule separator."
  where
    isSeparator = Text.isPrefixOf "─" . locatedValue
    problem kind source message = Left (Diagnostic kind source message [])

parseSeparator :: Located Text -> Either Diagnostic (Maybe Text)
parseSeparator (Located source text) =
  let (bar, suffix) = Text.span (== '─') text
   in case Text.uncons suffix of
        Nothing -> Right Nothing
        Just (first, _)
          | isSpace first -> Right (Just (Text.stripStart suffix))
          | otherwise ->
              let span' = lineSpan (spanStart source) (Text.length bar) 1
               in Left (Diagnostic MalformedSeparator span' "Expected whitespace before the rule label." [])
