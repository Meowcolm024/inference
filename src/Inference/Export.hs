module Inference.Export
  ( ExportTarget (..),
    FragmentContext (..),
    ExportedFragment (..),
    exportInference,
    exportItem,
  )
where

import Data.Bifunctor (first)
import Data.Maybe (catMaybes)
import Data.Text (Text)
import Data.Text qualified as Text
import Inference.AST (Document (..))
import Inference.Content
import Inference.HTML (HtmlTemplateMode, renderHtml, renderHtmlExpression, selectHtmlTemplates)
import Inference.LaTeX (renderLatex, renderLatexExpression, renderLatexMath)
import Inference.Parser (Diagnostic)
import Inference.Templates (templatesFor)

data ExportTarget = Mathpar | LatexMath | Html HtmlTemplateMode

data FragmentContext = InlineFragment | DisplayFragment
  deriving (Eq, Show)

data ExportedFragment = ExportedFragment
  { fragmentKey :: OccurrenceKey,
    fragmentContext :: FragmentContext,
    fragmentText :: Text
  }
  deriving (Eq, Show)

exportInference :: ExportTarget -> ParsedInference -> Either (OccurrenceKey, Diagnostic) [ExportedFragment]
exportInference target parsed =
  catMaybes <$> traverse render (parsedItems parsed)
  where
    render item = first (parsedKey item,) (exportItem target parsed item)

-- Inline TeX fragments contain bare math. Empty sections and notation
-- declarations have no standalone fragment.
exportItem :: ExportTarget -> ParsedInference -> ParsedItem -> Either Diagnostic (Maybe ExportedFragment)
exportItem target parsed item = case parsedContent item of
  ParsedNotationBlock -> Right Nothing
  ParsedSection section -> do
    rendered <- renderSection (Document notations [section])
    pure $
      if Text.null rendered
        then Nothing
        else Just (fragment DisplayFragment rendered)
  ParsedInline expression ->
    Just . fragment InlineFragment <$> renderExpression notations expression
  where
    notations = parsedNotations parsed
    templates = parsedTemplates parsed
    latexTemplates = templatesFor "latex" templates
    fragment = ExportedFragment (parsedKey item)
    (renderSection, renderExpression) = case target of
      Mathpar -> (renderLatex latexTemplates, renderLatexExpression latexTemplates)
      LatexMath -> (renderLatexMath latexTemplates, renderLatexExpression latexTemplates)
      Html mode ->
        let htmlTemplates = selectHtmlTemplates mode templates
         in (renderHtml htmlTemplates, renderHtmlExpression htmlTemplates)
