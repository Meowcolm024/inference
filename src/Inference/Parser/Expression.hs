module Inference.Parser.Expression (parseExpression, parseExpressionBefore) where

import Data.Char (GeneralCategory (MathSymbol), generalCategory, isSpace)
import Data.Either (isRight, partitionEithers)
import Data.List (find, maximumBy, sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser.Notation
import Inference.Parser.Source

data Token = Name Text | Keyword Text | Boundary Text | Open | Close
  deriving (Eq)

type Tokens = [Located Token]

tokenize :: Bool -> NotationTable -> Located Text -> Either Diagnostic Tokens
tokenize layout table (Located source text) = go (spanStart source) text
  where
    layoutMarkers = ["::=", "|", "=", "--"]
    symbols =
      if layout
        then Map.map (sortOn (Down . Text.length)) (Map.unionWith (++) (symbolicLiterals table) (Map.fromListWith (++) [(first, [literal]) | literal <- layoutMarkers, Just (first, _) <- [Text.uncons literal]]))
        else symbolicLiterals table
    guardBoundary start input =
      let offset = sourceColumn start - sourceColumn (spanStart source)
          before = Text.take offset text
          after = Text.drop 2 input
       in maybe False (isSpace . snd) (Text.unsnoc before) && maybe True (isSpace . fst) (Text.uncons after)
    go start input = case Text.uncons input of
      Nothing -> Right []
      Just (first, rest)
        | isSpace first -> go (advance start 1) rest
        | identifierStart first ->
            let (suffix, remaining) = Text.span identifierContinue rest
                name = Text.cons first suffix
                token = if Set.member name (allLiterals table) then Keyword name else Name name
             in emit start (1 + Text.length suffix) token remaining
        | first == '(' -> emit start 1 Open rest
        | first == ')' -> emit start 1 Close rest
        | Just literal <- find (`Text.isPrefixOf` input) (Map.findWithDefault [] first symbols) ->
            let width = Text.length literal
             in if literal == "--" && layout && not (guardBoundary start input)
                  then case find (\candidate -> Text.isPrefixOf candidate input) (Map.findWithDefault [] first (symbolicLiterals table)) of
                    Just declared -> emit start (Text.length declared) (Keyword declared) (Text.drop (Text.length declared) input)
                    Nothing -> Left (Diagnostic InvalidToken (lineSpan start 0 1) "A guard delimiter requires whitespace on both sides." [])
                  else emit start width (if layout && elem literal layoutMarkers then Boundary literal else Keyword literal) (Text.drop width input)
        | generalCategory first == MathSymbol -> emit start 1 (Name (Text.singleton first)) rest
        | otherwise ->
            Left (Diagnostic InvalidToken (lineSpan start 0 1) ("Unknown token ‘" <> Text.singleton first <> "’.") [])
    emit start width token remaining =
      (Located (lineSpan start 0 width) token :) <$> go (advance start width) remaining

-- Atoms, groups and applications have no upper precedence bound.
data BoundExpr = BoundExpr Expr (Maybe Integer)

data Context = Context
  { notationTable :: NotationTable,
    endOfLine :: SourceSpan
  }

-- Shared leading literals can yield several Pratt branches. Retain failures
-- for diagnostics, and consider ambiguity only among complete parses.
type Search a = [Either Diagnostic a]

andThen :: Search a -> (a -> Search b) -> Search b
andThen results next = concatMap (either (pure . Left) next) results

parseExpression :: NotationTable -> Located Text -> Either Diagnostic Expr
parseExpression table source = do
  tokens <- tokenize False table source
  let context = Context table (pointSpan (spanEnd (location source)))
      complete (BoundExpr expression _, []) = [Right expression]
      complete (_, token : _) =
        [Left (Diagnostic UnexpectedToken (location token) ("Unexpected " <> describeToken (locatedValue token) <> " after expression.") [])]
      (failures, expressions) = partitionEithers (parseAt context (const False) 0 tokens `andThen` complete)
  case expressions of
    first : second : _ -> Left (ambiguity table (location source) first second)
    [expression] -> Right expression
    [] -> case failures of
      first : rest -> Left (maximumBy (comparing failurePriority) (first :| rest))
      [] -> Left (expected context tokens ExpectedExpression "Expected an expression.")
  where
    failurePriority problem =
      (spanStart (diagnosticSpan problem), diagnosticKind problem == ExpectedDelimiter)

tokenLiteral :: Token -> Maybe Text
tokenLiteral (Keyword literal) = Just literal
tokenLiteral (Boundary literal) = Just literal
tokenLiteral _ = Nothing

-- Stop at a layout delimiter only at the current expression level. Pattern
-- delimiters and grouped expressions can consume the same tokens internally.
parseExpressionBefore :: NotationTable -> [Text] -> Located Text -> Either Diagnostic (Expr, Maybe (Located Text), Located Text)
parseExpressionBefore table markers source = do
  tokens <- tokenize True table source
  let context = Context table (pointSpan (spanEnd (location source)))
      stops (Boundary literal) = elem literal markers
      stops _ = False
      complete (BoundExpr expression _, remaining) = case remaining of
        [] -> Right (expression, Nothing, sliceLocated (Text.length (locatedValue source)) 0 source)
        Located span' (Boundary literal) : _
          | elem literal markers ->
              let offset = sourceColumn (spanEnd span') - sourceColumn (spanStart (location source))
               in Right (expression, Just (Located span' literal), trimLocated (sliceLocated offset (Text.length (locatedValue source) - offset) source))
        token : _ -> Left (Diagnostic UnexpectedToken (location token) ("Unexpected " <> describeToken (locatedValue token) <> " after expression.") [])
      (failures, results) = partitionEithers (map (>>= complete) (parseAt context stops 0 tokens))
  case results of
    (expression, _, _) : (other, _, _) : _ -> Left (ambiguity table (location source) expression other)
    [result] -> Right result
    [] -> case failures of
      failure : rest -> Left (maximumBy (comparing (spanStart . diagnosticSpan)) (failure :| rest))
      [] -> Left (expected context tokens ExpectedExpression "Expected an expression.")

parseAt :: Context -> (Token -> Bool) -> Integer -> Tokens -> Search (BoundExpr, Tokens)
parseAt context delimiter minimumPrecedence tokens =
  term tokens `andThen` extend
  where
    table = notationTable context
    term input@(Located lead token : rest)
      | Just literal <- tokenLiteral token,
        not (delimiter token),
        candidates <- Map.findWithDefault [] literal (prefixNotations table),
        notations <- filter ((>= minimumPrecedence) . notationPrecedence) candidates,
        not (null notations) =
          concat [parseNotationUse context delimiter notation lead [] parts rest | notation <- notations, _ :| parts <- [notationPattern notation]]
      | Just _ <- tokenLiteral token = [Left (expected context input ExpectedExpression "Expected an expression.")]
      | otherwise = parseApplication context input
    term input = parseApplication context input

    extend current@(left, Located lead token : rest)
      | Just literal <- tokenLiteral token,
        not (delimiter token) =
          let candidates = Map.findWithDefault [] literal (leftNotations table)
              attempts =
                concat
                  [ parseNotationUse context delimiter notation lead [unbound left] parts rest
                  | notation <- candidates,
                    notationPrecedence notation >= minimumPrecedence,
                    Hole _ requirement :| Literal _ : parts <- [notationPattern notation],
                    fits requirement left
                  ]
           in (attempts `andThen` extend) ++ [Right current | not (any isRight attempts)]
    extend current = [Right current]

unbound :: BoundExpr -> Expr
unbound (BoundExpr expression _) = expression

fits :: HolePrecedence -> BoundExpr -> Bool
fits (AtLeast minimumPrecedence) (BoundExpr _ precedence) = maybe True (>= minimumPrecedence) precedence
fits AtomOnly (BoundExpr expression _) = case exprNode expression of
  Atom _ -> True
  Group _ -> True
  _ -> False

parseApplication :: Context -> Tokens -> Search (BoundExpr, Tokens)
parseApplication context tokens = parseAtom context tokens `andThen` extend
  where
    extend (function, remaining@(Located _ next : _))
      | startsAtom next =
          parseAtom context remaining `andThen` \(argument, rest) ->
            let source = cover (exprSpan function) (exprSpan argument)
             in extend (Expr source (Application function argument), rest)
    extend (expression, remaining) = [Right (BoundExpr expression Nothing, remaining)]
    startsAtom (Name _) = True
    startsAtom Open = True
    startsAtom _ = False

parseAtom :: Context -> Tokens -> Search (Expr, Tokens)
parseAtom _ (Located source (Name name) : rest) = [Right (Expr source (Atom name), rest)]
parseAtom context (Located start Open : rest) =
  parseAt context (const False) 0 rest `andThen` \case
    (BoundExpr expression _, Located end Close : remaining) -> [Right (Expr (cover start end) (Group expression), remaining)]
    (_, remaining) -> [Left (expected context remaining ExpectedDelimiter "Expected closing parenthesis.")]
parseAtom context tokens = [Left (expected context tokens ExpectedExpression "Expected an atom or a parenthesized expression.")]

parseNotationUse :: Context -> (Token -> Bool) -> Notation -> SourceSpan -> [Expr] -> [PatternPart] -> Tokens -> Search (BoundExpr, Tokens)
parseNotationUse context delimiter notation lead leftArguments = match leftArguments lead
  where
    start = case leftArguments of
      left : _ -> exprSpan left
      [] -> lead
    match arguments end [] remaining =
      let expression = Expr (cover start end) (NotationApplication (notationId notation) lead (reverse arguments))
       in [Right (BoundExpr expression (Just (notationPrecedence notation)), remaining)]
    match arguments _ (Literal literal : parts) remaining = case remaining of
      Located source token : rest
        | tokenLiteral token == Just literal -> match arguments source parts rest
      _ -> [Left (expected context remaining ExpectedDelimiter ("Expected delimiter ‘" <> literal <> "’."))]
    match arguments _ (Hole _ requirement : parts) remaining =
      let nextDelimiter = case parts of
            Literal literal : _ -> (== Just literal) . tokenLiteral
            _ -> delimiter
          parseHole = case requirement of
            AtomOnly -> parseAtom context remaining
            AtLeast precedence -> map (fmap (\(expression, rest) -> (unbound expression, rest))) (parseAt context nextDelimiter precedence remaining)
       in parseHole `andThen` \(argument, rest) -> match (argument : arguments) (exprSpan argument) parts rest

expected :: Context -> Tokens -> DiagnosticKind -> Text -> Diagnostic
expected context tokens kind message =
  case tokens of
    token : _ -> Diagnostic kind (location token) (message <> " Found " <> describeToken (locatedValue token) <> ".") []
    [] -> Diagnostic kind (endOfLine context) (message <> " Reached the end of the line.") []

describeToken :: Token -> Text
describeToken = \case
  Name name -> "atom ‘" <> name <> "’"
  Keyword literal -> "notation token ‘" <> literal <> "’"
  Boundary literal -> "layout delimiter ‘" <> literal <> "’"
  Open -> "opening parenthesis"
  Close -> "closing parenthesis"

ambiguity :: NotationTable -> SourceSpan -> Expr -> Expr -> Diagnostic
ambiguity table source first second =
  case find (uncurry (/=) . snd) (Map.toAscList sharedChoices) of
    Just (lead, (firstId, secondId)) ->
      let keywordNotations = concat (Map.elems (prefixNotations table)) ++ concat (Map.elems (leftNotations table))
          related = Set.toAscList (Set.fromList [notationSpan n | n <- keywordNotations, notationId n `elem` [firstId, secondId]])
       in problem lead related
    Nothing -> problem source []
  where
    sharedChoices = Map.intersectionWith (,) (choices first) (choices second)
    problem lead = Diagnostic AmbiguousExpression lead "Competing notation declarations give multiple parses."
    choices = Map.fromList . collect
    collect expression = case exprNode expression of
      Atom _ -> []
      Group inner -> collect inner
      Application function argument -> collect function ++ collect argument
      NotationApplication identity lead arguments -> (lead, identity) : concatMap collect arguments
