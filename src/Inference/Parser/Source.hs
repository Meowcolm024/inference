module Inference.Parser.Source
  ( Diagnostic (..),
    DiagnosticKind (..),
    formatDiagnostic,
    Located (..),
    advance,
    pointSpan,
    cover,
    lineSpan,
    identifierStart,
    identifierContinue,
    symbolic,
    sliceLocated,
    trimLocated,
    dashLabel,
  )
where

import Data.Char (GeneralCategory (DecimalNumber), generalCategory, isLetter, isMark, isPunctuation, isSpace, isSymbol)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST

data DiagnosticKind
  = InvalidLineEnding
  | MalformedSourceDelimiter
  | NestedSourceEnvironment
  | UnexpectedSourceEnd
  | MismatchedSourceEnd
  | UnclosedSourceEnvironment
  | MalformedSeparator
  | MissingSeparator
  | MissingConclusion
  | ExpectedBlankLine
  | MalformedDeclaration
  | InvalidPattern
  | InvalidTemplateReference
  | InvalidToken
  | ExpectedExpression
  | ExpectedDelimiter
  | UnexpectedToken
  | AmbiguousExpression
  | InvalidNotationApplication
  | UnknownBlockKind
  | UnknownBlockOption
  | DuplicateBlockOption
  | MalformedBlockOption
  | InvalidBnfGroup
  | InvalidProduction
  | OrphanContinuation
  | InvalidEquation
  | EmptyGuard
  | ReservedDashLine
  deriving (Eq, Show)

data Diagnostic = Diagnostic
  { diagnosticKind :: DiagnosticKind,
    diagnosticSpan :: SourceSpan,
    diagnosticMessage :: Text,
    diagnosticRelated :: [SourceSpan]
  }
  deriving (Eq, Show)

formatDiagnostic :: Text -> Diagnostic -> Text
formatDiagnostic input diagnostic =
  Text.unlines
    ( excerpt (diagnosticSpan diagnostic) (diagnosticMessage diagnostic)
        ++ concatMap (\source -> excerpt source "Competing notation declared here.") (diagnosticRelated diagnostic)
    )
  where
    sourceLines = Text.splitOn "\n" input
    excerpt (SourceSpan (SourcePosition line column) (SourcePosition _ endColumn)) message =
      let number = Text.pack (show line)
          header = number <> ":" <> Text.pack (show column) <> ": " <> message
       in case drop (line - 1) sourceLines of
            rawLine : _ ->
              let source = Text.dropWhileEnd (== '\r') rawLine
                  padding = Text.map (\c -> if c == '\t' then c else ' ') (Text.take (column - 1) source)
                  width = max 1 (endColumn - column)
               in [header, number <> " | " <> source, Text.replicate (Text.length number) " " <> " | " <> padding <> Text.replicate width "^"]
            [] -> [header]

data Located a = Located
  { location :: SourceSpan,
    locatedValue :: a
  }
  deriving (Eq, Show, Functor)

advance :: SourcePosition -> Int -> SourcePosition
advance (SourcePosition line column) count = SourcePosition line (column + count)

pointSpan :: SourcePosition -> SourceSpan
pointSpan position = SourceSpan position position

cover :: SourceSpan -> SourceSpan -> SourceSpan
cover first lastSpan = SourceSpan (spanStart first) (spanEnd lastSpan)

lineSpan :: SourcePosition -> Int -> Int -> SourceSpan
lineSpan start offset width = SourceSpan (advance start offset) (advance start (offset + width))

identifierStart :: Char -> Bool
identifierStart character = isLetter character || character == '_'

identifierContinue :: Char -> Bool
identifierContinue character =
  identifierStart character
    || isMark character
    || generalCategory character == DecimalNumber
    || character `elem` scriptCharacters
  where
    -- Unicode classifies the script letters as letters already.
    scriptCharacters = "₀₁₂₃₄₅₆₇₈₉⁰¹²³⁴⁵⁶⁷⁸⁹₊₋₌₍₎⁺⁻⁼⁽⁾" :: String

symbolic :: Char -> Bool
symbolic character = isSymbol character || isPunctuation character

sliceLocated :: Int -> Int -> Located Text -> Located Text
sliceLocated offset width (Located source value) =
  Located (lineSpan (spanStart source) offset width) (Text.take width (Text.drop offset value))

trimLocated :: Located Text -> Located Text
trimLocated source =
  let value = locatedValue source
      trimmedStart = Text.dropWhile isSpace value
      offset = Text.length value - Text.length trimmedStart
      trimmed = Text.dropWhileEnd isSpace trimmedStart
   in sliceLocated offset (Text.length trimmed) source

dashLabel :: Located Text -> Maybe (SourceSpan, Text)
dashLabel source =
  let (dashes, rest) = Text.span (== '-') (locatedValue source)
   in if Text.length dashes >= 3 && (Text.null rest || maybe False (isSpace . fst) (Text.uncons rest))
        then Just (lineSpan (spanStart (location source)) 0 (Text.length dashes), Text.strip rest)
        else Nothing
