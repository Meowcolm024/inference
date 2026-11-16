module ModuleTests (moduleTests) where

import Control.Monad.Trans.State.Strict (State, modify', runState)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.Content
import Inference.Export
import Inference.FileSystem (fileSystemResolver)
import Inference.HTML (HtmlTemplateMode (..))
import Inference.LaTeX (compileSourceWithImports, parseSourceWithImportTemplates)
import Inference.Modules (NotationResolver)
import Inference.Pandoc (compileDocumentWithImportOptions, compileDocumentWithImports)
import System.FilePath (normalise, takeDirectory, (</>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Pandoc.Definition (Block (..), Format (..), Inline (..), Pandoc (..), nullMeta)

moduleTests :: TestTree
moduleTests =
  testGroup
    "Notation modules"
    [ testCase "mock filesystem resolves nested imports and reads each identity once" $ do
        let files =
              Map.fromList
                [ ("nested/transitive.notation", "import \"./arrow.notation\""),
                  ("nested/arrow.notation", "infixr:60 \"→\" => \"\\to\"")
                ]
            input = source "import \"nested/transitive.notation\"\nimport \"./nested/arrow.notation\""
            (result, readsInReverse) = runState (compileSourceWithImports (mockResolver files) input) []
        reverse readsInReverse @?= ["nested/transitive.notation", "nested/arrow.notation"]
        case result of
          Right latex -> assertBool "renders the imported arrow" ("{A\\to B\\to C}" `Text.isInfixOf` latex)
          Left diagnostic -> assertFailure (Text.unpack diagnostic),
      testCase "source imports are transitive, forward, and deduplicated" $ do
        result <- compileSourceWithImports (fileSystemResolver root) (source "import \"nested/transitive.notation\"\nimport \"./arrow.notation\"")
        case result of
          Right latex -> assertBool "renders the imported arrow" ("{A\\to B\\to C}" `Text.isInfixOf` latex)
          Left diagnostic -> assertFailure (Text.unpack diagnostic),
      testCase "LaTeX source exposes ordered content with imported HTML templates" $ do
        result <- parseSourceWithImportTemplates (fileSystemResolver root) (source "import \"arrow.notation\"")
        case result of
          Left diagnostic -> assertFailure (Text.unpack diagnostic)
          Right (document, templates) -> do
            let content = sourceInference templates document
            map parsedKey (parsedItems content) @?= map OccurrenceKey [1, 2]
            case exportInference (Html UseHtmlTemplates) content of
              Right [fragment] -> do
                fragmentKey fragment @?= OccurrenceKey 1
                assertBool "uses the imported HTML template" ("<b>→</b>" `Text.isInfixOf` fragmentText fragment)
              other -> assertFailure (show other),
      testCase "Pandoc inline expressions use imported backend templates" $ do
        let document =
              Pandoc
                nullMeta
                [ Para [Code ("", ["inference"], []) "A → B"],
                  CodeBlock ("", ["inference-notation"], []) "import \"nested/transitive.notation\""
                ]
        rendered <- compileDocumentWithImports root (Format "html5") document
        rendered @?= Right (Pandoc nullMeta [Para [RawInline (Format "html") "<span style=\"font-style:normal\"><span style=\"font-style:italic\">A</span> <b>→</b> <span style=\"font-style:italic\">B</span></span>"], RawBlock (Format "html") ""]),
      testCase "HTML template opt-out applies to imported notation in blocks and inline expressions" $ do
        let document =
              Pandoc
                nullMeta
                [ CodeBlock ("", ["inference"], []) "────\nA → B",
                  Para [Code ("", ["inference"], []) "A → B"],
                  CodeBlock ("", ["inference-notation"], []) "import \"nested/transitive.notation\""
                ]
            compileIgnoring = compileDocumentWithImportOptions IgnoreHtmlTemplates root
        mapM_
          ( \target -> do
              rendered <- compileIgnoring (Format target) document
              case rendered of
                Right (Pandoc _ [RawBlock (Format "html") block, Para [RawInline (Format "html") inline], RawBlock _ ""]) ->
                  mapM_ (\fragment -> assertBool "uses the Unicode pattern" ("→" `Text.isInfixOf` fragment && not ("<b>" `Text.isInfixOf` fragment))) [block, inline]
                other -> assertFailure (show other)
          )
          ["html", "html4", "html5"]
        latex <- compileDocumentWithImports root (Format "latex") document
        compileIgnoring (Format "latex") document >>= (@?= latex)
        let invalid = Pandoc nullMeta [CodeBlock ("", ["inference-notation"], []) "infixr:60 \"→\"\n  html => missing"]
        validation <- compileIgnoring (Format "html5") invalid
        case validation of
          Left diagnostic -> assertBool "still validates template references" ("missing" `Text.isInfixOf` diagnostic)
          Right _ -> assertFailure "Expected an invalid template diagnostic.",
      testCase "cycles point at the closing import with the full chain" $ do
        result <- compileSourceWithImports (fileSystemResolver root) (source "import \"cycle.notation\"")
        case result of
          Left diagnostic ->
            assertBool "shows the cycle and source" $
              all (`Text.isInfixOf` diagnostic) ["nested/cycle.notation:1:1:", "Notation import cycle", " -> ", "import \"../cycle.notation\""]
          Right _ -> assertFailure "Expected an import cycle.",
      testCase "missing, malformed, and non-notation imports have source locations" $ do
        checkError "import \"missing.notation\"" "stdin:6:1: Cannot import"
        checkError "import \"/absolute.notation\"" "stdin:6:1: Expected import"
        checkError "import \"invalid.notation\"" "invalid.notation:1:1:",
      testCase "ambiguity reports local and imported declaration locations" $ do
        result <- compileSourceWithImports (fileSystemResolver root) (source "import \"arrow.notation\"\ninfixl:60 \"→\"")
        case result of
          Left diagnostic ->
            assertBool "shows both declarations" $
              all (`Text.isInfixOf` diagnostic) ["stdin:3:", "arrow.notation:1:1:", "stdin:7:1:"]
          Right _ -> assertFailure "Expected ambiguous notation."
    ]
  where
    root = "test/fixtures/modules"
    source declarations =
      "\\begin{inference}\n────\nA → B → C\n\\end{inference}\n\\begin{inference-notation}\n"
        <> declarations
        <> "\n\\end{inference-notation}\n"
    checkError declaration expected = do
      result <- compileSourceWithImports (fileSystemResolver root) (source declaration)
      case result of
        Left diagnostic -> assertBool (Text.unpack diagnostic) (expected `Text.isInfixOf` diagnostic)
        Right _ -> assertFailure "Expected an import diagnostic."

mockResolver :: Map.Map FilePath Text -> NotationResolver (State [FilePath])
mockResolver files importer requested =
  pure (Right (identity, readSource))
  where
    identity = normalise (maybe "." takeDirectory importer </> requested)
    readSource = do
      modify' (identity :)
      pure (maybe (Left "File not found.") Right (Map.lookup identity files))
