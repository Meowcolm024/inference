module Inference.Parser.Body (parseBnf, parseEquations) where

import Control.Monad (when)
import Data.Char (isSpace)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser.Expression (parseExpression, parseExpressionBefore)
import Inference.Parser.Notation (NotationTable)
import Inference.Parser.Source

parseBnf :: NotationTable -> [Located Text] -> Either Diagnostic [BnfGroup]
parseBnf _ [] = Right []
parseBnf table (line : rest)
  | Text.null (locatedValue line) = parseBnf table rest
  | Text.isPrefixOf "|" (locatedValue line) =
      problem OrphanContinuation (location line) "A continuation needs a preceding production in a named BNF group."
  | Just (marker, name) <- dashLabel line = do
      when (Text.null name) (problem InvalidBnfGroup marker "Expected a syntax group name after the dashes.")
      let (body, remaining) = break (Text.null . locatedValue) rest
      when (null body) (problem InvalidBnfGroup marker "A syntax group must contain at least one production.")
      productions <- parseProductions body
      (BnfGroup name (location line) productions :) <$> parseBnf table remaining
  | otherwise = problem InvalidBnfGroup (location line) "Start each BNF group with a named dash label."
  where
    parseProductions [] = Right []
    parseProductions (source : remaining)
      | Just (marker, _) <- dashLabel source =
          problem InvalidBnfGroup marker "Separate syntax groups with a blank line."
      | Text.isPrefixOf "|" (locatedValue source) =
          problem OrphanContinuation (location source) "A continuation needs an indented row after a production."
      | otherwise = do
          let (categoriesText, suffix) = Text.breakOn "::=" (locatedValue source)
              categoryWidth = Text.length categoriesText
          when (Text.null suffix) (problem InvalidProduction (location source) "Expected ‘::=’ after the category names.")
          categories <- parseCategories (sliceLocated 0 categoryWidth source)
          first <- alternatives source (trimLocated (sliceLocated (categoryWidth + 3) (Text.length suffix - 3) source))
          let (continuations, next) = span (Text.isPrefixOf "|" . locatedValue) remaining
          rows <- traverse continuation continuations
          (Production categories (first : rows) :) <$> parseProductions next

    continuation source
      | sourceColumn (spanStart (location source)) <= 1 =
          problem OrphanContinuation (location source) "Indent a continuation row beneath its production."
      | otherwise = alternatives source (trimLocated (sliceLocated 1 (Text.length (locatedValue source) - 1) source))

    alternatives physical source = do
      expressions <- parseAlternatives source
      pure (ProductionRow (location physical) (sourceColumn (spanStart (location physical)) - 1) expressions)

    parseAlternatives source
      | Text.null (locatedValue source) = problem InvalidProduction (location source) "Expected a nonempty production alternative."
      | otherwise = do
          (expression, marker, remaining) <- parseExpressionBefore table ["|", "::="] source
          case marker of
            Nothing -> Right [expression]
            Just boundary
              | locatedValue boundary == "::=" ->
                  problem InvalidProduction (location boundary) "A production has only one outer ‘::=’ keyword."
            Just _ -> (expression :) <$> parseAlternatives remaining

parseCategories :: Located Text -> Either Diagnostic [Expr]
parseCategories source = do
  let (name, suffix) = Text.breakOn "," (locatedValue source)
      width = Text.length name
      category = trimLocated (sliceLocated 0 width source)
  expression <- case Text.uncons (locatedValue category) of
    Just (first, rest)
      | identifierStart first && Text.all identifierContinue rest -> Right (Expr (location category) (Atom (locatedValue category)))
    _ -> problem InvalidProduction (location category) "Expected a category name."
  if Text.null suffix
    then Right [expression]
    else (expression :) <$> parseCategories (sliceLocated (width + 1) (Text.length suffix - 1) source)

parseEquations :: NotationTable -> [Located Text] -> Either Diagnostic [EquationRow]
parseEquations table = traverse parseLine
  where
    parseLine source
      | Text.null (locatedValue source) = Right (EquationBlank (location source))
      | Just (marker, _) <- dashLabel source =
          problem ReservedDashLine marker "Dash labels and dividers are reserved for BNF groups."
      | otherwise = do
          (left, equal, rightSource) <- parseExpressionBefore table ["="] source
          case equal of
            Nothing -> problem InvalidEquation (pointSpan (spanEnd (location source))) "Expected an outer ‘=’ between the equation sides."
            Just _ -> pure ()
          when (Text.null (locatedValue rightSource)) (problem InvalidEquation (location rightSource) "Expected a right-hand expression.")
          (right, guardMarker, guardSource) <- parseExpressionBefore table ["--"] rightSource
          condition <- case guardMarker of
            Nothing -> Right Nothing
            Just _ -> Just <$> parseGuard guardSource
          pure (EquationLine (Equation (location source) left right condition))
    parseGuard source = do
      let value = locatedValue source
          hasIf = value == "if" || maybe False (isSpace . fst) (Text.stripPrefix "if" value >>= Text.uncons)
          condition = if hasIf then trimLocated (sliceLocated 2 (Text.length value - 2) source) else source
      when (Text.null (locatedValue condition)) (problem EmptyGuard (location condition) "Expected a nonempty guard condition.")
      EquationGuard hasIf <$> parseExpression table condition

problem :: DiagnosticKind -> SourceSpan -> Text -> Either Diagnostic a
problem kind source message = Left (Diagnostic kind source message [])
