module Inference.Content
  ( OccurrenceKey (..),
    ParsedInference (..),
    ParsedItem (..),
    ParsedContent (..),
    sourceInference,
  )
where

import Data.Maybe (mapMaybe)
import Inference.AST
import Inference.Templates (BackendTemplates)

-- Keys identify occurrences within a single compilation.
newtype OccurrenceKey = OccurrenceKey Int
  deriving (Eq, Ord, Show)

data ParsedInference = ParsedInference
  { parsedNotations :: [Notation],
    parsedTemplates :: BackendTemplates,
    parsedItems :: [ParsedItem]
  }
  deriving (Eq, Show)

data ParsedItem = ParsedItem
  { parsedKey :: OccurrenceKey,
    parsedContent :: ParsedContent
  }
  deriving (Eq, Show)

data ParsedContent
  = ParsedNotationBlock
  | ParsedSection Section
  | ParsedInline Expr
  deriving (Eq, Show)

-- Literal chunks and the original notation text stay in the host document.
sourceInference :: BackendTemplates -> SourceDocument -> ParsedInference
sourceInference templates document =
  ParsedInference (sourceDocumentNotations document) templates items
  where
    items = zipWith (ParsedItem . OccurrenceKey) [1 ..] (mapMaybe content (sourceDocumentChunks document))
    content (LatexText _) = Nothing
    content (NotationSource _ _) = Just ParsedNotationBlock
    content (RuleSetSource section) = Just (ParsedSection section)
