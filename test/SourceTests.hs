module SourceTests (sourceTests) where

import Data.Text qualified as Text
import Inference.AST
import Inference.FileSystem (fileSystemResolver)
import Inference.LaTeX (compileSource, compileSourceWithImports)
import Inference.Parser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import TestSupport

sourceTests :: TestTree
sourceTests =
  testGroup
    "LaTeX source"
    [ testCase "rewrites only recognized environments and resolves forward notation" $ do
        let input =
              "% \\begin{inference}\r\n\\begin{document}\r\n\r\n"
                <> "  \\begin{inference}[rule_set=  Types #_%  ]\n─\nA → B\n  \\end{inference}\n"
                <> "Between \\begin{inference} and \\end{inference}\r\n"
                <> "\\begin{inference}\r\n─\r\nB → C\r\n\\end{inference}\r\n"
                <> "\\begin{inference}[rule_set=Empty]\n\\end{inference}\n"
                <> "\\begin{inference-notation}\r\ninfixr:60 \"→\" => \"\\to\"\r\n\r\n\\end{inference-notation}\r\n"
                <> "\\end{document}"
            expected =
              "% \\begin{inference}\r\n\\begin{document}\r\n\r\n"
                <> "\\begin{figure}\n\\begin{mathpar}\n\\inferrule\n  { }\n  {A\\to B}\n\\end{mathpar}\n"
                <> "\\caption{Types \\#\\_\\%}\n\\end{figure}\n"
                <> "Between \\begin{inference} and \\end{inference}\r\n"
                <> "\\begin{mathpar}\n\\inferrule\n  { }\n  {B\\to C}\n\\end{mathpar}\n"
                <> "% infixr:60 \"→\" => \"\\to\"\r\n% \r\n\\end{document}"
        compileSource input @?= Right expected
        case parseSource input of
          Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))
          Right document -> do
            map notationSpan (sourceDocumentNotations document) @?= [at 16 1 23]
            let sections = [section | RuleSetSource section <- sourceDocumentChunks document]
            map sectionTitle sections @?= [Just "Types #_%", Nothing, Just "Empty"]
            map sectionMarkers (take 1 sections)
              @?= [Just (SectionMarkers (at 4 3 44) (at 7 3 18))]
            map (exprSpan . ruleConclusion) (concatMap sectionRules sections) @?= [at 6 1 6, at 11 1 6],
      testCase "plain LaTeX and unknown environments pass through" $ do
        let input = "\\begin{inference-other}\r\n% Prose\r\n\\end{inference-other}\n\\end{document}"
        compileSource input @?= Right input,
      testCase "empty notation block emits a newline" $
        compileSource "\\begin{inference-notation}\n\\end{inference-notation}" @?= Right "\n",
      testCase "nested opening delimiter" $
        sourceFailure [begin, notationBegin] NestedSourceEnvironment 2 notationBegin,
      testCase "mismatched closing delimiter" $
        sourceFailure [begin, notationEnd] MismatchedSourceEnd 2 notationEnd,
      testCase "closing delimiter without an opening delimiter" $
        sourceFailure ["Prose", end] UnexpectedSourceEnd 2 end,
      testCase "unclosed environment" $
        sourceFailure ["Prose", begin, "─", "A"] UnclosedSourceEnvironment 2 begin,
      testCase "empty caption and malformed delimiters" $ do
        let emptyTitle = begin <> "[rule_set= ]"
            trailingContent = end <> " text"
            notationWithOptions = notationBegin <> "[rule_set=Types]"
        sourceDiagnostic [emptyTitle, end] MalformedBlockOption (at 1 29 29)
        sourceFailure [begin, trailingContent] MalformedSourceDelimiter 2 trailingContent
        sourceFailure [notationWithOptions, notationEnd] MalformedSourceDelimiter 1 notationWithOptions,
      testCase "body diagnostics use document coordinates" $ do
        sourceDiagnostic [begin, "─", end] MissingConclusion (at 2 2 2)
        sourceDiagnostic ["Prose", begin, "─", "𝛤 @", end] InvalidToken (at 4 3 4)
        sourceDiagnostic ["Prose", notationBegin, "notation:4 \"λ\" x:atom => missing", notationEnd] InvalidTemplateReference (at 3 26 33),
      testCase "ambiguity reports declaration spans across notation environments" $ do
        let first = "infixl:60 \"→\" => \"\\to\""
            second = "infixr:60 \"→\" => \"\\to\""
            input = Text.unlines [begin, "─", "A → B", end, notationBegin, first, notationEnd, notationBegin, second, notationEnd]
        case compileSource input of
          Left diagnostic -> do
            diagnosticKind diagnostic @?= AmbiguousExpression
            diagnosticSpan diagnostic @?= at 3 3 4
            diagnosticRelated diagnostic @?= [wholeLine 6 first, wholeLine 9 second]
          Right output -> assertFailure ("Expected ambiguity, got " <> Text.unpack output),
      testCase "complete source examples produce one group per rule set" $ do
        checkExample "stlc" 2 2
        checkExample "system-f" 3 3
        checkExample "untyped-lambda" 2 4
    ]
  where
    begin = "\\begin{inference}"
    end = "\\end{inference}"
    notationBegin = "\\begin{inference-notation}"
    notationEnd = "\\end{inference-notation}"
    wholeLine number line = at number 1 (Text.length line + 1)
    sourceFailure lines' kind number line = sourceDiagnostic lines' kind (wholeLine number line)
    sourceDiagnostic lines' kind source =
      case compileSource (Text.unlines lines') of
        Left diagnostic -> do
          diagnosticKind diagnostic @?= kind
          diagnosticSpan diagnostic @?= source
        Right output -> assertFailure ("Expected a diagnostic, got " <> Text.unpack output)
    checkExample name groups captions = do
      input <- readUtf8 ("example/" <> name <> ".tex")
      result <- compileSourceWithImports (fileSystemResolver ".") input
      case result of
        Left diagnostic -> assertFailure (Text.unpack diagnostic)
        Right output -> do
          Text.count "\\begin{mathpar}" output @?= groups
          Text.count "\\caption{" output @?= captions
          assertBool
            "document preamble and boundaries remain intact"
            ( Text.isPrefixOf "\\documentclass{article}\n\\usepackage{mathpartir}\n\n\\begin{document}\n" output
                && Text.isSuffixOf "\\end{document}\n" output
            )
