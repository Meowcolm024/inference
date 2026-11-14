module FilterTests (filterTests) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Inference.Pandoc (compileDocument, compileDocumentFor)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Pandoc.Definition (Block (..), Format (..), Inline (..), MathType (..), Meta (..), MetaValue (..), Pandoc (..), nullMeta)

filterTests :: TestTree
filterTests =
  testGroup
    "Pandoc filter"
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
      testCase "display expression blocks render directly in LaTeX and HTML" $ do
        let input =
              Pandoc
                nullMeta
                [ CodeBlock ("identity", ["inference"], [("kind", "expr")]) "ι → ι",
                  CodeBlock ("", ["inference-notation"], []) "infixr:60 \"→\"\n  html => lhs \" <b>→</b> \" rhs"
                ]
        case compileDocument input of
          Right (Pandoc _ [RawBlock (Format "latex") display, RawBlock _ _]) ->
            display @?= "\\[\n\\iota\\to\\iota\n\\]\n"
          other -> assertFailure (show other)
        case compileDocumentFor (Format "html5") input of
          Right (Pandoc _ [Div ("identity", [], []) [RawBlock (Format "html") display], RawBlock _ _]) ->
            assertBool "renders a centered expression using the HTML override" $
              all (`Text.isInfixOf` display) ["text-align:center", "font-style:normal", "ι <b>→</b> ι"]
          other -> assertFailure (show other),
      testCase "inline expressions use forward notation and keep surrounding prose and attributes" $ do
        let source = "infixr:60 \"→\"\n  latex => lhs \"\\Rightarrow \" rhs\n  html => lhs \" <b>→</b> \" rhs\ninfix:50 \"<\""
            ordinaryCode = Code ("", [], []) "A → B"
            declaration = CodeBlock ("", ["inference-notation"], []) source
            paragraph expressions = Para [Str "Type", Space, ordinaryCode, Space, Emph expressions]
            attr = ("type", ["highlight"], [("data-note", "type")])
            input =
              Pandoc
                nullMeta
                [ paragraph
                    [ Code ("type", ["highlight", "inference"], [("data-note", "type")]) "ι → B",
                      Space,
                      Code ("", ["inference"], []) "A < B"
                    ],
                  declaration
                ]
        case compileDocument input of
          Right (Pandoc _ [prose, RawBlock (Format "latex") _]) ->
            prose @?= paragraph [Span attr [Math InlineMath "\\iota\\Rightarrow B"], Space, Math InlineMath "A<B"]
          other -> assertFailure (show other)
        compileDocumentFor (Format "html5") input
          @?= Right
            ( Pandoc
                nullMeta
                [ paragraph [Span attr [RawInline (Format "html") "<span style=\"font-style:normal\">ι <b>→</b> <span style=\"font-style:italic\">B</span></span>"], Space, RawInline (Format "html") "<span style=\"font-style:normal\"><span style=\"font-style:italic\">A</span> &lt; <span style=\"font-style:italic\">B</span></span>"],
                  RawBlock (Format "html") ""
                ]
            )
        compileDocumentFor (Format "docx") input @?= Right input,
      testCase "inline diagnostics retain spans and competing block locations" $ do
        let input =
              Pandoc
                nullMeta
                [ Para [Code ("", ["inference"], []) "ι", Code ("use", ["inference"], []) "A → B → C"],
                  CodeBlock ("left", ["inference-notation"], []) "infixl:60 \"→\"",
                  CodeBlock ("right", ["inference-notation"], []) "infixr:60 \"→\""
                ]
        case compileDocument input of
          Left diagnostic -> do
            assertBool "identifies the inline code and shows its source" $
              "inference inline #use:1:" `Text.isPrefixOf` diagnostic && "A → B → C" `Text.isInfixOf` diagnostic
            assertBool "locates both declarations" $
              all (`Text.isInfixOf` diagnostic) ["inference block #left:1:1:", "inference block #right:1:1:"]
          Right _ -> assertFailure "Expected an inline ambiguity diagnostic.",
      testCase "inline code accepts expressions only" $ do
        let inline source = Para [Code ("", ["inference"], []) source]
            checkBad source =
              case compileDocument (Pandoc nullMeta [inline "ι", inline source]) of
                Left diagnostic -> assertBool "identifies the second marked inline" ("inference inline 2:1:" `Text.isPrefixOf` diagnostic)
                Right _ -> assertFailure ("Expected an inline diagnostic for " <> Text.unpack source)
        mapM_ checkBad ["notation:30 \"op\"", "A ::= B", "x = y -- if p", "──── R\nx"],
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
                  CodeBlock ("", ["inference"], []) "──── Base\nx2ι",
                  CodeBlock ("", ["inference"], [("kind", "bnf")]) "--- Types & terms\nA ::= X | Y\n  | X → X",
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
            assertBool "renders a labeled rule and escapes source text" (all (`Text.isInfixOf` rule) ["justify-content:center;align-items:center", "border-top:", "<span style=\"font-style:italic\">A</span> &lt; <span style=\"font-style:italic\">B</span>", "Intro &lt;&amp;&gt;", "<figcaption", "Types &amp; &lt;terms&gt;"])
            assertBool "uses the forward HTML template" ("<span style=\"font-style:italic\">A</span> <b>→</b> <span style=\"font-style:italic\">B</span>" `Text.isInfixOf` rule)
            assertBool "renders a Unicode axiom with a bar and label" (all (`Text.isInfixOf` axiom) ["border-top:", "<span style=\"font-style:italic\">x2</span>ι", "Base"])
            assertBool "omits the axiom's empty premises row" (not ("grid-area:1/1" `Text.isInfixOf` axiom))
            assertBool "renders a named BNF table with a continuation row" (all (`Text.isInfixOf` bnf) ["<table", "margin:.5em auto", "Types &amp; terms", "::=", "<tr><td", "<span style=\"font-style:italic\">X</span> <b>→</b> <span style=\"font-style:italic\">X</span>"])
            assertBool "adds spacing around both BNF separators" (all (`Text.isInfixOf` bnf) ["padding-inline:2pt\">::=</span>", "padding-inline:2pt\">|</span>"])
            Text.count "<tr>" bnf @?= 2
            assertBool "renders an equation guard and spacer row" (all (`Text.isInfixOf` equation) ["<table", "margin:.5em auto", "if <span style=\"font-style:normal\"><span style=\"font-style:italic\">x</span> &lt; <span style=\"font-style:italic\">y</span></span>", "colspan=\"4\""])
            declaration @?= ""
          other -> assertFailure (show other)
    ]
