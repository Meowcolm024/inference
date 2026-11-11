module BlockTests (blockTests) where

import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.LaTeX (compileSource)
import Inference.Parser
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Test.Tasty.QuickCheck (Positive (..), Property, counterexample, testProperty, (===))
import TestSupport (at, parsed)

blockTests :: TestTree
blockTests =
  testGroup
    "BNF and equations"
    [ testCase "BNF keywords need no declarations; category lists and rows survive parsing" $ do
        body <- parsedBody BnfKind [] "--- Types\nA,B ::= x | y\n        | z\nC ::= q\n\n--- Contexts\nΓ ::= ∅"
        case body of
          BnfGroups [types, contexts] -> do
            map bnfGroupName [types, contexts] @?= ["Types", "Contexts"]
            case bnfProductions types of
              [production, _] -> do
                map atomName (productionCategories production) @?= [Just "A", Just "B"]
                map productionRowIndent (productionRows production) @?= [0, 8]
                map (map atomName . productionAlternatives) (productionRows production)
                  @?= [[Just "x", Just "y"], [Just "z"]]
              other -> assertFailure (show other)
          other -> assertFailure (show other),
      testProperty "all reserved dash counts identify the same BNF group" dashProperty,
      testCase "continuations omit the leading bar and retain indentation and alternative separators" $ do
        let source = "\\begin{inference}[kind=bnf]\n--- Terms\nA ::= x | y\n        | z | w\n\\end{inference}"
        output <- parsed source (compileSource source)
        assertBool "keeps the continuation indentation" (Text.isInfixOf "\\hspace{4em}z \\mid w" output)
        assertBool "omits the continuation marker" (not (Text.isInfixOf "\\hspace{4em}\\mid" output))
        assertBool "keeps the first production row" (Text.isInfixOf "A \\mathrel{::=} x \\mid y" output),
      testCase "BNF layout ignores delimiters consumed inside grouping and mixfix" $ do
        body <-
          parsedBody
            BnfKind
            [ "infix:10 \"|\" => \"\\\\mid\"",
              "notation:50 \"wrap\" x:0 \"|\" y:0 \"done\" => x \"+\" y",
              "notation:50 \"define\" x:0 \"::=\" y:0 \"done\" => x \"+\" y"
            ]
            "--- Terms\nA ::= wrap x | y done | (x | y) | define x ::= y done"
        case body of
          BnfGroups [group] -> case bnfProductions group of
            [production] -> map (length . productionAlternatives) (productionRows production) @?= [3]
            other -> assertFailure (show other)
          other -> assertFailure (show other),
      testCase "missing and misplaced BNF group labels" $ do
        rejectBody BnfKind "---\nA ::= x" InvalidBnfGroup (at 1 1 4)
        rejectBody BnfKind "--- Types" InvalidBnfGroup (at 1 1 4)
        rejectBody BnfKind "--- Types\nA ::= x\n--- Contexts\nΓ ::= y" InvalidBnfGroup (at 3 1 4)
        rejectBody BnfKind "--- Types\n  | x" OrphanContinuation (at 2 3 6),
      testCase "empty BNF categories and alternatives are rejected" $ do
        rejectBody BnfKind "--- Types\nA, ::= x" InvalidProduction (at 2 4 4)
        rejectBody BnfKind "--- Types\nA ::= x |" InvalidProduction (at 2 10 10)
        rejectBody BnfKind "--- Types\nA ::= x ::= y" InvalidProduction (at 2 9 12),
      testCase "equations need no equality declaration and preserve blank rows" $ do
        body <- parsedBody EquationKind [] "x = y\n\nx = x"
        case body of
          Equations [EquationLine first, EquationBlank _, EquationLine _] -> do
            atomName (equationLeft first) @?= Just "x"
            atomName (equationRight first) @?= Just "y"
            equationGuard first @?= Nothing
          other -> assertFailure (show other),
      testCase "equations keep nested equalities and guard conditions" $ do
        body <-
          parsedBody
            EquationKind
            [ "infix:20 \"=\" => \"=\"",
              "notation:50 \"box\" x:0 \"=\" y:0 \"end\" => x \"+\" y"
            ]
            "box a = b end = (x = y) -- if a = b\nx = y -- a = b"
        case body of
          Equations [EquationLine first, EquationLine second] -> do
            case exprNode (equationLeft first) of
              NotationApplication (NotationId 2) _ arguments -> length arguments @?= 2
              other -> assertFailure (show other)
            case exprNode (equationRight first) of
              Group _ -> pure ()
              other -> assertFailure (show other)
            guardHasIf <$> equationGuard first @?= Just True
            guardHasIf <$> equationGuard second @?= Just False
          other -> assertFailure (show other),
      testCase "guard delimiters do not consume a longer dash operator" $ do
        body <- parsedBody EquationKind ["infix:20 \"---\" => \"+\""] "x = y --- z"
        case body of
          Equations [EquationLine equation] -> equationGuard equation @?= Nothing
          other -> assertFailure (show other),
      testCase "equation sides, guards, and reserved dash lines are diagnosed" $ do
        rejectBody EquationKind "= x" ExpectedExpression (at 1 1 2)
        rejectBody EquationKind "x =" InvalidEquation (at 1 4 4)
        rejectBody EquationKind "x = y --" EmptyGuard (at 1 9 9)
        rejectBody EquationKind "x = y -- if" EmptyGuard (at 1 12 12)
        rejectBody EquationKind "  ---- label" ReservedDashLine (at 1 3 7)
        rejectBody InferenceKind "--- label\n─\nx" ReservedDashLine (at 1 1 4),
      testCase "empty bodies emit no layout" $ do
        compileSource "\\begin{inference}[kind=bnf]\n\n\\end{inference}" @?= Right ""
        compileSource "\\begin{inference}[kind=equation]\n\n\\end{inference}" @?= Right "",
      testCase "source options preserve braced commas and report option spans" $ do
        let input = "\\begin{inference}[kind=bnf,rule_set={Types, {terms}}]\n--- Names\nA ::= x\n\\end{inference}"
        case parseSource input of
          Right document -> [sectionTitle section | RuleSetSource section <- sourceDocumentChunks document] @?= [Just "Types, {terms}"]
          Left diagnostic -> assertFailure (Text.unpack (formatDiagnostic input diagnostic))
        rejectSource "\\begin{inference}[kind=unknown]" UnknownBlockKind (at 1 24 31)
        rejectSource "\\begin{inference}[extra=x]" UnknownBlockOption (at 1 19 24)
        rejectSource "\\begin{inference}[kind=bnf,kind=equation]" DuplicateBlockOption (at 1 28 32)
        rejectSource "\\begin{inference}[rule_set={Types,terms]" MalformedBlockOption (at 1 19 40),
      testCase "Pandoc attributes select the same grammar, including Org quoting" $ do
        parseBlockAttributes [("kind", "\"bnf\""), ("rule_set", "\"Types, terms\"")]
          @?= Right (BlockOptions BnfKind (Just "Types, terms"))
        case parseBlockAttributes [("kind", "equation")] of
          Right options -> do
            section <- parsed "x = y" (parseBlockSection [] options "x = y")
            case sectionBody section of
              Equations [EquationLine _] -> pure ()
              other -> assertFailure (show other)
          Left diagnostic -> assertFailure (show diagnostic),
      testCase "source layout preserves mixed blocks and literal surrounding text" $ do
        let source = "Before\r\n\\begin{inference}[kind=bnf]\n--- Names\nA ::= x\n\\end{inference}\nMiddle\n\\begin{inference}[kind=equation]\nx = y\n\\end{inference}\nAfter"
        output <- parsed source (compileSource source)
        assertBool "copies the surrounding text" (Text.isPrefixOf "Before\r\n" output && Text.isSuffixOf "After" output)
        assertBool "renders distinct layouts" (Text.isInfixOf "\\begin{array}{l}" output && Text.isInfixOf "\\begin{array}{rcll}" output)
    ]

parsedBody :: BlockKind -> [Text] -> Text -> IO BlockBody
parsedBody kind declarations body = do
  let source = Text.unlines declarations
  notations <- parsed source (parseNotationBlock source)
  sectionBody <$> parsed body (parseBlockSection notations (BlockOptions kind Nothing) body)

rejectBody :: BlockKind -> Text -> DiagnosticKind -> SourceSpan -> Assertion
rejectBody kind body = rejected (parseBlockSection [] (BlockOptions kind Nothing) body)

rejectSource :: Text -> DiagnosticKind -> SourceSpan -> Assertion
rejectSource opening = rejected (parseSource (opening <> "\n\\end{inference}"))

rejected :: Either Diagnostic a -> DiagnosticKind -> SourceSpan -> Assertion
rejected result kind source = case result of
  Left diagnostic -> do
    diagnosticKind diagnostic @?= kind
    diagnosticSpan diagnostic @?= source
  Right _ -> assertFailure "Expected a diagnostic."

atomName :: Expr -> Maybe Text
atomName expression = case exprNode expression of
  Atom name -> Just name
  _ -> Nothing

dashProperty :: Positive Int -> Property
dashProperty (Positive extra) =
  let count = 3 + mod extra 80
      source = Text.replicate count "-" <> " Types\nA ::= x"
   in case parseBlockSection [] (BlockOptions BnfKind Nothing) source of
        Right section -> case sectionBody section of
          BnfGroups [group] -> (bnfGroupName group, length (bnfProductions group)) === ("Types", 1)
          other -> counterexample (show other) False
        Left diagnostic -> counterexample (show diagnostic) False
