module Main (main) where

import Control.Applicative (optional, (<|>))
import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.LaTeX (compileSourceWithImports)
import Inference.Pandoc (runFilter)
import Options.Applicative (Parser, execParser, flag', footer, fullDesc, help, helper, info, long, metavar, progDesc, strArgument, strOption, value)
import System.Exit (exitFailure)
import System.IO (hSetBinaryMode, stderr, stdin, stdout)

main :: IO ()
main = do
  (mode, root) <-
    execParser $
      info
        (helper <*> ((,) <$> modeParser <*> moduleRootParser))
        ( fullDesc
            <> progDesc "Filter Pandoc JSON from stdin. Convert inference blocks for LaTeX and HTML writers."
            <> footer "Try pandoc --from=markdown --to=latex --filter=inference notes.md"
        )
  case mode of
    Filter target -> runFilter root target
    Source -> runSource root

data Mode = Filter (Maybe String) | Source

modeParser :: Parser Mode
modeParser =
  flag' Source (long "source" <> help "Rewrite inference environments in UTF-8 LaTeX from stdin.")
    <|> (Filter <$> optional (strArgument (metavar "FORMAT" <> help "Pandoc output format")))

moduleRootParser :: Parser FilePath
moduleRootParser =
  strOption (long "module-root" <> metavar "DIRECTORY" <> value "." <> help "Resolve document notation imports relative to this directory (default: current directory).")

runSource :: FilePath -> IO ()
runSource root = do
  hSetBinaryMode stdin True
  hSetBinaryMode stdout True
  hSetBinaryMode stderr True
  result <- try @IOException ByteString.getContents
  case result of
    Left failure -> failWith ("stdin: " <> Text.pack (show failure) <> "\n")
    Right bytes -> case Encoding.decodeUtf8' bytes of
      Left _ -> failWith "stdin: invalid UTF-8 input.\n"
      Right input -> do
        compiled <- compileSourceWithImports root input
        case compiled of
          Left message -> failWith message
          Right latex -> ByteString.hPut stdout (Encoding.encodeUtf8 latex)

failWith :: Text -> IO a
failWith message = do
  ByteString.hPut stderr (Encoding.encodeUtf8 message)
  exitFailure
