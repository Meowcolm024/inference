module Inference.Pandoc (runFilter, compileDocument, compileDocumentFor, compileDocumentWithImports) where

import Control.Exception (ErrorCall (..), Handler (..), IOException, catches)
import Control.Monad.Trans.State.Strict (State, StateT (..), evalState, evalStateT, state)
import Data.Maybe (maybeToList)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Inference.AST (Expr, Notation)
import Inference.Blocks (BlockCompilationError (..), BlockDiagnostic (..), InferenceBlock (..), InferenceBlockKind (..), compileBlocksInScope, compileBlocksWithContext)
import Inference.HTML (renderHtml, renderHtmlExpression)
import Inference.LaTeX (renderLatex, renderLatexExpression)
import Inference.Modules (NotationSourceInput (..), formatModuleDiagnostic, loadNotationScope)
import Inference.Parser (Diagnostic (..), formatDiagnostic, parseInlineExpression)
import Inference.Templates (BackendTemplates, templatesFor)
import System.Exit (die, exitFailure)
import System.IO (hSetBinaryMode, hSetEncoding, stderr, stdin, stdout, utf8)
import Text.Pandoc.JSON (Block (..), Format (..), Inline (..), MathType (..), Pandoc (..), toJSONFilter)
import Text.Pandoc.Walk (query, walkM)

runFilter :: FilePath -> Maybe String -> IO ()
runFilter root target = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetEncoding stderr utf8
  toJSONFilter (filterDocument root (Format . Text.pack <$> target))
    `catches` [ Handler $ \(ErrorCall message) -> die ("inference: " <> message),
                Handler $ \(failure :: IOException) -> die ("inference: " <> show failure)
              ]

filterDocument :: FilePath -> Maybe Format -> Pandoc -> IO Pandoc
filterDocument _ Nothing document = pure document
filterDocument root (Just target) document = do
  result <- compileDocumentWithImports root target document
  case result of
    Right rendered -> pure rendered
    Left message -> Text.hPutStr stderr message >> exitFailure

compileDocument :: Pandoc -> Either Text Pandoc
compileDocument = compileDocumentFor (Format "latex")

compileDocumentFor :: Format -> Pandoc -> Either Text Pandoc
compileDocumentFor = compileWithScope Nothing

compileDocumentWithImports :: FilePath -> Format -> Pandoc -> IO (Either Text Pandoc)
compileDocumentWithImports root target@(Format name) document@(Pandoc _ blocks)
  | name `notElem` ["latex", "html", "html4", "html5"] = pure (Right document)
  | otherwise = do
      let sources =
            [ NotationSourceInput (blockReference ordinal block) 0 (blockSource block)
            | (ordinal, block@InferenceBlock {blockKind = NotationBlock}) <- zip [1 ..] (query (maybeToList . inferenceBlock) blocks)
            ]
      scope <- loadNotationScope root sources
      pure $ do
        (notations, templates, locate) <- either (Left . formatModuleDiagnostic) Right scope
        let related diagnostic =
              [ ImportedDiagnostic (locate diagnostic {diagnosticSpan = span', diagnosticMessage = "Competing notation declared here."})
              | span' <- diagnosticRelated diagnostic
              ]
        compileWithScope (Just (notations, templates, related)) target document

compileWithScope :: Maybe ([Notation], BackendTemplates, Diagnostic -> [BlockDiagnostic]) -> Format -> Pandoc -> Either Text Pandoc
compileWithScope scope (Format target) document@(Pandoc metadata blocks)
  | target == "latex" =
      compile
        renderDeclaration
        (\templates input -> rawLatex <$> renderLatex (templatesFor "latex" templates) input)
        (\templates notations expression -> Math InlineMath <$> renderLatexExpression (templatesFor "latex" templates) notations expression)
  | target `elem` ["html", "html4", "html5"] =
      compile
        (const (rawHtml ""))
        (\templates input -> rawHtml <$> renderHtml (templatesFor "html" templates) input)
        (\templates notations expression -> RawInline (Format "html") <$> renderHtmlExpression (templatesFor "html" templates) notations expression)
  | otherwise = Right document
  where
    compile declaration rules renderExpression = do
      (rendered, expressions) <-
        either (Left . formatCompilationError) Right $
          let inputs = query (maybeToList . inferenceBlock) blocks
           in case scope of
                Nothing -> compileBlocksWithContext declaration rules compileInlines inputs
                Just resolved -> compileBlocksInScope declaration rules compileInlines resolved inputs
      withInlines <- expressions
      pure (Pandoc metadata (evalState (walkM replaceBlock withInlines) rendered))
      where
        compileInlines notations templates related =
          evalStateT (walkM (replaceInline notations (renderExpression templates notations) related) blocks) 1
    rawLatex = RawBlock (Format "latex")
    rawHtml = RawBlock (Format "html")
    renderDeclaration = rawLatex . Text.unlines . map ("% " <>) . Text.lines

inferenceBlock :: Block -> Maybe InferenceBlock
inferenceBlock (CodeBlock (identifier, classes, attributes) source)
  | "inference-notation" `elem` classes = Just (InferenceBlock identifier NotationBlock source)
  | "inference" `elem` classes = Just (InferenceBlock identifier (RuleBlock attributes) source)
inferenceBlock _ = Nothing

replaceInline ::
  [Notation] ->
  (Expr -> Either Diagnostic Inline) ->
  (Diagnostic -> [BlockDiagnostic]) ->
  Inline ->
  StateT Int (Either Text) Inline
replaceInline notations render related (Code (identifier, classes, attributes) source)
  | "inference" `elem` classes = StateT $ \ordinal ->
      case parseInlineExpression notations source >>= render of
        Left diagnostic ->
          let reference
                | Text.null identifier = "inference inline " <> Text.pack (show ordinal)
                | otherwise = "inference inline #" <> identifier
              primary = reference <> ":" <> formatDiagnostic source diagnostic {diagnosticRelated = []}
           in Left (primary <> foldMap formatBlockDiagnostic (related diagnostic))
        Right rendered ->
          let remaining = (identifier, filter (/= "inference") classes, attributes)
              replacement = if remaining == ("", [], []) then rendered else Span remaining [rendered]
           in Right (replacement, ordinal + 1)
replaceInline _ _ _ inline = pure inline

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
formatBlockDiagnostic (ImportedDiagnostic diagnostic) = formatModuleDiagnostic diagnostic
formatBlockDiagnostic (BlockDiagnostic (Just (ordinal, block)) diagnostic) =
  blockReference ordinal block <> ":" <> formatDiagnostic (blockSource block) diagnostic

blockReference :: Int -> InferenceBlock -> Text
blockReference ordinal block
  | Text.null (blockId block) = "inference block " <> Text.pack (show ordinal)
  | otherwise = "inference block #" <> blockId block
