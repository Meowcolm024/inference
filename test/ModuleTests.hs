module ModuleTests (moduleTests) where

import Data.Text qualified as Text
import Inference.LaTeX (compileSourceWithImports)
import Inference.Pandoc (compileDocumentWithImports)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Pandoc.Definition (Block (..), Format (..), Inline (..), Pandoc (..), nullMeta)

moduleTests :: TestTree
moduleTests =
  testGroup
    "Notation modules"
    [ testCase "source imports are transitive, forward, and deduplicated" $ do
        result <- compileSourceWithImports root (source "import \"nested/transitive.notation\"\nimport \"./arrow.notation\"")
        case result of
          Right latex -> assertBool "renders the imported arrow" ("{A\\to B\\to C}" `Text.isInfixOf` latex)
          Left diagnostic -> assertFailure (Text.unpack diagnostic),
      testCase "Pandoc inline expressions use imported backend templates" $ do
        let document =
              Pandoc
                nullMeta
                [ Para [Code ("", ["inference"], []) "A → B"],
                  CodeBlock ("", ["inference-notation"], []) "import \"nested/transitive.notation\""
                ]
        rendered <- compileDocumentWithImports root (Format "html5") document
        rendered @?= Right (Pandoc nullMeta [Para [RawInline (Format "html") "A <b>→</b> B"], RawBlock (Format "html") ""]),
      testCase "cycles point at the closing import with the full chain" $ do
        result <- compileSourceWithImports root (source "import \"cycle.notation\"")
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
        result <- compileSourceWithImports root (source "import \"arrow.notation\"\ninfixl:60 \"→\"")
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
      result <- compileSourceWithImports root (source declaration)
      case result of
        Left diagnostic -> assertBool (Text.unpack diagnostic) (expected `Text.isInfixOf` diagnostic)
        Right _ -> assertFailure "Expected an import diagnostic."
