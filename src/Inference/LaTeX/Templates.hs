module Inference.LaTeX.Templates (LatexTemplates, TemplatePart (..)) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Inference.AST (NotationId)

type LatexTemplates = Map NotationId (NonEmpty TemplatePart)

data TemplatePart = Fragment Text | Reference Text
  deriving (Eq, Show)
