module Inference.Pandoc (runFilter, compileDocument) where

import Control.Exception (ErrorCall (..), Handler (..), IOException, catches)
import Control.Monad.Trans.State.Strict (State, evalState, state)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Inference.Blocks (BlockCompilationError (..), BlockDiagnostic (..), InferenceBlock (..), InferenceBlockKind (..), compileBlocks)
import Inference.LaTeX (renderLatex)
import Inference.Parser (formatDiagnostic)
import System.Exit (die, exitFailure)
import System.IO (hSetBinaryMode, hSetEncoding, stderr, stdin, stdout, utf8)
import Text.Pandoc.JSON (Block (..), Format (..), Pandoc (..), toJSONFilter)
import Text.Pandoc.Walk (query, walkM)

runFilter :: Maybe String -> IO ()
runFilter target = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetEncoding stderr utf8
  toJSONFilter (filterDocument (Format . Text.pack <$> target))
    `catches` [ Handler $ \(ErrorCall message) -> die ("inference: " <> message),
                Handler $ \(failure :: IOException) -> die ("inference: " <> show failure)
              ]

filterDocument :: Maybe Format -> Pandoc -> IO Pandoc
filterDocument (Just (Format "latex")) document =
  case compileDocument document of
    Right rendered -> pure rendered
    Left message -> Text.hPutStr stderr message >> exitFailure
filterDocument _ document = pure document

compileDocument :: Pandoc -> Either Text Pandoc
compileDocument (Pandoc metadata blocks) =
  case compileBlocks renderDeclaration renderRules (query (maybeToList . inferenceBlock) blocks) of
    Left failure -> Left (formatCompilationError failure)
    Right rendered -> Right (Pandoc metadata (evalState (walkM replaceBlock blocks) rendered))
  where
    rawLatex = RawBlock (Format "latex")
    renderDeclaration = rawLatex . Text.unlines . map ("% " <>) . Text.lines
    renderRules templates document = rawLatex <$> renderLatex templates document

inferenceBlock :: Block -> Maybe InferenceBlock
inferenceBlock (CodeBlock (identifier, classes, attributes) source)
  | "inference-notation" `elem` classes = Just (InferenceBlock identifier NotationBlock source)
  | "inference" `elem` classes = Just (InferenceBlock identifier (RuleBlock attributes) source)
inferenceBlock _ = Nothing

replaceBlock :: Block -> State [Block] Block
replaceBlock block = state $ \rendered ->
  case (inferenceBlock block, rendered) of
    (Just _, replacement : rest) -> (replacement, rest)
    _ -> (block, rendered)

formatCompilationError :: BlockCompilationError -> Text
formatCompilationError failure =
  formatBlockDiagnostic (compilationDiagnostic failure)
    <> foldMap formatBlockDiagnostic (compilationRelated failure)

formatBlockDiagnostic :: BlockDiagnostic -> Text
formatBlockDiagnostic (BlockDiagnostic Nothing diagnostic) = formatDiagnostic "" diagnostic
formatBlockDiagnostic (BlockDiagnostic (Just (ordinal, block)) diagnostic) =
  reference <> ":" <> formatDiagnostic (blockSource block) diagnostic
  where
    reference
      | Text.null (blockId block) = "inference block " <> Text.pack (show ordinal)
      | otherwise = "inference block #" <> blockId block
