module Inference.Templates (BackendTemplates, Templates, TemplatePart (..), templatesFor) where

import Data.List.NonEmpty (NonEmpty)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Inference.AST (NotationId)

type Templates = Map NotationId (NonEmpty TemplatePart)

type BackendTemplates = Map Text Templates

data TemplatePart = Fragment Text | Reference Text
  deriving (Eq, Show)

templatesFor :: Text -> BackendTemplates -> Templates
templatesFor backend = Map.findWithDefault Map.empty backend
