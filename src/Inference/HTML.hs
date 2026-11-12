module Inference.HTML (renderHtml) where

import Data.Foldable (fold)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST
import Inference.Parser (Diagnostic (..), DiagnosticKind (..))
import Inference.Templates (TemplatePart (..), Templates)

renderHtml :: Templates -> Document -> Either Diagnostic Text
renderHtml templates document =
  Text.intercalate "\n" <$> traverse renderSection (documentSections document)
  where
    notations = Map.fromList [(notationId notation, notation) | notation <- documentNotations document]
    renderSection section = do
      body <- case sectionBody section of
        InferenceRules [] -> pure ""
        InferenceRules rules ->
          styled "div" "display:flex;flex-wrap:wrap;align-items:center;gap:1em" . fold
            <$> traverse (renderRule renderExpr) rules
        BnfGroups groups -> fold <$> traverse (renderBnfGroup renderExpr) groups
        Equations rows
          | any isEquation rows -> table . fold <$> traverse (renderEquationRow renderExpr) rows
          | otherwise -> pure ""
      pure $ case sectionTitle section of
        Just title
          | not (Text.null body) ->
              styled "figure" "margin:1em 0" (body <> styled "figcaption" "margin-top:.5em" (escapeHtml title))
        _ -> body

    renderExpr expression = case exprNode expression of
      Atom name -> Right (escapeHtml name)
      Group inner -> do
        rendered <- renderExpr inner
        pure ("(" <> rendered <> ")")
      Application function argument -> do
        left <- renderExpr function
        right <- renderExpr argument
        pure (left <> " " <> right)
      NotationApplication identity lead arguments -> do
        notation <- case Map.lookup identity notations of
          Just declaration -> Right declaration
          Nothing -> invalid lead "Notation application refers to an unknown declaration."
        let patternParts = NonEmpty.toList (notationPattern notation)
            names = [name | Hole name _ <- patternParts]
        if length names /= length arguments
          then invalid lead "Notation application has the wrong number of arguments."
          else do
            rendered <- traverse renderExpr arguments
            let bindings = Map.fromList (zip names rendered)
                reference name = case Map.lookup name bindings of
                  Just value -> Right value
                  Nothing -> invalid lead ("Unknown template hole ‘" <> name <> "’.")
                patternPart (Literal literal) = Right (escapeHtml literal)
                patternPart (Hole name _) = reference name
                templatePart (Fragment fragment) = Right fragment
                templatePart (Reference name) = reference name
            case Map.lookup identity templates of
              Just parts -> fold <$> traverse templatePart parts
              Nothing -> Text.intercalate " " <$> traverse patternPart patternParts

    invalid source message = Left (Diagnostic InvalidNotationApplication source message [])

type ExpressionRenderer = Expr -> Either Diagnostic Text

renderRule :: ExpressionRenderer -> Rule -> Either Diagnostic Text
renderRule renderExpr rule = do
  premises <- traverse renderExpr (rulePremises rule)
  conclusion <- renderExpr (ruleConclusion rule)
  let top = case premises of
        [] -> ""
        _ ->
          styled
            "div"
            "grid-area:1/1;display:flex;flex-wrap:wrap;justify-content:center;gap:.25em 1em;padding:.15em .4em"
            (foldMap (element "span") premises)
      bottom = styled "div" "grid-area:2/1;border-top:1px solid currentColor;padding:.15em .4em;text-align:center" conclusion
      labelStyle = "grid-area:2/2;align-self:start;transform:translateY(-50%);font-size:.85em"
      label = foldMap (styled "span" labelStyle . escapeHtml) (ruleLabel rule)
  pure $
    styled
      "div"
      "display:inline-grid;grid-template-columns:minmax(0,auto) auto;column-gap:.4em;max-width:100%;overflow-wrap:anywhere"
      (top <> bottom <> label)

renderBnfGroup :: ExpressionRenderer -> BnfGroup -> Either Diagnostic Text
renderBnfGroup renderExpr group = do
  productions <- traverse renderProduction (bnfProductions group)
  let caption = styled "caption" "text-align:left;font-weight:bold" (escapeHtml (bnfGroupName group))
  pure (tableWithCaption caption (fold productions))
  where
    renderProduction production = do
      categories <- traverse renderExpr (productionCategories production)
      rows <- traverse renderAlternatives (productionRows production)
      pure $ case rows of
        [] -> ""
        first : rest ->
          row [rightCell (Text.intercalate ", " categories), cell "::=", cell first]
            <> foldMap (\continuation -> row [cell "", cell "", cell continuation]) rest
    renderAlternatives alternatives =
      Text.intercalate " | " <$> traverse renderExpr (productionAlternatives alternatives)

renderEquationRow :: ExpressionRenderer -> EquationRow -> Either Diagnostic Text
renderEquationRow _ (EquationBlank _) = Right (row ["<td colspan=\"4\" style=\"height:.75em\"></td>"])
renderEquationRow renderExpr (EquationLine equation) = do
  left <- renderExpr (equationLeft equation)
  right <- renderExpr (equationRight equation)
  condition <- case equationGuard equation of
    Nothing -> Right ""
    Just guard -> do
      expression <- renderExpr (guardExpression guard)
      pure ((if guardHasIf guard then "if " else "") <> expression)
  pure (row [rightCell left, cell "=", cell right, cell condition])

isEquation :: EquationRow -> Bool
isEquation (EquationLine _) = True
isEquation (EquationBlank _) = False

table :: Text -> Text
table = tableWithCaption ""

tableWithCaption :: Text -> Text -> Text
tableWithCaption caption rows =
  styled "table" "border-collapse:collapse;margin:.5em 0" (caption <> element "tbody" rows)

row :: [Text] -> Text
row = element "tr" . Text.concat

cell, rightCell :: Text -> Text
cell = styled "td" "padding:.15em .4em;vertical-align:baseline"
rightCell = styled "td" "padding:.15em .4em;vertical-align:baseline;text-align:right"

element :: Text -> Text -> Text
element tag body = "<" <> tag <> ">" <> body <> "</" <> tag <> ">"

styled :: Text -> Text -> Text -> Text
styled tag css body = "<" <> tag <> " style=\"" <> css <> "\">" <> body <> "</" <> tag <> ">"

escapeHtml :: Text -> Text
escapeHtml = Text.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#39;"
  char -> Text.singleton char
