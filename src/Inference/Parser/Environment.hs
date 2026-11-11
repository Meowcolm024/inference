module Inference.Parser.Environment
  ( RawChunk (..),
    scanEnvironments,
  )
where

import Control.Applicative ((<|>))
import Data.Char (isSpace)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser.Options (parseSourceOptions)
import Inference.Parser.Source

data RawChunk
  = RawLatex Text
  | RawNotation SectionMarkers Text
  | RawRuleSet SectionMarkers BlockOptions Text

data Environment = NotationEnvironment | RuleEnvironment
  deriving (Eq)

data Delimiter = Opening Environment (Located Text) | Closing Environment Text

scanEnvironments :: Text -> Either Diagnostic [RawChunk]
scanEnvironments = outside [] . zip [1 ..] . physicalLines
  where
    outside latex [] = Right (plain latex [])
    outside latex ((number, raw) : rest) =
      case delimiter number raw of
        Nothing -> outside (raw : latex) rest
        Just (source, Closing _ suffix)
          | not (Text.null suffix) ->
              invalidClosing source
          | otherwise ->
              problem UnexpectedSourceEnd source "This closing delimiter has no open inference environment."
        Just (source, Opening environment options) -> do
          configuration <- parseOptions environment source options
          chunks <- inside environment configuration source [] rest
          pure (plain latex chunks)

    inside environment title begin body ((number, raw) : rest) =
      case delimiter number raw of
        Nothing -> inside environment title begin (raw : body) rest
        Just (source, Opening _ _) ->
          problem NestedSourceEnvironment source "Close the current inference environment before opening another."
        Just (source, Closing actual suffix)
          | not (Text.null suffix) ->
              invalidClosing source
          | actual /= environment ->
              problem MismatchedSourceEnd source ("Expected ‘" <> closing environment <> "’ to close this environment.")
          | otherwise ->
              let markers = SectionMarkers begin source
                  content = Text.concat (reverse body)
                  chunk = case environment of
                    NotationEnvironment -> RawNotation markers content
                    RuleEnvironment -> RawRuleSet markers title content
               in (chunk :) <$> outside [] rest
    inside environment _ begin _ [] =
      problem UnclosedSourceEnvironment begin ("This environment is missing its closing ‘" <> closing environment <> "’ delimiter.")

    plain [] rest = rest
    plain latex rest = RawLatex (Text.concat (reverse latex)) : rest
    invalidClosing source = problem MalformedSourceDelimiter source "Place the closing delimiter on its own line."

physicalLines :: Text -> [Text]
physicalLines input
  | Text.null input = []
  | otherwise =
      let (line, suffix) = Text.breakOn "\n" input
       in if Text.null suffix then [line] else (line <> "\n") : physicalLines (Text.drop 1 suffix)

delimiter :: Int -> Text -> Maybe (SourceSpan, Delimiter)
delimiter number raw =
  let line = case Text.stripSuffix "\n" raw of
        Just beforeLF -> fromMaybe beforeLF (Text.stripSuffix "\r" beforeLF)
        Nothing -> raw
      (indent, rest) = Text.span horizontalSpace line
      content = Text.dropWhileEnd horizontalSpace rest
      source = lineSpan (SourcePosition number 1) (Text.length indent) (Text.length content)
      match prefix kind = do
        suffix <- Text.stripPrefix prefix content
        let value = Text.dropWhile horizontalSpace suffix
            offset = Text.length content - Text.length value
        pure (kind (Located (lineSpan (spanStart source) offset (Text.length value)) value))
   in (source,)
        <$> ( match "\\begin{inference-notation}" (Opening NotationEnvironment)
                <|> match "\\begin{inference}" (Opening RuleEnvironment)
                <|> match (closing NotationEnvironment) (Closing NotationEnvironment . locatedValue)
                <|> match (closing RuleEnvironment) (Closing RuleEnvironment . locatedValue)
            )

parseOptions :: Environment -> SourceSpan -> Located Text -> Either Diagnostic BlockOptions
parseOptions RuleEnvironment _ options = parseSourceOptions options
parseOptions NotationEnvironment source options
  | Text.null (locatedValue options) = Right (BlockOptions InferenceKind Nothing)
  | otherwise = problem MalformedSourceDelimiter source "Place ‘\\begin{inference-notation}’ on its own line without options."

horizontalSpace :: Char -> Bool
horizontalSpace character = isSpace character && character /= '\r'

closing :: Environment -> Text
closing NotationEnvironment = "\\end{inference-notation}"
closing RuleEnvironment = "\\end{inference}"

problem :: DiagnosticKind -> SourceSpan -> Text -> Either Diagnostic a
problem kind source message = Left (Diagnostic kind source message [])
