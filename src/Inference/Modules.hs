module Inference.Modules
  ( NotationSourceInput (..),
    ModuleDiagnostic (..),
    NotationResolver,
    formatModuleDiagnostic,
    loadNotationScope,
  )
where

import Control.Monad (foldM, guard)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Except (ExceptT, runExceptT, throwE)
import Data.Char (isSpace)
import Data.IntMap.Strict qualified as IntMap
import Data.List (intercalate, mapAccumL)
import Data.Maybe (listToMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser (parseNotationBlockWithTemplates)
import Inference.Parser.Source
import Inference.Templates (BackendTemplates)
import System.FilePath (isRelative)

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

-- The resolver receives the importing module identity, or Nothing for the host
-- document, and the requested relative path. Return a stable identity and a
-- read action so cycles and duplicate imports can be detected before reading.
type NotationResolver m = Maybe FilePath -> FilePath -> m (Either Text (FilePath, m (Either Text Text)))

-- The returned function maps declaration spans in the shared notation scope
-- back to their source. Expression spans already refer to the host document.
loadNotationScope ::
  (Monad m) =>
  NotationResolver m ->
  [NotationSourceInput] ->
  m (Either ModuleDiagnostic ([Notation], BackendTemplates, Diagnostic -> ModuleDiagnostic))
loadNotationScope resolve inputs = runExceptT $ do
  (_, sources) <- foldM (expand resolve []) (Set.empty, []) inputs
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
  forall m.
  (Monad m) =>
  NotationResolver m ->
  [FilePath] ->
  (Set FilePath, [(NotationSourceInput, NotationSourceInput)]) ->
  NotationSourceInput ->
  ExceptT ModuleDiagnostic m (Set FilePath, [(NotationSourceInput, NotationSourceInput)])
expand resolve chain initial source = do
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
              failure :: DiagnosticKind -> Text -> ExceptT ModuleDiagnostic m a
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
              missing :: FilePath -> Text -> ExceptT ModuleDiagnostic m a
              missing ending reason = failure MissingModule ("Cannot import " <> trace ending <> ". " <> reason)
          (canonical, readSource) <- lift (resolve (listToMaybe (reverse chain)) path) >>= either (missing path) pure
          if canonical `elem` chain
            then failure ImportCycle ("Notation import cycle: " <> trace canonical <> ".")
            else
              if Set.member canonical seen
                then pure (seen, loaded, "" : lines')
                else do
                  body <- lift readSource >>= either (missing canonical) pure
                  (nextSeen, nextLoaded) <-
                    expand
                      resolve
                      (chain ++ [canonical])
                      (Set.insert canonical seen, loaded)
                      (NotationSourceInput (Text.pack canonical) 0 body)
                  pure (nextSeen, nextLoaded, "" : lines')
      | otherwise = pure (seen, loaded, raw : lines')
