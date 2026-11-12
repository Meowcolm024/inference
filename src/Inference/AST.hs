module Inference.AST
  ( SourcePosition (..),
    SourceSpan (..),
    Document (..),
    SourceDocument (..),
    SourceChunk (..),
    Section (..),
    SectionMarkers (..),
    BlockKind (..),
    BlockOptions (..),
    BlockBody (..),
    BnfGroup (..),
    Production (..),
    ProductionRow (..),
    EquationRow (..),
    Equation (..),
    EquationGuard (..),
    sectionRules,
    Rule (..),
    Expr (..),
    ExprNode (..),
    NotationId (..),
    Notation (..),
    PatternPart (..),
    HolePrecedence (..),
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
    sectionBody :: BlockBody
  }
  deriving (Eq, Show)

data BlockKind = InferenceKind | BnfKind | EquationKind
  deriving (Eq, Show)

data BlockOptions = BlockOptions
  { optionsKind :: BlockKind,
    optionsTitle :: Maybe Text
  }
  deriving (Eq, Show)

data BlockBody
  = InferenceRules [Rule]
  | BnfGroups [BnfGroup]
  | Equations [EquationRow]
  deriving (Eq, Show)

sectionRules :: Section -> [Rule]
sectionRules section = case sectionBody section of
  InferenceRules rules -> rules
  _ -> []

data BnfGroup = BnfGroup
  { bnfGroupName :: Text,
    bnfGroupSpan :: SourceSpan,
    bnfProductions :: [Production]
  }
  deriving (Eq, Show)

data Production = Production
  { productionCategories :: [Expr],
    productionRows :: [ProductionRow]
  }
  deriving (Eq, Show)

data ProductionRow = ProductionRow
  { productionRowSpan :: SourceSpan,
    productionAlternatives :: [Expr]
  }
  deriving (Eq, Show)

data EquationRow = EquationLine Equation | EquationBlank SourceSpan
  deriving (Eq, Show)

data Equation = Equation
  { equationSpan :: SourceSpan,
    equationLeft :: Expr,
    equationRight :: Expr,
    equationGuard :: Maybe EquationGuard
  }
  deriving (Eq, Show)

data EquationGuard = EquationGuard
  { guardHasIf :: Bool,
    guardExpression :: Expr
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
    notationPattern :: NonEmpty PatternPart
  }
  deriving (Eq, Show)

data PatternPart = Literal Text | Hole Text HolePrecedence
  deriving (Eq, Show)

data HolePrecedence = AtLeast Integer | AtomOnly
  deriving (Eq, Show)
