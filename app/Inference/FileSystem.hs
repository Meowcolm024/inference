module Inference.FileSystem (fileSystemResolver) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as Bytes
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.Modules (NotationResolver)
import System.Directory (canonicalizePath)
import System.FilePath (takeDirectory, (</>))

fileSystemResolver :: FilePath -> NotationResolver IO
fileSystemResolver root importer requested = do
  let base = maybe root takeDirectory importer
  result <- try @IOException (canonicalizePath (base </> requested))
  pure $ case result of
    Left failure -> Left (Text.pack (show failure))
    Right canonical -> Right (canonical, readSource canonical)
  where
    readSource canonical = do
      result <- try @IOException (Bytes.readFile canonical)
      pure $ case result of
        Left failure -> Left (Text.pack (show failure))
        Right bytes -> case Encoding.decodeUtf8' bytes of
          Left _ -> Left "Invalid UTF-8."
          Right source -> Right source
