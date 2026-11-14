module Inference.Blocks
  ( InferenceBlock (..),
    InferenceBlockKind (..),
    BlockCompilationError (..),
    BlockDiagnostic (..),
    compileBlocks,
    compileBlocksWithTemplates,
    compileBlocksWithContext,
    compileBlocksInScope,
  )
where

import Data.IntMap.Strict qualified as IntMap
import Data.List (mapAccumL)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST (Document (..), Notation, SourcePosition (..), SourceSpan (..))
import Inference.LaTeX.Templates (LatexTemplates)
import Inference.Modules (ModuleDiagnostic)
import Inference.Parser (Diagnostic (..), parseBlockAttributes, parseBlockSection, parseNotationBlockWithTemplates)
import Inference.Templates (BackendTemplates, templatesFor)

data InferenceBlockKind = NotationBlock | RuleBlock [(Text, Text)]
  deriving (Eq, Show)

data InferenceBlock = InferenceBlock
  { blockId :: Text,
    blockKind :: InferenceBlockKind,
    blockSource :: Text
  }
  deriving (Eq, Show)

data BlockCompilationError = BlockCompilationError
  { compilationDiagnostic :: BlockDiagnostic,
    compilationRelated :: [BlockDiagnostic]
  }
  deriving (Eq, Show)

data BlockDiagnostic
  = BlockDiagnostic (Maybe (Int, InferenceBlock)) Diagnostic
  | ImportedDiagnostic ModuleDiagnostic
  deriving (Eq, Show)

-- Output follows input order. Diagnostics use one-based block ordinals and
-- block-relative spans, including for related notation declarations.
compileBlocks ::
  (Text -> output) ->
  (LatexTemplates -> Document -> Either Diagnostic output) ->
  [InferenceBlock] ->
  Either BlockCompilationError [output]
compileBlocks renderDeclaration renderDocument =
  compileBlocksWithTemplates renderDeclaration (renderDocument . templatesFor "latex")

-- Use backend-specific overrides from the same set of notation declarations.
compileBlocksWithTemplates ::
  (Text -> output) ->
  (BackendTemplates -> Document -> Either Diagnostic output) ->
  [InferenceBlock] ->
  Either BlockCompilationError [output]
compileBlocksWithTemplates renderDeclaration renderDocument blocks =
  fst <$> compileBlocksWithContext renderDeclaration renderDocument (\_ _ _ -> ()) blocks

-- Inline expressions can use the same validated declarations and diagnostic origins.
compileBlocksWithContext ::
  (Text -> output) ->
  (BackendTemplates -> Document -> Either Diagnostic output) ->
  ([Notation] -> BackendTemplates -> (Diagnostic -> [BlockDiagnostic]) -> result) ->
  [InferenceBlock] ->
  Either BlockCompilationError ([output], result)
compileBlocksWithContext renderDeclaration renderDocument compileOther blocks = do
  (notations, templates) <- case parseNotationBlockWithTemplates source of
    Left diagnostic -> Left (BlockCompilationError (locateNotation diagnostic) [])
    Right parsed -> Right parsed
  compileBlocksInScope renderDeclaration renderDocument compileOther (notations, templates, relatedDeclarations) blocks
  where
    numbered = zip [1 ..] blocks
    declarations = [(ordinal, block) | (ordinal, block@InferenceBlock {blockKind = NotationBlock}) <- numbered]
    -- A blank line prevents template clauses from attaching across blocks.
    -- CRLF also keeps a trailing lone CR in a block invalid.
    source = Text.concat [blockSource block <> "\r\n\n" | (_, block) <- declarations]
    origins = IntMap.fromDistinctAscList (snd (mapAccumL indexBlock 1 declarations))
    indexBlock line entry@(_, block) = (line + Text.count "\n" (blockSource block) + 2, (line, entry))
    relatedDeclarations diagnostic =
      [ locateNotation diagnostic {diagnosticSpan = span', diagnosticMessage = "Competing notation declared here."}
      | span' <- diagnosticRelated diagnostic
      ]
    locateNotation diagnostic =
      case IntMap.lookupLE (sourceLine (spanStart span')) origins of
        Just (firstLine, entry) ->
          let relative position = position {sourceLine = sourceLine position - firstLine + 1}
              localSpan = SourceSpan (relative (spanStart span')) (relative (spanEnd span'))
           in BlockDiagnostic (Just entry) diagnostic {diagnosticSpan = localSpan, diagnosticRelated = []}
        Nothing -> BlockDiagnostic Nothing diagnostic
      where
        span' = diagnosticSpan diagnostic

-- Compile host blocks with declarations already loaded by the caller.
compileBlocksInScope ::
  (Text -> output) ->
  (BackendTemplates -> Document -> Either Diagnostic output) ->
  ([Notation] -> BackendTemplates -> (Diagnostic -> [BlockDiagnostic]) -> result) ->
  ([Notation], BackendTemplates, Diagnostic -> [BlockDiagnostic]) ->
  [InferenceBlock] ->
  Either BlockCompilationError ([output], result)
compileBlocksInScope renderDeclaration renderDocument compileOther (notations, templates, relatedDeclarations) blocks = do
  let compileBlock entry@(_, block) = case blockKind block of
        NotationBlock -> Right (renderDeclaration (blockSource block))
        RuleBlock attributes ->
          case do
            options <- parseBlockAttributes attributes
            section <- parseBlockSection notations options (blockSource block)
            renderDocument templates (Document notations [section]) of
            Left diagnostic ->
              let primary = BlockDiagnostic (Just entry) diagnostic {diagnosticRelated = []}
               in Left (BlockCompilationError primary (relatedDeclarations diagnostic))
            Right rendered -> Right rendered
  rendered <- traverse compileBlock (zip [1 ..] blocks)
  pure (rendered, compileOther notations templates relatedDeclarations)
