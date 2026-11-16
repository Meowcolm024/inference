module Wasm where

import Data.Text qualified as Text
import GHC.Wasm.Prim (JSString (..), fromJSString, toJSString)
import Preview (compileJson)

foreign export javascript "compilePreview" compilePreview :: JSString -> IO JSString

compilePreview :: JSString -> IO JSString
compilePreview = pure . toJSString . Text.unpack . compileJson . Text.pack . fromJSString
