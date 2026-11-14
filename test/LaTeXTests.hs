module LaTeXTests (latexTests) where

import Data.ByteString.Lazy qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.AST
import Inference.FileSystem (fileSystemResolver)
import Inference.LaTeX (compileSource, compileSourceWithImports, renderLatex)
import Inference.Parser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TestSupport

latexTests :: TestTree
latexTests =
  testGroup
    "LaTeX"
    [ golden "axioms, labels, grouping, scripts, and template substitution" "test/fixtures/latex/features.rules" "features",
      golden "BNF groups and continuation alignment" "test/fixtures/latex/bnf.rules" "bnf",
      golden "aligned equations and guards" "test/fixtures/latex/equations.rules" "equations",
      golden "untyped lambda calculus" "example/untyped-lambda.tex" "untyped-lambda",
      goldenWith (compileSourceWithImports (fileSystemResolver ".")) "simply typed lambda calculus" "example/stlc.tex" "stlc",
      golden "section order, omitted empty sections, and caption escaping" "test/fixtures/latex/sections.rules" "sections",
      testCase "infix and mixfix default to pattern order with Unicode mapping and escaping" $ do
        let input = oneRule ["infixr:60 \"→\"", "notation:50 Γ:51 \"⊢\" e:51 \":\" A:51"] "Γ ⊢ e₁ : ι → A_name"
        output <- parsed input (compileSource input)
        assertBool "maps atom and notation characters and escapes the underscore" $
          Text.isInfixOf "{\\Gamma\\vdash e_{1}:\\iota\\to A\\_name}" output,
      testCase "maps directional arrows and PLFA reduction notation" $ do
        let input =
              oneRule
                [ "infix:20 \"↖\"",
                  "infix:20 \"⇓\"",
                  "infix:20 \"←—\"",
                  "infix:20 \"—↠\"",
                  "infix:20 \"↞—\"",
                  "infix:20 \"⟺\""
                ]
                "(a ↖ b) (c ⇓ d) (e ←— f) (g —↠ h) (i ↞— j) (k ⟺ l)"
        output <- parsed input (compileSource input)
        assertBool "maps each complete arrow literal" $
          all
            (`Text.isInfixOf` output)
            [ "a\\nwarrow b",
              "c\\Downarrow d",
              "e\\longleftarrow f",
              "g\\mathrel{\\relbar\\joinrel\\twoheadrightarrow}h",
              "i\\mathrel{\\twoheadleftarrow\\joinrel\\relbar}j",
              "k\\Longleftrightarrow l"
            ],
      testCase "maps Unicode double brackets and preserves ASCII brackets" $ do
        let input =
              oneRule
                [ "notation:30 \"[[\" e:0 \"]]\"",
                  "notation:30 \"⟦\" e:0 \"⟧\"",
                  "notation:30 \"[\" e:0 \"]\""
                ]
                "([[ x ]]) (⟦ x ⟧) ([ [ x ] ])"
        output <- parsed input (compileSource input)
        assertBool "maps only the Unicode double brackets" $
          Text.isInfixOf "\\left([[x]]\\right)\\,\\left(\\llbracket x\\rrbracket\\right)\\,\\left([[x]]\\right)" output,
      testCase "maps blackboard-bold identifiers, primes, and PLFA operators" $ do
        let input =
              oneRule
                [ "infixr:20 \"⊎\"",
                  "infix:10 \"⦂\"",
                  "notation:30 \"ƛ\" x:atom \"·\" e:30"
                ]
                "ƛ 𝕒″ · ℰ ⦂ ℕ₁ ⊎ 𝔹"
        output <- parsed input (compileSource input)
        assertBool "renders scripts on the blackboard-bold base and maps notation literals" $
          Text.isInfixOf "{\\lambda\\,\\mathbb{a}^{\\prime\\prime}\\cdot\\mathcal{E}\\mathrel{:}\\mathbb{N}_{1}\\uplus\\mathbb{B}}" output,
      testCase "explicit templates override rendering without changing the expression AST" $ do
        let automatic = oneRule ["infixr:60 \"→\"", "notation:10 e:11 \"term\""] "ι → A term"
            explicit = oneRule ["infixr:60 \"→\" => \"\\Rightarrow\"", "notation:10 e:11 \"term\" => \"\\mathsf{term}(\" e \")\""] "ι → A term"
        defaultAst <- parsedSource automatic
        explicitAst <- parsedSource explicit
        sourceRules defaultAst @?= sourceRules explicitAst
        defaultOutput <- parsed automatic (compileSource automatic)
        explicitOutput <- parsed explicit (compileSource explicit)
        assertBool "spaces the postfix literal in the default layout" (Text.isInfixOf "{\\iota\\to A\\,term}" defaultOutput)
        assertBool "uses both explicit templates" (Text.isInfixOf "{\\mathsf{term}(\\iota\\Rightarrow A)}" explicitOutput),
      testCase "LaTeX uses its own override and falls back when only HTML is configured" $ do
        let input =
              oneRule
                [ "infixr:60 \"→\"",
                  "  html => lhs \"<mo>→</mo>\" rhs",
                  "notation:10 e:11 \"term\"",
                  "  latex => \"\\mathsf{term}(\" e \")\""
                ]
                "ι → A term"
        output <- parsed input (compileSource input)
        assertBool "renders without a Lean override" (Text.isInfixOf "{\\mathsf{term}(\\iota\\to A)}" output),
      testCase "an unresolved notation in a constructed AST reports a diagnostic" $ do
        document <- parsedSource (oneRule ["infixr:60 \"→\" => \"\\to\""] "A → B")
        case renderLatex mempty (Document [] (sourceSections document)) of
          Left diagnostic -> do
            diagnosticKind diagnostic @?= InvalidNotationApplication
            diagnosticSpan diagnostic @?= at 6 3 4
          Right latex -> assertFailure ("Expected a diagnostic, rendered " <> Text.unpack latex)
    ]
  where
    golden = goldenWith (\input -> pure (either (Left . formatDiagnostic input) Right (compileSource input)))
    goldenWith compile title inputPath name =
      goldenVsString title ("test/fixtures/latex/" <> name <> ".tex") $ do
        input <- readUtf8 inputPath
        result <- compile input
        case result of
          Left diagnostic -> assertFailure (Text.unpack diagnostic)
          Right latex -> pure (ByteString.fromStrict (Encoding.encodeUtf8 latex))
