module Preview (compileJson) where

import Data.Aeson
import Data.Aeson.Types (Pair)
import Data.Bifunctor (first)
import Data.Functor.Identity (Identity (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.Lazy qualified as Lazy
import Data.Text.Lazy.Encoding qualified as LazyEncoding
import Inference.AST (Document (..), SourcePosition (..), SourceSpan (..))
import Inference.HTML (renderHtml, renderHtmlExpression)
import Inference.Modules (ModuleDiagnostic (..), NotationResolver, NotationSourceInput (..), loadNotationScope)
import Inference.Parser (Diagnostic (..), parseBlockAttributes, parseBlockSection, parseInlineExpression)
import Inference.Templates (templatesFor)
import System.FilePath.Posix (isAbsolute, takeDirectory, (</>))

data ItemKind = Notation | Block | Inline deriving (Eq)

data Item = Item
  { itemKey :: Text,
    itemKind :: ItemKind,
    itemPairs :: [(Text, Text)],
    itemSource :: Text
  }

instance FromJSON Item where
  parseJSON = withObject "item" $ \item -> do
    key <- item .: "key"
    kind <-
      item .: "kind" >>= \case
        "notation" -> pure Notation
        "block" -> pure Block
        "inline" -> pure Inline
        other -> fail ("Unknown item kind: " <> Text.unpack other)
    attr <- item .: "attr"
    Item key kind <$> attr .: "pairs" <*> item .: "source"

data Module = Module FilePath Text

instance FromJSON Module where
  parseJSON = withObject "module" $ \entry -> Module <$> entry .: "path" <*> entry .: "source"

data Request = Request Int [Item] [Module]

instance FromJSON Request where
  parseJSON = withObject "request" $ \request ->
    Request <$> request .: "revision" <*> request .: "items" <*> request .: "modules"

compileJson :: Text -> Text
compileJson input = Lazy.toStrict (LazyEncoding.decodeUtf8 (encode response))
  where
    response = case eitherDecodeStrict' (Encoding.encodeUtf8 input) of
      Left message -> failure Nothing (Text.pack message)
      Right (Request revision items modules) ->
        let keys = map itemKey items
         in if length keys /= Set.size (Set.fromList keys)
              then failure (Just revision) "Duplicate item key."
              else case traverse moduleEntry modules of
                Left message -> failure (Just revision) message
                Right entries
                  | Map.size (Map.fromList entries) /= length entries ->
                      failure (Just revision) "Duplicate module path."
                  | otherwise -> compile revision items (Map.fromList entries)
    failure :: Maybe Int -> Text -> Value
    failure revision message = object ["revision" .= revision, "status" .= ("error" :: Text), "message" .= message]
    moduleEntry (Module path source) = (,source) <$> normalizePath path

compile :: Int -> [Item] -> Map.Map FilePath Text -> Value
compile revision items modules =
  case result of
    Left diagnostic -> response "invalid" ["diagnostics" .= [diagnostic]]
    Right fragments -> response "ok" ["fragments" .= concat fragments]
  where
    response :: Text -> [Pair] -> Value
    response status fields = object (["revision" .= revision, "status" .= status] <> fields)
    declarations = [NotationSourceInput ("/item:" <> itemKey item) 0 (itemSource item) | item <- items, itemKind item == Notation]
    result = do
      (notations, templates, locate) <-
        first (moduleDiagnostic []) (runIdentity (loadNotationScope (resolveModule modules) declarations))
      let html = templatesFor "html" templates
          renderItem item = case itemKind item of
            Notation -> Right []
            kind ->
              let rendered = case kind of
                    Block -> do
                      options <- parseBlockAttributes (itemPairs item)
                      section <- parseBlockSection notations options (itemSource item)
                      renderHtml html (Document notations [section])
                    _ -> parseInlineExpression notations (itemSource item) >>= renderHtmlExpression html notations
                  report diagnostic =
                    diagnosticValue
                      (itemOrigin (itemKey item))
                      diagnostic
                      [ let ModuleDiagnostic source local = locate diagnostic {diagnosticSpan = span'}
                         in object ["message" .= ("Competing notation declared here." :: Text), "location" .= location (sourceOrigin source) (diagnosticSpan local)]
                      | span' <- diagnosticRelated diagnostic
                      ]
               in first report ((\fragment -> [object ["key" .= itemKey item, "html" .= fragment]]) <$> rendered)
      traverse renderItem items

resolveModule :: Map.Map FilePath Text -> NotationResolver Identity
resolveModule modules importer requested = pure $ do
  path <- normalizePath (maybe "" takeDirectory importer </> requested)
  Right (path, pure (maybe (Left "File not found.") Right (Map.lookup path modules)))

normalizePath :: FilePath -> Either Text FilePath
normalizePath path
  | isAbsolute path = Left "Expected a project-relative module path."
  | otherwise = do
      parts <- foldl' step (Right []) (Text.splitOn "/" (Text.pack path))
      case parts of
        [] -> Left "Expected a module path."
        _ -> Right (Text.unpack (Text.intercalate "/" (reverse parts)))
  where
    step previous part = do
      parts <- previous
      case part of
        "" -> Right parts
        "." -> Right parts
        ".." -> case parts of
          [] -> Left "Module path escapes the project root."
          _ : rest -> Right rest
        _ -> Right (part : parts)

moduleDiagnostic :: [Value] -> ModuleDiagnostic -> Value
moduleDiagnostic related (ModuleDiagnostic source diagnostic) =
  diagnosticValue (sourceOrigin source) diagnostic related

sourceOrigin :: NotationSourceInput -> Value
sourceOrigin source =
  case Text.stripPrefix "/item:" (notationSourceName source) of
    Just key -> itemOrigin key
    Nothing -> object ["module" .= notationSourceName source]

itemOrigin :: Text -> Value
itemOrigin key = object ["item" .= key]

diagnosticValue :: Value -> Diagnostic -> [Value] -> Value
diagnosticValue origin diagnostic related =
  object
    [ "code" .= show (diagnosticKind diagnostic),
      "message" .= diagnosticMessage diagnostic,
      "location" .= location origin (diagnosticSpan diagnostic),
      "related" .= related
    ]

location :: Value -> SourceSpan -> Value
location origin (SourceSpan start end) =
  object ["source" .= origin, "start" .= position start, "end" .= position end]
  where
    position (SourcePosition line column) = object ["line" .= line, "column" .= column]
