module LaTeXTests (latexTests) where

import Data.ByteString.Lazy qualified as ByteString
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Inference.AST
import Inference.LaTeX (compileSource, renderLatex)
import Inference.Parser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import TestSupport

latexTests :: TestTree
latexTests =
  testGroup
    "LaTeX"
    [ golden "axioms, labels, grouping, scripts, and template substitution" "test/fixtures/latex/features.rules" "features",
      golden "BNF groups and continuation indentation" "test/fixtures/latex/bnf.rules" "bnf",
      golden "aligned equations and guards" "test/fixtures/latex/equations.rules" "equations",
      golden "untyped lambda calculus" "example/untyped-lambda.tex" "untyped-lambda",
      golden "simply typed lambda calculus" "example/stlc.tex" "stlc",
      golden "section order, omitted empty sections, and caption escaping" "test/fixtures/latex/sections.rules" "sections",
      testCase "an unresolved notation in a constructed AST reports a diagnostic" $ do
        document <- parsedSource (oneRule ["infixr:60 \"→\" => \"\\to\""] "A → B")
        case renderLatex (Document [] (sourceSections document)) of
          Left diagnostic -> do
            diagnosticKind diagnostic @?= InvalidNotationApplication
            diagnosticSpan diagnostic @?= at 6 3 4
          Right latex -> assertFailure ("Expected a diagnostic, rendered " <> Text.unpack latex)
    ]
  where
    golden title inputPath name =
      goldenVsString title ("test/fixtures/latex/" <> name <> ".tex") $ do
        input <- readUtf8 inputPath
        case compileSource input of
          Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))
          Right latex -> pure (ByteString.fromStrict (Encoding.encodeUtf8 latex))
