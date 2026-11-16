module Inference.Pandoc (runFilter, compileDocument, compileDocumentFor, compileDocumentWithImports, compileDocumentWithImportOptions) where

import Control.Exception (ErrorCall (..), Handler (..), IOException, catches)
import Control.Monad.Trans.State.Strict (State, evalState, execState, modify', state)
import Data.Bifunctor (first)
import Data.Data (Data, gmapM)
import Data.IntMap.Strict qualified as IntMap
import Data.List (mapAccumL)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Typeable (eqT, (:~:) (Refl))
import Inference.AST (Notation, sectionTitle)
import Inference.Blocks (BlockCompilationError (..), BlockDiagnostic (..), InferenceBlock (..), InferenceBlockKind (..), parseBlockNotationScope)
import Inference.Content
import Inference.Export
import Inference.FileSystem (fileSystemResolver)
import Inference.HTML (HtmlTemplateMode (..))
import Inference.LaTeX (renderLatexMathBody)
import Inference.Modules (NotationSourceInput (..), formatModuleDiagnostic, loadNotationScope)
import Inference.Parser (Diagnostic (..), InferenceInput (..), formatDiagnostic, parseInferenceContent)
import Inference.Templates (BackendTemplates, templatesFor)
import System.Exit (die, exitFailure)
import System.IO (hSetBinaryMode, hSetEncoding, stderr, stdin, stdout, utf8)
import Text.Pandoc.JSON (Attr, Block (..), Format (..), Inline (..), MathType (..), Pandoc (..), toJSONFilter)

runFilter :: HtmlTemplateMode -> FilePath -> Maybe String -> IO ()
runFilter templateMode root target = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetEncoding stderr utf8
  toJSONFilter (filterDocument templateMode root (Format . Text.pack <$> target))
    `catches` [ Handler $ \(ErrorCall message) -> die ("inference: " <> message),
                Handler $ \(failure :: IOException) -> die ("inference: " <> show failure)
              ]

filterDocument :: HtmlTemplateMode -> FilePath -> Maybe Format -> Pandoc -> IO Pandoc
filterDocument _ _ Nothing document = pure document
filterDocument templateMode root (Just target) document = do
  result <- compileDocumentWithImportOptions templateMode root target document
  case result of
    Right rendered -> pure rendered
    Left message -> Text.hPutStr stderr message >> exitFailure

compileDocument :: Pandoc -> Either Text Pandoc
compileDocument = compileDocumentFor (Format "latex")

compileDocumentFor :: Format -> Pandoc -> Either Text Pandoc
compileDocumentFor = compileWithScope UseHtmlTemplates Nothing

compileDocumentWithImports :: FilePath -> Format -> Pandoc -> IO (Either Text Pandoc)
compileDocumentWithImports = compileDocumentWithImportOptions UseHtmlTemplates

compileDocumentWithImportOptions :: HtmlTemplateMode -> FilePath -> Format -> Pandoc -> IO (Either Text Pandoc)
compileDocumentWithImportOptions templateMode root target document@(Pandoc _ blocks)
  | Nothing <- targetExporter templateMode target = pure (Right document)
  | otherwise = do
      let sources =
            [ NotationSourceInput (blockReference ordinal block) 0 (blockSource block)
            | (ordinal, HostBlock block@InferenceBlock {blockKind = NotationBlock}) <- collectOccurrences blocks
            ]
      scope <- loadNotationScope (fileSystemResolver root) sources
      pure $ do
        (notations, templates, locate) <- either (Left . formatModuleDiagnostic) Right scope
        let related diagnostic =
              [ ImportedDiagnostic (locate diagnostic {diagnosticSpan = span', diagnosticMessage = "Competing notation declared here."})
              | span' <- diagnosticRelated diagnostic
              ]
        compileWithScope templateMode (Just (notations, templates, related)) target document

data HostOccurrence
  = HostBlock InferenceBlock
  | HostInline Attr Text

data Replacement
  = ReplaceBlock Block
  | ReplaceInline Inline

targetExporter :: HtmlTemplateMode -> Format -> Maybe ExportTarget
targetExporter templateMode (Format target)
  | target == "latex" = Just Mathpar
  | target `elem` ["org", "markdown"] = Just LatexMath
  | target `elem` ["html", "html4", "html5"] = Just (Html templateMode)
  | otherwise = Nothing

compileWithScope :: HtmlTemplateMode -> Maybe ([Notation], BackendTemplates, Diagnostic -> [BlockDiagnostic]) -> Format -> Pandoc -> Either Text Pandoc
compileWithScope templateMode scope target document@(Pandoc metadata blocks) =
  case targetExporter templateMode target of
    Just exporter -> compile exporter
    Nothing -> Right document
  where
    occurrences = collectOccurrences blocks
    origins = IntMap.fromDistinctAscList (zip [1 ..] occurrences)
    compile exporter = do
      (notations, templates, related) <- case scope of
        Just resolved -> Right resolved
        Nothing -> first formatCompilationError (parseBlockNotationScope [block | (_, HostBlock block) <- occurrences])
      let report (OccurrenceKey key, diagnostic) =
            let primary = diagnostic {diagnosticRelated = []}
                message = case IntMap.lookup key origins of
                  Just (ordinal, HostBlock block) -> formatBlockDiagnostic (BlockDiagnostic (Just (ordinal, block)) primary)
                  Just (ordinal, HostInline (identifier, _, _) source) ->
                    inlineReference ordinal identifier <> ":" <> formatDiagnostic source primary
                  Nothing -> formatDiagnostic "" primary
             in message <> foldMap formatBlockDiagnostic (related diagnostic)
      parsed <- first report (parseInferenceContent notations templates (map (hostInput . snd) occurrences))
      replacements <- traverse (render exporter parsed report) (zip (map snd occurrences) (parsedItems parsed))
      let keyed = IntMap.fromDistinctAscList replacements
      pure (Pandoc metadata (evalState (visitOccurrences (replace keyed) blocks) 1))

    render exporter parsed report (host, item) = do
      let key@(OccurrenceKey ordinal) = parsedKey item
      replacement <- first (report . (key,)) (renderOccurrence exporter parsed host item)
      pure (ordinal, replacement)

renderOccurrence :: ExportTarget -> ParsedInference -> HostOccurrence -> ParsedItem -> Either Diagnostic Replacement
renderOccurrence LatexMath parsed (HostBlock _) item =
  ReplaceBlock <$> case parsedContent item of
    ParsedSection section -> do
      math <- renderLatexMathBody (templatesFor "latex" (parsedTemplates parsed)) (parsedNotations parsed) section
      pure $ case math of
        Nothing -> Plain []
        Just body ->
          let display = Para [Math DisplayMath body]
           in case sectionTitle section of
                Nothing -> display
                Just title -> Div ("", [], []) [display, Para [Str title]]
    _ -> Right (Plain [])
renderOccurrence exporter parsed host item = do
  fragment <- exportItem exporter parsed item
  let markup = maybe "" fragmentText fragment
  pure $ case host of
    HostBlock block ->
      ReplaceBlock $ case exporter of
        Html _ -> keepHtmlAnchor block (RawBlock (Format "html") markup)
        _ -> RawBlock (Format "latex") $ case blockKind block of
          NotationBlock -> Text.unlines (map ("% " <>) (Text.lines (blockSource block)))
          RuleBlock _ -> markup
    HostInline (identifier, classes, attributes) _ ->
      let inline = case exporter of
            Html _ -> RawInline (Format "html") markup
            _ -> Math InlineMath markup
          remaining = (identifier, filter (/= "inference") classes, attributes)
       in ReplaceInline (if remaining == ("", [], []) then inline else Span remaining [inline])

hostInput :: HostOccurrence -> InferenceInput
hostInput (HostBlock block) = case blockKind block of
  NotationBlock -> NotationInput
  RuleBlock attributes -> SectionInput attributes (blockSource block)
hostInput (HostInline _ source) = InlineInput source

inlineReference :: Int -> Text -> Text
inlineReference ordinal identifier
  | Text.null identifier = "inference inline " <> Text.pack (show ordinal)
  | otherwise = "inference inline #" <> identifier

-- Keep the existing diagnostic ordinals for blocks and inlines while using
-- a single occurrence order across both kinds of host node.
collectOccurrences :: [Block] -> [(Int, HostOccurrence)]
collectOccurrences blocks =
  snd (mapAccumL number (1, 1) (reverse (execState (visitOccurrences collect blocks) [])))
  where
    collect occurrence = modify' (occurrence :) >> pure Nothing
    number (block, inline) occurrence = case occurrence of
      HostBlock _ -> ((block + 1, inline), (block, occurrence))
      HostInline _ _ -> ((block, inline + 1), (inline, occurrence))

replace :: IntMap.IntMap Replacement -> HostOccurrence -> State Int (Maybe Replacement)
replace replacements _ = state $ \key -> (IntMap.lookup key replacements, key + 1)

-- A single traversal sees inline nodes and blocks in notes, lists, tables,
-- and other containers in tree order. Marked code nodes are atomic.
visitOccurrences ::
  forall m a.
  (Monad m, Data a) =>
  (HostOccurrence -> m (Maybe Replacement)) ->
  a ->
  m a
visitOccurrences visit node
  | Just Refl <- eqT @a @Block,
    Just block <- inferenceBlock node = do
      replacement <- visit (HostBlock block)
      pure $ case replacement of
        Just (ReplaceBlock rendered) -> rendered
        _ -> node
  | Just Refl <- eqT @a @Inline,
    Code attr@(_, classes, _) source <- node,
    "inference" `elem` classes = do
      replacement <- visit (HostInline attr source)
      pure $ case replacement of
        Just (ReplaceInline rendered) -> rendered
        _ -> node
  | Just Refl <- eqT @a @Text = pure node
  | otherwise = gmapM (visitOccurrences visit) node

inferenceBlock :: Block -> Maybe InferenceBlock
inferenceBlock (CodeBlock (identifier, classes, attributes) source)
  | "inference-notation" `elem` classes = Just (InferenceBlock identifier NotationBlock source)
  | "inference" `elem` classes = Just (InferenceBlock identifier (RuleBlock attributes) source)
inferenceBlock _ = Nothing

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
