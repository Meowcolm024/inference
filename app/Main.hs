module Main (main) where

import Control.Applicative (optional, (<|>))
import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.LaTeX (compileSource)
import Inference.Pandoc (runFilter)
import Inference.Parser (formatDiagnostic)
import Options.Applicative (Parser, execParser, flag', footer, fullDesc, help, helper, info, long, metavar, progDesc, strArgument)
import System.Exit (exitFailure)
import System.IO (hSetBinaryMode, stderr, stdin, stdout)

main :: IO ()
main = do
  mode <-
    execParser $
      info
        (helper <*> modeParser)
        ( fullDesc
            <> progDesc "Filter Pandoc JSON from stdin. Convert inference blocks when FORMAT is latex."
            <> footer "Try pandoc --from=markdown --to=latex --filter=inference notes.md"
        )
  case mode of
    Filter target -> runFilter target
    Source -> runSource

data Mode = Filter (Maybe String) | Source

modeParser :: Parser Mode
modeParser =
  flag' Source (long "source" <> help "Rewrite inference environments in UTF-8 LaTeX from stdin.")
    <|> (Filter <$> optional (strArgument (metavar "FORMAT" <> help "Pandoc output format")))

runSource :: IO ()
runSource = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBinaryMode stderr True
  result <- try @IOException ByteString.getContents
  case result of
    Left failure -> failWith ("stdin: " <> Text.pack (show failure) <> "\n")
    Right bytes -> case Encoding.decodeUtf8' bytes of
      Left _ -> failWith "stdin: invalid UTF-8 input.\n"
      Right input -> case compileSource input of
        Left diagnostic -> failWith ("stdin:" <> formatDiagnostic input diagnostic)
        Right latex -> ByteString.hPut stdout (Encoding.encodeUtf8 latex)

failWith :: Text -> IO a
failWith message = do
  ByteString.hPut stderr (Encoding.encodeUtf8 message)
  exitFailure
