module Inference.Modules
  ( NotationSourceInput (..),
    ModuleDiagnostic (..),
    formatModuleDiagnostic,
    loadNotationScope,
  )
where

import Control.Exception (IOException, try)
import Control.Monad (foldM, guard)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.ByteString qualified as Bytes
import Data.Char (isSpace)
import Data.IntMap.Strict qualified as IntMap
import Data.List (intercalate, mapAccumL)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.AST
import Inference.Parser (parseNotationBlockWithTemplates)
import Inference.Parser.Source
import Inference.Templates (BackendTemplates)
import System.Directory (canonicalizePath)
import System.FilePath (isRelative, takeDirectory, (</>))

data NotationSourceInput = NotationSourceInput
  { notationSourceName :: Text,
    notationSourceOffset :: Int,
    notationSourceText :: Text
  }
  deriving (Eq, Show)

data ModuleDiagnostic = ModuleDiagnostic NotationSourceInput Diagnostic
  deriving (Eq, Show)

formatModuleDiagnostic :: ModuleDiagnostic -> Text
formatModuleDiagnostic (ModuleDiagnostic source diagnostic) =
  notationSourceName source <> ":" <> formatDiagnostic (notationSourceText source) diagnostic

-- The returned function maps declaration spans in the shared notation scope
-- back to their source. Expression spans already refer to the host document.
loadNotationScope ::
  FilePath ->
  [NotationSourceInput] ->
  IO (Either ModuleDiagnostic ([Notation], BackendTemplates, Diagnostic -> ModuleDiagnostic))
loadNotationScope root inputs = runExceptT $ do
  (_, sources) <- foldM (expand root []) (Set.empty, []) inputs
  let ordered = reverse sources
      merged = Text.concat [notationSourceText source <> "\r\n\n" | (source, _) <- ordered]
      origins = IntMap.fromDistinctAscList (snd (mapAccumL indexSource 1 ordered))
      locate diagnostic =
        let span' = diagnosticSpan diagnostic
         in case IntMap.lookupLE (sourceLine (spanStart span')) origins of
              Just (start, (source, original)) ->
                let shift pos = pos {sourceLine = sourceLine pos - start + 1 + notationSourceOffset source}
                 in ModuleDiagnostic original diagnostic {diagnosticSpan = SourceSpan (shift (spanStart span')) (shift (spanEnd span')), diagnosticRelated = []}
              Nothing -> ModuleDiagnostic (NotationSourceInput "notation" 0 "") diagnostic
  case parseNotationBlockWithTemplates merged of
    Left diagnostic -> throwE (locate diagnostic)
    Right (notations, templates) -> pure (notations, templates, locate)
  where
    indexSource start entry@(source, _) =
      (start + Text.count "\n" (notationSourceText source) + 2, (start, entry))

expand ::
  FilePath ->
  [FilePath] ->
  (Set FilePath, [(NotationSourceInput, NotationSourceInput)]) ->
  NotationSourceInput ->
  ExceptT ModuleDiagnostic IO (Set FilePath, [(NotationSourceInput, NotationSourceInput)])
expand base chain initial source = do
  (seen, loaded, lines') <- foldM visit (fst initial, snd initial, []) (zip [1 ..] (Text.splitOn "\n" (notationSourceText source)))
  let cleaned = source {notationSourceText = Text.intercalate "\n" (reverse lines')}
  pure (seen, (cleaned, source) : loaded)
  where
    visit (seen, loaded, lines') (number, raw)
      | (keyword, suffix) <- Text.span identifierContinue (Text.stripStart raw),
        keyword == "import",
        not ("=>" `Text.isPrefixOf` Text.stripStart suffix) = do
          let line = number + notationSourceOffset source
              column = Text.length raw - Text.length (Text.stripStart raw) + 1
              span' = lineSpan (SourcePosition line column) 0 (Text.length (Text.strip raw))
              failure :: DiagnosticKind -> Text -> ExceptT ModuleDiagnostic IO a
              failure kind message = throwE (ModuleDiagnostic source (Diagnostic kind span' message []))
              request = do
                guard (maybe False (isSpace . fst) (Text.uncons suffix))
                quoted <- Text.stripPrefix "\"" (Text.strip suffix)
                path <- Text.stripSuffix "\"" quoted
                guard (not (Text.null path) && Text.all (`notElem` ['"', '\0', '\r']) path)
                guard (isRelative (Text.unpack path))
                pure (Text.unpack path)
          path <- maybe (failure MalformedImport "Expected import with a nonempty quoted relative path.") pure request
          let trace ending = Text.pack (intercalate " -> " (chain ++ [ending]))
              missing :: FilePath -> Text -> ExceptT ModuleDiagnostic IO a
              missing ending reason = failure MissingModule ("Cannot import " <> trace ending <> ". " <> reason)
          canonical <- lift (try @IOException (canonicalizePath (base </> path))) >>= either (missing path . Text.pack . show) pure
          if canonical `elem` chain
            then failure ImportCycle ("Notation import cycle: " <> trace canonical <> ".")
            else
              if Set.member canonical seen
                then pure (seen, loaded, "" : lines')
                else do
                  bytes <- lift (try @IOException (Bytes.readFile canonical)) >>= either (missing canonical . Text.pack . show) pure
                  body <- either (const (missing canonical "Invalid UTF-8.")) pure (Encoding.decodeUtf8' bytes)
                  (nextSeen, nextLoaded) <-
                    expand
                      (takeDirectory canonical)
                      (chain ++ [canonical])
                      (Set.insert canonical seen, loaded)
                      (NotationSourceInput (Text.pack canonical) 0 body)
                  pure (nextSeen, nextLoaded, "" : lines')
      | otherwise = pure (seen, loaded, raw : lines')
