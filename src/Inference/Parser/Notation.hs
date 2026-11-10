module Inference.Parser.Notation
  ( isDeclaration,
    parseNotation,
    NotationTable (..),
    buildNotationTable,
  )
where

import Control.Monad (foldM, void)
import Data.Char (isSpace)
import Data.Foldable (traverse_)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Void (Void)
import Inference.AST
import Inference.Parser.Source
import Text.Megaparsec (Parsec, choice, eof, errorOffset, getOffset, manyTill, runParser, satisfy, takeWhileP, try, (<|>))
import Text.Megaparsec qualified as Megaparsec
import Text.Megaparsec.Char (char, string)
import Text.Megaparsec.Char.Lexer qualified as Lexer

data Associativity = NonAssociative | LeftAssociative | RightAssociative

data DeclarationStyle = Mixfix | Infix Associativity

declarationStyles :: [(Text, DeclarationStyle)]
declarationStyles =
  [("notation", Mixfix), ("infixl", Infix LeftAssociative), ("infixr", Infix RightAssociative), ("infix", Infix NonAssociative)]

isDeclaration :: Text -> Bool
isDeclaration line =
  let (name, rest) = Text.span identifierContinue line
   in name `elem` map fst declarationStyles && ":" `Text.isPrefixOf` Text.stripStart rest

type Parser = Parsec Void Text

parseNotation :: NotationId -> Located Text -> Either Diagnostic Notation
parseNotation identity (Located source text) = do
  (precedence, patternParts, template) <-
    case runParser (declaration (spanStart source) <* eof) "declaration" text of
      Right result -> Right result
      Left bundle ->
        let parseError = NonEmpty.head (Megaparsec.bundleErrors bundle)
            offset = errorOffset parseError
            width = if offset < Text.length text then 1 else 0
            problem = lineSpan (spanStart source) offset width
            message = Text.strip (Text.pack (Megaparsec.parseErrorTextPretty parseError))
         in Left (Diagnostic MalformedDeclaration problem message [])
  holes <- validatePattern source patternParts
  traverse_ (validateReference holes) template
  pure (Notation identity source precedence (fmap locatedValue patternParts) (fmap locatedValue template))

declaration :: SourcePosition -> Parser (Integer, NonEmpty (Located PatternPart), NonEmpty (Located TemplatePart))
declaration start = do
  style <- choice [result <$ string name | (name, result) <- declarationStyles]
  spacing
  void (symbol ":")
  precedence <- lexeme Lexer.decimal
  (patternParts, template) <- case style of
    Mixfix -> do
      first <- patternPart
      rest <- manyTill patternPart (symbol "=>")
      parts <- (:|) <$> templatePart <*> manyTill templatePart eof
      pure (first :| rest, parts)
    Infix associativity -> do
      literal <- located (Literal <$> quoted)
      void (symbol "=>")
      fragment <- located (Fragment <$> quoted)
      let (left, right) = case associativity of
            LeftAssociative -> (precedence, precedence + 1)
            RightAssociative -> (precedence + 1, precedence)
            NonAssociative -> (precedence + 1, precedence + 1)
          source = location literal
          patternParts = Located source (Hole "left" (AtLeast left)) :| [literal, Located source (Hole "right" (AtLeast right))]
          template = Located source (Reference "left") :| [fragment, Located source (Reference "right")]
      pure (patternParts, template)
  pure (precedence, fmap (fmap trimLiteral) patternParts, template)
  where
    located :: Parser a -> Parser (Located a)
    located parser = do
      begin <- getOffset
      value <- parser
      end <- getOffset
      spacing
      pure (Located (lineSpan start begin (end - begin)) value)
    patternPart = located ((Literal <$> quoted) <|> hole)
    hole = do
      name <- lexeme identifier
      void (symbol ":")
      precedence <- (AtomOnly <$ string "atom") <|> (AtLeast <$> Lexer.decimal)
      pure (Hole name precedence)
    templatePart = located ((Fragment <$> quoted) <|> (Reference <$> identifier))
    trimLiteral (Literal literal) = Literal (Text.strip literal)
    trimLiteral part = part

identifier :: Parser Text
identifier = Text.cons <$> satisfy identifierStart <*> takeWhileP Nothing identifierContinue

quoted :: Parser Text
quoted = Text.pack <$> (char '"' *> manyTill quotedCharacter (char '"'))
  where
    quotedCharacter = try (char '\\' *> satisfy (\c -> c == '"' || c == '\\')) <|> satisfy (/= '"')

spacing :: Parser ()
spacing = void (takeWhileP Nothing isSpace)

lexeme :: Parser a -> Parser a
lexeme parser = parser <* spacing

symbol :: Text -> Parser Text
symbol = lexeme . string

validatePattern :: SourceSpan -> NonEmpty (Located PatternPart) -> Either Diagnostic (Set Text)
validatePattern source parts = do
  case parts of
    Located _ (Hole _ _) :| [] -> invalid source "A pattern must contain a literal."
    _ -> pure ()
  snd <$> foldM validatePart (False, Set.empty) parts
  where
    validatePart (_, holes) (Located span' (Literal literal))
      | validLiteral literal = Right (False, holes)
      | otherwise = invalid span' "A literal must be an identifier or a run of symbols or punctuation without parentheses."
    validatePart (previousWasHole, holes) (Located span' (Hole name _))
      | previousWasHole = invalid span' "A literal must separate consecutive holes."
      | Set.member name holes = invalid span' ("Duplicate hole " <> name <> ".")
      | otherwise = Right (True, Set.insert name holes)
    invalid span' message = Left (Diagnostic InvalidPattern span' message [])

validLiteral :: Text -> Bool
validLiteral literal = case Text.uncons literal of
  Nothing -> False
  Just (first, rest)
    | identifierStart first -> Text.all identifierContinue rest
    | otherwise -> Text.all (\c -> symbolic c && c /= '(' && c /= ')') literal

validateReference :: Set Text -> Located TemplatePart -> Either Diagnostic ()
validateReference holes (Located span' (Reference name))
  | Set.notMember name holes = Left (Diagnostic InvalidTemplateReference span' ("Unknown template hole " <> name <> ".") [])
validateReference _ _ = Right ()

data NotationTable = NotationTable
  { prefixNotations :: Map Text [Notation],
    leftNotations :: Map Text [Notation],
    allLiterals :: Set Text,
    symbolicLiterals :: Map Char [Text]
  }

buildNotationTable :: [Notation] -> NotationTable
buildNotationTable notations =
  NotationTable
    { prefixNotations = Map.fromListWith (++) prefixes,
      leftNotations = Map.fromListWith (++) leftExtensions,
      allLiterals = literals,
      symbolicLiterals = Map.map (sortOn (Down . Text.length)) symbols
    }
  where
    prefixes = [(literal, [notation]) | notation <- notations, Literal literal :| _ <- [notationPattern notation]]
    leftExtensions = [(literal, [notation]) | notation <- notations, Hole _ _ :| Literal literal : _ <- [notationPattern notation]]
    literals = Set.fromList [literal | notation <- notations, Literal literal <- NonEmpty.toList (notationPattern notation)]
    symbols =
      Map.fromListWith
        (++)
        [(first, [literal]) | literal <- Set.toList literals, Just (first, _) <- [Text.uncons literal], not (identifierStart first)]
