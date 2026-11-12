module FilterTests (filterTests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Inference.Pandoc (compileDocument)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Pandoc.Definition (Block (..), Format (..), Inline (..), Meta (..), MetaValue (..), Pandoc (..), nullMeta)

filterTests :: TestTree
filterTests =
  testGroup
    "Pandoc block kinds"
    [ testCase "mixed kinds share forward notation and retain surrounding blocks" $ do
        let metadata = Meta (Map.singleton "title" (MetaString "Kept"))
            before = Para [Str "Before"]
            after = Para [Str "After"]
            input =
              Pandoc
                metadata
                [ before,
                  CodeBlock ("syntax", ["inference"], [("kind", "bnf"), ("rule_set", "Types")]) "--- Types\nA ::= X | X → X",
                  CodeBlock ("equation", ["inference"], [("kind", "\"equation\"")]) "ι = y -- if x ≠ y",
                  CodeBlock ("", ["inference"], []) "─\nx",
                  CodeBlock ("", ["inference-notation"], []) "infixr:60 \"→\"\ninfix:53 \"≠\" => \"\\ne\"",
                  after
                ]
        case compileDocument input of
          Right (Pandoc actualMeta [actualBefore, RawBlock firstFormat bnf, RawBlock secondFormat equation, RawBlock _ rule, RawBlock _ declaration, actualAfter]) -> do
            actualMeta @?= metadata
            actualBefore @?= before
            actualAfter @?= after
            firstFormat @?= Format "latex"
            secondFormat @?= Format "latex"
            assertBool "renders BNF with its caption and forward arrow" (Text.isInfixOf "\\begin{array}{l}" bnf && Text.isInfixOf "\\caption{Types}" bnf && Text.isInfixOf "\\to" bnf)
            assertBool "renders the equation with its explicit guard template" (Text.isInfixOf "\\iota & = & y & \\mbox{if}\\;x\\ne y" equation)
            assertBool "defaults to inference rules" (Text.isInfixOf "\\inferrule" rule)
            assertBool "keeps notation comments" (Text.isPrefixOf "% infixr" declaration)
          other -> assertFailure (show other),
      testCase "notation clauses cannot attach across Pandoc blocks" $ do
        let input =
              Pandoc
                nullMeta
                [ CodeBlock ("first", ["inference-notation"], []) "notation:5 \"a\"",
                  CodeBlock ("orphan", ["inference-notation"], []) "  latex => \"b\""
                ]
        case compileDocument input of
          Left diagnostic ->
            assertBool "identifies the orphan clause" (Text.isPrefixOf "inference block #orphan:1:3:" diagnostic)
          Right _ -> assertFailure "Expected a misplaced template diagnostic.",
      testCase "kind errors include the Pandoc block identity" $ do
        let input = Pandoc nullMeta [CodeBlock ("bad", ["inference"], [("kind", "unknown")]) "x"]
        case compileDocument input of
          Left diagnostic -> assertBool "identifies the option and block" (Text.isInfixOf "inference block #bad" diagnostic && Text.isInfixOf "Unknown block kind ‘unknown’" diagnostic)
          Right _ -> assertFailure "Expected a kind diagnostic.",
      testCase "equation errors retain block-relative spans" $ do
        let input = Pandoc nullMeta [CodeBlock ("", ["inference"], [("kind", "equation")]) "x = y\n--- Bad"]
        case compileDocument input of
          Left diagnostic -> assertBool "reports the row and column" (Text.isPrefixOf "inference block 1:2:1:" diagnostic)
          Right _ -> assertFailure "Expected an equation diagnostic.",
      testCase "ambiguity identifies competing declarations in separate blocks" $ do
        let input =
              Pandoc
                nullMeta
                [ CodeBlock ("rule", ["inference"], []) "────\nA → B → C",
                  BlockQuote [CodeBlock ("left", ["inference-notation"], []) "\ninfixl:60 \"→\""],
                  CodeBlock ("right", ["inference-notation"], []) "infixr:60 \"→\""
                ]
        case compileDocument input of
          Left diagnostic -> do
            assertBool "locates the ambiguous rule" (Text.isPrefixOf "inference block #rule:2:" diagnostic)
            assertBool "locates the nested declaration" (Text.isInfixOf "inference block #left:2:1: Competing notation declared here." diagnostic)
            assertBool "locates the later declaration" (Text.isInfixOf "inference block #right:1:1: Competing notation declared here." diagnostic)
          Right _ -> assertFailure "Expected an ambiguity diagnostic."
    ]
