module TestSupport (oneRule, readFixture, readUtf8, parsed, parsedSource, sourceSections, sourceRules, at) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Inference.AST
import Inference.Parser
import System.IO (IOMode (ReadMode), hSetEncoding, utf8, withFile)
import Test.Tasty.HUnit (assertFailure)

oneRule :: [Text] -> Text -> Text
oneRule declarations expression =
  Text.unlines (["\\begin{inference-notation}"] ++ declarations ++ ["\\end{inference-notation}", "\\begin{inference}", "─", expression, "\\end{inference}"])

readFixture :: String -> IO Text
readFixture name = readUtf8 ("test/fixtures/" <> name <> ".rules")

readUtf8 :: FilePath -> IO Text
readUtf8 path = withFile path ReadMode $ \handle -> do
  hSetEncoding handle utf8
  Text.IO.hGetContents handle

parsed :: Text -> Either Diagnostic a -> IO a
parsed input result = case result of
  Right value -> pure value
  Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))

parsedSource :: Text -> IO SourceDocument
parsedSource input = parsed input (parseSource input)

sourceSections :: SourceDocument -> [Section]
sourceSections document = [section | RuleSetSource section <- sourceDocumentChunks document]

sourceRules :: SourceDocument -> [Rule]
sourceRules = concatMap sectionRules . sourceSections

at :: Int -> Int -> Int -> SourceSpan
at line start end = SourceSpan (SourcePosition line start) (SourcePosition line end)
