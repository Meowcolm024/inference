module FilterTests (filterTests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Inference.Pandoc (compileDocument, compileDocumentFor)
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
          Right _ -> assertFailure "Expected an ambiguity diagnostic.",
      testCase "HTML writers render all block kinds with inline styles" $ do
        let prose = Para [Str "Kept"]
            input =
              Pandoc
                (Meta (Map.singleton "title" (MetaString "Kept")))
                [ prose,
                  CodeBlock ("rule", ["inference"], [("rule_set", "Types & <terms>")]) "A < B\n──── Intro <&>\nA → B",
                  CodeBlock ("", ["inference"], []) "──── Base\nι",
                  CodeBlock ("", ["inference"], [("kind", "bnf")]) "--- Types & terms\nA ::= X\n  | X → X",
                  CodeBlock ("", ["inference"], [("kind", "equation")]) "x = y -- if x < y\n\nz = z",
                  CodeBlock ("", ["inference-notation"], []) "infixr:60 \"→\" => \"\\to\"\n  html => lhs \" <b>→</b> \" rhs\ninfix:50 \"<\""
                ]
            html = compileDocumentFor (Format "html5") input
        compileDocumentFor (Format "html") input @?= html
        compileDocumentFor (Format "html4") input @?= html
        compileDocumentFor (Format "docx") input @?= Right input
        case html of
          Right (Pandoc metadata [kept, Div ("rule", [], []) [RawBlock ruleFormat rule], RawBlock _ axiom, RawBlock _ bnf, RawBlock _ equation, RawBlock _ declaration]) -> do
            metadata @?= Meta (Map.singleton "title" (MetaString "Kept"))
            kept @?= prose
            ruleFormat @?= Format "html"
            assertBool "renders a labeled rule and escapes source text" (all (`Text.isInfixOf` rule) ["border-top:", "A &lt; B", "Intro &lt;&amp;&gt;", "<figcaption", "Types &amp; &lt;terms&gt;"])
            assertBool "uses the forward HTML template" ("A <b>→</b> B" `Text.isInfixOf` rule)
            assertBool "renders a Unicode axiom with a bar and label" (all (`Text.isInfixOf` axiom) ["border-top:", "ι", "Base"])
            assertBool "omits the axiom's empty premises row" (not ("grid-area:1/1" `Text.isInfixOf` axiom))
            assertBool "renders a named BNF table with a continuation row" (all (`Text.isInfixOf` bnf) ["<table", "Types &amp; terms", "::=", "<tr><td", "X <b>→</b> X"])
            Text.count "<tr>" bnf @?= 2
            assertBool "renders an equation guard and spacer row" (all (`Text.isInfixOf` equation) ["<table", "if x &lt; y", "colspan=\"4\""])
            declaration @?= ""
          other -> assertFailure (show other)
    ]
