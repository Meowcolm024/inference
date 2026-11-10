module Main (main) where

import Data.ByteString.Lazy qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Encoding
import Data.Text.IO qualified as Text.IO
import Inference.AST
import Inference.LaTeX (compileSource, renderLatex)
import Inference.Parser
import System.IO (IOMode (ReadMode), hSetEncoding, utf8, withFile)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.Golden (goldenVsString)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Positive (..), Property, chooseInt, counterexample, forAll, testProperty, (===))

main :: IO ()
main =
  defaultMain $
    testGroup
      "Inference"
      [ testGroup "Parser" [layoutTests, expressionTests, declarationTests, negativeFixtures, exampleTests],
        latexTests,
        sourceTests
      ]

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
        sourceFailure [emptyTitle, end] MalformedSourceDelimiter 1 emptyTitle
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
        checkExample "stlc" 2
        checkExample "system-f" 3
        checkExample "untyped-lambda" 4
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
    checkExample name groups = do
      input <- readUtf8 ("example/" <> name <> ".tex")
      case compileSource input of
        Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))
        Right output -> do
          Text.count "\\begin{mathpar}" output @?= groups
          Text.count "\\caption{" output @?= groups
          assertBool
            "document preamble and boundaries remain intact"
            ( Text.isPrefixOf "\\documentclass{article}\n\\usepackage{mathpartir}\n\n\\begin{document}\n" output
                && Text.isSuffixOf "\\end{document}\n" output
            )

latexTests :: TestTree
latexTests =
  testGroup
    "LaTeX"
    [ golden "axioms, labels, grouping, scripts, and template substitution" "test/fixtures/latex/features.rules" "features",
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

layoutTests :: TestTree
layoutTests =
  testGroup
    "Rule layout"
    [ testCase "labeled premises and an unlabeled axiom" $ do
        input <- readFixture "positive/layout"
        section <- parsed input (parseRuleSection [] Nothing input)
        case sectionRules section of
          [rule, axiom] -> do
            ruleLabel rule @?= Just "Labeled rule"
            map shape (rulePremises rule) @?= [Name "e₁", Name "e₂"]
            shape (ruleConclusion rule) @?= Name "Γ"
            ruleSpan rule @?= SourceSpan (SourcePosition 2 3) (SourcePosition 5 4)
            ruleLabel axiom @?= Nothing
            rulePremises axiom @?= []
            shape (ruleConclusion axiom) @?= Name "∅"
          rules -> assertFailure ("Expected two rules, found " <> show rules),
      testCase "CRLF and a missing final newline preserve spans" $ do
        input <- readFixture "positive/layout"
        let crlf = Text.replace "\n" "\r\n" (Text.dropWhileEnd (== '\n') input)
        parseRuleSection [] Nothing crlf @?= parseRuleSection [] Nothing input,
      testCase "empty and whitespace-only documents" $
        parseRuleSection [] Nothing " \t\r\n \n" @?= Right (Section Nothing Nothing []),
      testCase "missing separator" $
        failsWith (parseRuleSection [] Nothing "Γ\nA\n") MissingSeparator (at 2 2 2),
      testCase "missing blank line between rules" $
        failsWith (parseRuleSection [] Nothing "─\nA\n─\nB") ExpectedBlankLine (at 3 1 2),
      testCase "lone carriage return" $
        failsWith (parseRuleSection [] Nothing "─\r\n𝛤\rA") InvalidLineEnding (at 2 2 3),
      testProperty "separator length does not change rule contents" separatorProperty
    ]

separatorProperty :: Positive Int -> Property
separatorProperty (Positive premiseCount) = forAll (chooseInt (1, 80)) $ \width ->
  let input = Text.unlines (replicate premiseCount "Γ" ++ [Text.replicate width "─" <> " Rule", "A"])
   in case parseRuleSection [] Nothing input of
        Right section ->
          map (\r -> (ruleLabel r, map shape (rulePremises r), shape (ruleConclusion r))) (sectionRules section)
            === [(Just "Rule", replicate premiseCount (Name "Γ"), Name "A")]
        Left diagnostic -> counterexample (show diagnostic) False

expressionTests :: TestTree
expressionTests =
  testGroup
    "Expression trees"
    [ testCase "identifier boundaries, math symbols, and longest symbolic literal" $ do
        let declarations =
              [ "notation:10 e:11 \"term\" => e",
                "notation:56 \"λ\" x:atom \".\" e:56 => x e",
                "infix:55 \"<\" => \"<\"",
                "infix:55 \"<=\" => \"≤\""
              ]
        assertShape declarations "terminal" (Name "terminal")
        assertShape declarations "λx" (Name "λx")
        assertShape declarations "λ x . x" (Use 2 [Name "x", Name "x"])
        assertShape declarations "∅" (Name "∅")
        assertShape declarations "a<=b" (Use 4 [Name "a", Name "b"])
        assertShape declarations "a<b" (Use 3 [Name "a", Name "b"]),
      testCase "subscripts and superscripts stay inside identifiers" $ do
        input <- readFixture "positive/scripts"
        document <- parsedSource input
        let names = Text.words "e₀₁₂₃₄₅₆₇₈₉ e⁰¹²³⁴⁵⁶⁷⁸⁹ Γᵢ eⁿ⁺¹ Γ₍ᵢ₊₁₎ x⁽ᵅ⁻¹⁾ y₌ z⁼"
        case map (shape . ruleConclusion) (sourceRules document) of
          [scripts, keyword] -> do
            flattenCall scripts @?= map Name names
            keyword @?= Use 1 [Name "x"]
          rules -> assertFailure ("Expected two conclusions, found " <> show rules),
      testCase "juxtaposition is left-associative and tighter than notation" $ do
        let declarations = ["infixr:60 \"→\" => \"\\to\"", "notation:10 e:11 \"term\" => e"]
        assertShape declarations "f x y" (Call (Call (Name "f") (Name "x")) (Name "y"))
        assertShape declarations "f (g x)" (Call (Name "f") (Grouped (Call (Name "g") (Name "x"))))
        assertShape declarations "f(x)" (Call (Name "f") (Grouped (Name "x")))
        assertShape declarations "f (x)" (Call (Name "f") (Grouped (Name "x")))
        assertShape declarations "f x → g y" (Use 1 [Call (Name "f") (Name "x"), Call (Name "g") (Name "y")])
        assertShape declarations "e₁ e₂ term" (Use 2 [Call (Name "e₁") (Name "e₂")]),
      testCase "infix precedence and associativity" $ do
        let declarations = ["infixr:60 \"→\" => \"\\to\"", "infixl:52 \",\" => \",\"", "infix:53 \"∈\" => \"\\in\""]
        assertShape declarations "A → B → C" (Use 1 [Name "A", Use 1 [Name "B", Name "C"]])
        assertShape declarations "A, B, C" (Use 2 [Use 2 [Name "A", Name "B"], Name "C"])
        assertShape declarations "A, B → C" (Use 2 [Name "A", Use 1 [Name "B", Name "C"]])
        failsWith (parseSource (oneRule declarations "a ∈ b ∈ c")) UnexpectedToken (at 8 7 8)
        assertShape declarations "(a ∈ b) ∈ c" (Use 3 [Grouped (Use 3 [Name "a", Name "b"]), Name "c"]),
      testCase "nested delimiters end only the current hole" $ do
        input <- readFixture "positive/nested-mixfix"
        document <- parsedSource input
        let inner = Use 1 [Call (Name "g") (Name "y"), Name "a", Name "b"]
        map (shape . ruleConclusion) (sourceRules document)
          @?= [Use 1 [Call (Name "f") (Name "x"), inner, Name "c"]],
      testCase "grouping resets the enclosing delimiter and precedence" $ do
        let declarations = ["notation:20 \"if\" c:0 \"then\" t:0 => c t", "infix:10 \"then\" => \"then\""]
        assertShape declarations "if (a then b) then c" (Use 1 [Grouped (Use 2 [Name "a", Name "b"]), Name "c"]),
      testCase "an atom hole accepts a group but does not consume application" $ do
        let declarations = ["notation:56 \"λ\" x:atom \".\" e:56 => x e"]
        assertShape declarations "f (λ (x y) . z)" (Call (Name "f") (Grouped (Use 1 [Grouped (Call (Name "x") (Name "y")), Name "z"])))
        failsWith (parseSource (oneRule declarations "λ x y . z")) ExpectedDelimiter (at 6 5 6),
      testCase "declared literals cannot be used as application arguments" $
        failsWith (parseSource (oneRule ["notation:75 \"fst\" x:atom => x"] "f fst x")) UnexpectedToken (at 6 3 6),
      testCase "binding, lookup, and judgment share the colon" $ do
        let declarations =
              [ "infixr:60 \"→\" => \"\\to\"",
                "infix:55 \":\" => \":\"",
                "notation:53 x:atom \":\" A:54 \"∈\" Γ:51 => x A Γ",
                "infixl:52 \",\" => \",\"",
                "notation:50 Γ:51 \"⊢\" e:51 \":\" A:51 => Γ e A",
                "notation:56 \"λ\" x:atom \":\" A:0 \".\" e:56 => x A e"
              ]
            arrow = Use 1 [Name "A", Name "B"]
        assertShape declarations "x : A" (Use 2 [Name "x", Name "A"])
        assertShape declarations "x : A → B ∈ Γ, y : C" (Use 3 [Name "x", arrow, Use 4 [Name "Γ", Use 2 [Name "y", Name "C"]]])
        assertShape declarations "Γ ⊢ λ x : A . e : A → B" (Use 5 [Name "Γ", Use 6 [Name "x", Name "A", Name "e"], arrow])
    ]

declarationTests :: TestTree
declarationTests =
  testGroup
    "Declarations"
    [ testCase "infix shorthand lowers to a pattern and preserves template text" $ do
        let input = "infixr:60 \" → \" => \" \\to \""
        notations <- parsed input (parseNotationBlock input)
        case notations of
          [notation] -> do
            notationPattern notation @?= Hole "left" (AtLeast 61) :| [Literal "→", Hole "right" (AtLeast 60)]
            notationTemplate notation @?= Reference "left" :| [Fragment " \\to ", Reference "right"]
          other -> assertFailure ("Expected one notation, found " <> show other),
      testCase "quoted text supports literal quotes and backslashes" $ do
        let input = "notation:5 \"a\" => \"\\\"\\\\\""
        notations <- parsed input (parseNotationBlock input)
        map notationTemplate notations @?= [Fragment "\"\\" :| []],
      testCase "invalid patterns" $ do
        failsWith (parseNotationBlock "notation:5 x:0 y:0 => x") InvalidPattern (at 1 16 19)
        failsWith (parseNotationBlock "notation:5 x:0 \"+\" x:0 => x") InvalidPattern (at 1 20 23)
        failsWith (parseNotationBlock "notation:5 \"a b\" => \"x\"") InvalidPattern (at 1 12 17)
        failsWith (parseNotationBlock "notation:5 \"(\" => \"x\"") InvalidPattern (at 1 12 15),
      testCase "malformed precedence" $
        failsWith (parseNotationBlock "notation:-1 \"a\" => \"b\"") MalformedDeclaration (at 1 10 11)
    ]

negativeFixtures :: TestTree
negativeFixtures =
  testGroup
    "Negative fixtures"
    [ testCase "malformed separator" $
        fixtureFailure (parseRuleSection [] Nothing) "malformed-separator" MalformedSeparator (at 2 5 6),
      testCase "missing conclusion" $
        fixtureFailure (parseRuleSection [] Nothing) "missing-conclusion" MissingConclusion (at 2 11 11),
      testCase "unknown template reference" $
        fixtureFailure parseNotationBlock "invalid-template" InvalidTemplateReference (at 1 26 33),
      testCase "missing mixfix delimiter" $ do
        input <- readFixture "negative/missing-delimiter"
        diagnostic <- rejected (parseSource input) ExpectedDelimiter (at 6 14 14)
        diagnosticMessage diagnostic @?= "Expected delimiter ‘else’. Reached the end of the line.",
      testCase "unknown token after a supplementary Unicode character" $ do
        input <- readFixture "negative/invalid-token"
        diagnostic <- rejected (parseRuleSection [] Nothing input) InvalidToken (at 2 3 4)
        formatDiagnostic input diagnostic
          @?= Text.unlines ["2:3: Unknown token ‘@’.", "2 | 𝛤 @", "  |   ^"],
      testCase "competing prefixes inside a group" $
        assertAmbiguous "ambiguous-prefix" [at 7 4 8] [at 2 1 31, at 3 1 29],
      testCase "competing infix associativities" $
        assertAmbiguous "ambiguous-infix" [at 7 3 4, at 7 7 8] [at 2 1 23, at 3 1 23],
      testCase "a delimiter could belong to either nested pattern" $
        assertAmbiguous "ambiguous-nesting" [at 7 1 3] [at 2 1 39, at 3 1 52]
    ]

assertAmbiguous :: String -> [SourceSpan] -> [SourceSpan] -> Assertion
assertAmbiguous name primary related = do
  input <- readFixture ("negative/" <> name)
  diagnostic <- diagnose (parseSource input)
  diagnosticKind diagnostic @?= AmbiguousExpression
  assertBool ("Expected a competing token, got " <> show (diagnosticSpan diagnostic)) (diagnosticSpan diagnostic `elem` primary)
  diagnosticRelated diagnostic @?= related
  let rendered = formatDiagnostic input diagnostic
  assertBool "shows the ambiguity reason" ("multiple parses" `Text.isInfixOf` rendered)
  assertBool "highlights the use and both declarations" (Text.count "^" rendered > 2 && Text.count "Competing notation declared here." rendered == 2)

exampleTests :: TestTree
exampleTests =
  testGroup
    "Complete examples"
    [ example "stlc" [("STLC syntax", 7), ("STLC typing", 3)],
      example
        "system-f"
        [("System F type and context formation", 8), ("System F term formation", 8), ("System F typing", 8)],
      example
        "untyped-lambda"
        [("Untyped lambda syntax", 3), ("Capture-avoiding substitution", 6), ("Beta reduction", 4), ("Multi-step reduction", 2)]
    ]
  where
    example name expected = testCase name $ do
      input <- readUtf8 ("example/" <> name <> ".tex")
      document <- parsedSource input
      map (\section -> (sectionTitle section, length (sectionRules section))) (sourceSections document)
        @?= [(Just title, count) | (title, count) <- expected]

data Shape
  = Name Text
  | Grouped Shape
  | Call Shape Shape
  | Use Int [Shape]
  deriving (Eq, Show)

shape :: Expr -> Shape
shape expression = case exprNode expression of
  Atom name -> Name name
  Group inner -> Grouped (shape inner)
  Application function argument -> Call (shape function) (shape argument)
  NotationApplication (NotationId identity) _ arguments -> Use identity (map shape arguments)

flattenCall :: Shape -> [Shape]
flattenCall (Call function argument) = flattenCall function ++ [argument]
flattenCall expression = [expression]

assertShape :: [Text] -> Text -> Shape -> Assertion
assertShape declarations expression expected = do
  document <- parsedSource (oneRule declarations expression)
  map (shape . ruleConclusion) (sourceRules document) @?= [expected]

oneRule :: [Text] -> Text -> Text
oneRule declarations expression =
  Text.unlines (["\\begin{inference-notation}"] ++ declarations ++ ["\\end{inference-notation}", "\\begin{inference}", "─", expression, "\\end{inference}"])

readFixture :: String -> IO Text
readFixture name = readUtf8 ("test/fixtures/" <> name <> ".rules")

readUtf8 :: FilePath -> IO Text
readUtf8 path = withFile path ReadMode $ \handle -> do
  hSetEncoding handle utf8
  Text.IO.hGetContents handle

fixtureFailure :: (Text -> Either Diagnostic a) -> String -> DiagnosticKind -> SourceSpan -> Assertion
fixtureFailure parse name kind source = do
  input <- readFixture ("negative/" <> name)
  failsWith (parse input) kind source

failsWith :: Either Diagnostic a -> DiagnosticKind -> SourceSpan -> Assertion
failsWith result kind source = do
  _ <- rejected result kind source
  pure ()

rejected :: Either Diagnostic a -> DiagnosticKind -> SourceSpan -> IO Diagnostic
rejected result kind source = do
  diagnostic <- diagnose result
  diagnosticKind diagnostic @?= kind
  diagnosticSpan diagnostic @?= source
  pure diagnostic

diagnose :: Either Diagnostic a -> IO Diagnostic
diagnose (Left diagnostic) = pure diagnostic
diagnose (Right _) = assertFailure "Expected a diagnostic."

parsed :: Text -> Either Diagnostic a -> IO a
parsed input result = case result of
  Right value -> pure value
  Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))

parsedSource :: Text -> IO SourceDocument
parsedSource input = parsed input (parseSource input)

sourceSections :: SourceDocument -> [Section]
sourceSections document = [section | RuleSetSource section <- sourceDocumentChunks document]

sourceRules :: SourceDocument -> [Rule]
sourceRules = concatMap sectionRules . sourceSections

at :: Int -> Int -> Int -> SourceSpan
at line start end = SourceSpan (SourcePosition line start) (SourcePosition line end)
