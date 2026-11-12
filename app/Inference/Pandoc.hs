module Inference.Pandoc (runFilter, compileDocument, compileDocumentFor) where

import Control.Exception (ErrorCall (..), Handler (..), IOException, catches)
import Control.Monad.Trans.State.Strict (State, evalState, state)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Inference.Blocks (BlockCompilationError (..), BlockDiagnostic (..), InferenceBlock (..), InferenceBlockKind (..), compileBlocksWithTemplates)
import Inference.HTML (renderHtml)
import Inference.LaTeX (renderLatex)
import Inference.Parser (formatDiagnostic)
import Inference.Templates (templatesFor)
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
filterDocument Nothing document = pure document
filterDocument (Just target) document =
  case compileDocumentFor target document of
    Right rendered -> pure rendered
    Left message -> Text.hPutStr stderr message >> exitFailure

compileDocument :: Pandoc -> Either Text Pandoc
compileDocument = compileDocumentFor (Format "latex")

compileDocumentFor :: Format -> Pandoc -> Either Text Pandoc
compileDocumentFor (Format target) document@(Pandoc metadata blocks)
  | target == "latex" =
      compile renderDeclaration (\templates input -> rawLatex <$> renderLatex (templatesFor "latex" templates) input)
  | target `elem` ["html", "html4", "html5"] =
      compile (const (rawHtml "")) (\templates input -> rawHtml <$> renderHtml (templatesFor "html" templates) input)
  | otherwise = Right document
  where
    compile declaration rules =
      case compileBlocksWithTemplates declaration rules (query (maybeToList . inferenceBlock) blocks) of
        Left failure -> Left (formatCompilationError failure)
        Right rendered -> Right (Pandoc metadata (evalState (walkM replaceBlock blocks) rendered))
    rawLatex = RawBlock (Format "latex")
    rawHtml = RawBlock (Format "html")
    renderDeclaration = rawLatex . Text.unlines . map ("% " <>) . Text.lines

inferenceBlock :: Block -> Maybe InferenceBlock
inferenceBlock (CodeBlock (identifier, classes, attributes) source)
  | "inference-notation" `elem` classes = Just (InferenceBlock identifier NotationBlock source)
  | "inference" `elem` classes = Just (InferenceBlock identifier (RuleBlock attributes) source)
inferenceBlock _ = Nothing

replaceBlock :: Block -> State [Block] Block
replaceBlock block = state $ \rendered ->
  case (inferenceBlock block, rendered) of
    (Just input, replacement : rest) -> (keepHtmlAnchor input replacement, rest)
    _ -> (block, rendered)

keepHtmlAnchor :: InferenceBlock -> Block -> Block
keepHtmlAnchor (InferenceBlock identifier (RuleBlock _) _) replacement@(RawBlock (Format "html") _)
  | not (Text.null identifier) = Div (identifier, [], []) [replacement]
keepHtmlAnchor _ replacement = replacement

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
