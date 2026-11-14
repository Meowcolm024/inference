module Inference.Parser.Options (parseSourceOptions, parseBlockAttributes) where

import Control.Monad (foldM)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser.Source

parseSourceOptions :: Located Text -> Either Diagnostic BlockOptions
parseSourceOptions source
  | Text.null (locatedValue source) = Right (BlockOptions InferenceKind Nothing)
  | Just inner <- Text.stripPrefix "[" (locatedValue source) >>= Text.stripSuffix "]" = do
      parts <- splitOptions (sliceLocated 1 (Text.length inner) source)
      pairs <- traverse option parts
      parseOptions pairs
  | otherwise = invalid (location source) "Expected options enclosed in ‘[’ and ‘]’."
  where
    option part =
      let (key, rest) = Text.breakOn "=" (locatedValue part)
       in if Text.null rest
            then invalid (location part) "Expected an option of the form ‘name=value’."
            else do
              value <- unbrace (trimLocated (sliceLocated (Text.length key + 1) (Text.length rest - 1) part))
              Right (trimLocated (sliceLocated 0 (Text.length key) part), value)

-- Pandoc attributes have no character offsets in the block body.
parseBlockAttributes :: [(Text, Text)] -> Either Diagnostic BlockOptions
parseBlockAttributes attributes =
  parseOptions [(located key, located (Text.strip (unquote value))) | (key, value) <- attributes]
  where
    located = Located (pointSpan (SourcePosition 1 1))
    unquote value = case Text.stripPrefix "\"" value >>= Text.stripSuffix "\"" of
      Just content -> content
      Nothing -> value

parseOptions :: [(Located Text, Located Text)] -> Either Diagnostic BlockOptions
parseOptions pairs = snd <$> foldM apply (Set.empty, BlockOptions InferenceKind Nothing) pairs
  where
    apply (seen, options) (key, rawValue)
      | Set.member name seen = Left (Diagnostic DuplicateBlockOption (location key) ("Duplicate option ‘" <> name <> "’.") [])
      | otherwise = do
          let value = rawValue
          updated <- case name of
            "kind" -> do
              kind <- case locatedValue value of
                "bnf" -> Right BnfKind
                "equation" -> Right EquationKind
                "expr" -> Right ExprKind
                _ -> Left (Diagnostic UnknownBlockKind (location value) ("Unknown block kind ‘" <> locatedValue value <> "’. Use ‘bnf’, ‘equation’, or ‘expr’, or omit ‘kind’ for inference rules.") [])
              pure options {optionsKind = kind}
            "rule_set"
              | Text.null (locatedValue value) -> invalid (location value) "A rule_set title must be nonempty."
              | otherwise -> Right options {optionsTitle = Just (locatedValue value)}
            _ -> Left (Diagnostic UnknownBlockOption (location key) ("Unknown option ‘" <> name <> "’.") [])
          pure (Set.insert name seen, updated)
      where
        name = locatedValue key

unbrace :: Located Text -> Either Diagnostic (Located Text)
unbrace source
  | Just _ <- Text.stripPrefix "{" (locatedValue source) =
      case Text.stripSuffix "}" (locatedValue source) of
        Just _ -> Right (trimLocated (sliceLocated 1 (Text.length (locatedValue source) - 2) source))
        Nothing -> invalid (location source) "Unclosed braced option value."
  | otherwise = Right (trimLocated source)

splitOptions :: Located Text -> Either Diagnostic [Located Text]
splitOptions source = go 0 0 0 (Text.unpack (locatedValue source))
  where
    go :: Int -> Int -> Int -> [Char] -> Either Diagnostic [Located Text]
    go depth start offset []
      | depth /= 0 = invalid (location source) "Unbalanced braces in options."
      | otherwise = Right [sliceLocated start (offset - start) source]
    go depth start offset (char : rest) = case char of
      '{' -> go (depth + 1) start (offset + 1) rest
      '}'
        | depth == 0 -> invalid (location (sliceLocated offset 1 source)) "Unexpected closing brace in options."
        | otherwise -> go (depth - 1) start (offset + 1) rest
      ']' | depth == 0 -> invalid (location (sliceLocated offset 1 source)) "Unexpected closing bracket in options."
      ','
        | depth == 0 ->
            (sliceLocated start (offset - start) source :) <$> go depth (offset + 1) (offset + 1) rest
      _ -> go depth start (offset + 1) rest

invalid :: SourceSpan -> Text -> Either Diagnostic a
invalid source message = Left (Diagnostic MalformedBlockOption source message [])
