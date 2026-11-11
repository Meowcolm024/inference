module ParserTests (parserTests) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Positive (..), Property, chooseInt, counterexample, forAll, testProperty, (===))
import TestSupport

parserTests :: TestTree
parserTests = testGroup "Parser" [layoutTests, expressionTests, declarationTests, negativeFixtures, exampleTests]

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
        parseRuleSection [] Nothing " \t\r\n \n" @?= Right (Section Nothing Nothing (InferenceRules [])),
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
        [("Untyped lambda syntax", 1), ("Capture-avoiding substitution", 6), ("Beta reduction", 4), ("Multi-step reduction", 2)]
    ]
  where
    example name expected = testCase name $ do
      input <- readUtf8 ("example/" <> name <> ".tex")
      document <- parsedSource input
      map (\section -> (sectionTitle section, countBody (sectionBody section))) (sourceSections document)
        @?= [(Just title, count) | (title, count) <- expected]

countBody :: BlockBody -> Int
countBody (InferenceRules rules) = length rules
countBody (BnfGroups groups) = sum (map (length . bnfProductions) groups)
countBody (Equations rows) = length [() | EquationLine _ <- rows]

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
