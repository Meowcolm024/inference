module Main (main) where

import BlockTests (blockTests)
import FilterTests (filterTests)
import LaTeXTests (latexTests)
import ModuleTests (moduleTests)
import ParserTests (parserTests)
import SourceTests (sourceTests)
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain (testGroup "Inference" [parserTests, latexTests, sourceTests, blockTests, filterTests, moduleTests])
