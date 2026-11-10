module Inference.AST
  ( SourcePosition (..),
    SourceSpan (..),
    Document (..),
    SourceDocument (..),
    SourceChunk (..),
    Section (..),
    SectionMarkers (..),
    Rule (..),
    Expr (..),
    ExprNode (..),
    NotationId (..),
    Notation (..),
    PatternPart (..),
    HolePrecedence (..),
    TemplatePart (..),
  )
where

import Data.List.NonEmpty (NonEmpty)
import Data.Text (Text)

-- Coordinates count Unicode code points, including tabs, from one.
data SourcePosition = SourcePosition
  { sourceLine :: Int,
    sourceColumn :: Int
  }
  deriving (Eq, Ord, Show)

-- The end is exclusive.
data SourceSpan = SourceSpan
  { spanStart :: SourcePosition,
    spanEnd :: SourcePosition
  }
  deriving (Eq, Ord, Show)

data Document = Document
  { documentNotations :: [Notation],
    documentSections :: [Section]
  }
  deriving (Eq, Show)

data SourceDocument = SourceDocument
  { sourceDocumentNotations :: [Notation],
    sourceDocumentChunks :: [SourceChunk]
  }
  deriving (Eq, Show)

data SourceChunk
  = LatexText Text
  | NotationSource SectionMarkers Text
  | RuleSetSource Section
  deriving (Eq, Show)

data Section = Section
  { sectionTitle :: Maybe Text,
    sectionMarkers :: Maybe SectionMarkers,
    sectionRules :: [Rule]
  }
  deriving (Eq, Show)

data SectionMarkers = SectionMarkers
  { sectionBeginSpan :: SourceSpan,
    sectionEndSpan :: SourceSpan
  }
  deriving (Eq, Show)

data Rule = Rule
  { ruleSpan :: SourceSpan,
    ruleLabel :: Maybe Text,
    rulePremises :: [Expr],
    ruleConclusion :: Expr
  }
  deriving (Eq, Show)

data Expr = Expr
  { exprSpan :: SourceSpan,
    exprNode :: ExprNode
  }
  deriving (Eq, Show)

data ExprNode
  = Atom Text
  | Group Expr
  | Application Expr Expr
  | NotationApplication NotationId SourceSpan [Expr]
  deriving (Eq, Show)

newtype NotationId = NotationId Int
  deriving (Eq, Ord, Show)

data Notation = Notation
  { notationId :: NotationId,
    notationSpan :: SourceSpan,
    notationPrecedence :: Integer,
    notationPattern :: NonEmpty PatternPart,
    notationTemplate :: NonEmpty TemplatePart
  }
  deriving (Eq, Show)

data PatternPart = Literal Text | Hole Text HolePrecedence
  deriving (Eq, Show)

data HolePrecedence = AtLeast Integer | AtomOnly
  deriving (Eq, Show)

data TemplatePart = Fragment Text | Reference Text
  deriving (Eq, Show)
