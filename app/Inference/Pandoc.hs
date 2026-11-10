module Inference.Pandoc (runFilter) where

import Control.Exception (ErrorCall (..), Handler (..), IOException, catches)
import Control.Monad.Trans.State.Strict (StateT (..), evalStateT)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.List (mapAccumL)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Inference.AST (Document (..), SourcePosition (..), SourceSpan (..))
import Inference.LaTeX (renderLatex)
import Inference.Parser (Diagnostic (..), formatDiagnostic, parseNotationBlock, parseRuleSection)
import System.Exit (die, exitFailure)
import System.IO (hSetBinaryMode, hSetEncoding, stderr, stdin, stdout, utf8)
import Text.Pandoc.JSON (Block (..), Format (..), Pandoc (..), toJSONFilter)
import Text.Pandoc.Walk (query, walkM)

data BlockKind = NotationBlock | RuleBlock (Maybe Text)

data InferenceBlock = InferenceBlock
  { blockId :: Text,
    blockKind :: BlockKind,
    blockSource :: Text
  }

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
compileDocument (Pandoc metadata blocks) = do
  let annotated = query (maybeToList . inferenceBlock) blocks
      declarations = [(ordinal, block) | (ordinal, block@InferenceBlock {blockKind = NotationBlock}) <- zip [1 ..] annotated]
      -- A full separator keeps a trailing lone CR in a block invalid.
      source = Text.concat [blockSource block <> "\r\n" | (_, block) <- declarations]
      origins = IntMap.fromDistinctAscList (snd (mapAccumL indexBlock 1 declarations))
  notations <- case parseNotationBlock source of
    Left diagnostic -> Left (formatNotationDiagnostic origins diagnostic)
    Right parsed -> Right parsed
  let parseSection = parseRuleSection notations
      render ordinal block = case blockKind block of
        NotationBlock -> Right (rawLatex (Text.unlines (map ("% " <>) (Text.lines (blockSource block)))))
        RuleBlock title -> case parseSection title (blockSource block) >>= \section -> renderLatex (Document notations [section]) of
          Left diagnostic ->
            let related sourceSpan = formatNotationDiagnostic origins diagnostic {diagnosticSpan = sourceSpan, diagnosticMessage = "Competing notation declared here."}
             in Left (formatBlockDiagnostic ordinal block diagnostic <> foldMap related (diagnosticRelated diagnostic))
          Right latex -> Right (rawLatex latex)
  Pandoc metadata <$> evalStateT (walkM (replaceBlock render) blocks) 1
  where
    rawLatex = RawBlock (Format "latex")
    indexBlock line entry@(_, block) = (line + Text.count "\n" (blockSource block) + 1, (line, entry))

inferenceBlock :: Block -> Maybe InferenceBlock
inferenceBlock (CodeBlock (identifier, classes, attributes) source)
  | "inference-notation" `elem` classes = Just (InferenceBlock identifier NotationBlock source)
  | "inference" `elem` classes = Just (InferenceBlock identifier (RuleBlock caption) source)
  where
    -- Pandoc's Org reader keeps the outer double quotes on a quoted value.
    caption = unquote <$> lookup "rule_set" attributes
    unquote value = case Text.stripPrefix "\"" value >>= Text.stripSuffix "\"" of
      Just content -> content
      Nothing -> value
inferenceBlock _ = Nothing

replaceBlock :: (Int -> InferenceBlock -> Either Text Block) -> Block -> StateT Int (Either Text) Block
replaceBlock render block = case inferenceBlock block of
  Nothing -> pure block
  Just input -> StateT $ \ordinal -> (,ordinal + 1) <$> render ordinal input

formatBlockDiagnostic :: Int -> InferenceBlock -> Diagnostic -> Text
formatBlockDiagnostic ordinal block diagnostic =
  reference <> ":" <> formatDiagnostic (blockSource block) diagnostic {diagnosticRelated = []}
  where
    reference
      | Text.null (blockId block) = "inference block " <> Text.pack (show ordinal)
      | otherwise = "inference block #" <> blockId block

formatNotationDiagnostic :: IntMap (Int, InferenceBlock) -> Diagnostic -> Text
formatNotationDiagnostic origins diagnostic =
  case IntMap.lookupLE (sourceLine (spanStart source)) origins of
    Just (firstLine, (ordinal, block)) ->
      let relative position = position {sourceLine = sourceLine position - firstLine + 1}
          localSpan = SourceSpan (relative (spanStart source)) (relative (spanEnd source))
       in formatBlockDiagnostic ordinal block diagnostic {diagnosticSpan = localSpan}
    Nothing -> formatDiagnostic "" diagnostic
  where
    source = diagnosticSpan diagnostic
