{-# LANGUAGE OverloadedLists #-}

module Ide.Plugin.CodeRangeTest (testTree) where

import qualified Data.Vector                as V
import           Ide.Plugin.CodeRange
import           Ide.Plugin.CodeRange.Rules
import           Test.Hls
import           Test.Tasty.HUnit

testTree :: TestTree
testTree =
    testGroup "CodeRange" [
        testGroup "findPosition" $
            let check :: Position -> CodeRange -> Maybe SelectionRange -> Assertion
                check position codeRange = (findPosition position codeRange @?=)

                mkCodeRange :: Position -> Position -> V.Vector CodeRange -> CodeRange
                mkCodeRange start end children = CodeRange (Range start end) children CodeKindRegion
            in [
                testCase "not in range" $ check
                    (Position 10 1)
                    (mkCodeRange (Position 1 1) (Position 5 10) [])
                    Nothing,
                testCase "in top level range" $ check
                    (Position 3 8)
                    (mkCodeRange (Position 1 1) (Position 5 10) [])
                    (Just $ SelectionRange (Range (Position 1 1) (Position 5 10)) Nothing),
                testCase "in the gap between children, in parent" $ check
                    (Position 3 6)
                    (mkCodeRange (Position 1 1) (Position 5 10) [
                        mkCodeRange (Position 1 1) (Position 3 6) [],
                        mkCodeRange (Position 3 7) (Position 5 10) []
                    ])
                    (Just $ SelectionRange (Range (Position 1 1) (Position 5 10)) Nothing),
                testCase "before all children, in parent" $ check
                    (Position 1 1)
                    (mkCodeRange (Position 1 1) (Position 5 10) [
                        mkCodeRange (Position 1 2) (Position 3 6) [],
                        mkCodeRange (Position 3 7) (Position 5 10) []
                    ])
                    (Just $ SelectionRange (Range (Position 1 1) (Position 5 10)) Nothing),
                testCase "in children, in parent" $ check
                    (Position 2 1)
                    (mkCodeRange (Position 1 1) (Position 5 10) [
                        mkCodeRange (Position 1 2) (Position 3 6) [],
                        mkCodeRange (Position 3 7) (Position 5 10) []
                    ])
                    (Just $ SelectionRange (Range (Position 1 2) (Position 3 6)) $ Just
                        ( SelectionRange (Range (Position 1 1) (Position 5 10)) Nothing
                        )
                    )
            ],
        testGroup "findFoldingRanges" $
            let check :: CodeRange -> [FoldingRange] -> Assertion
                check codeRange = (findFoldingRanges codeRange @?=)

                mkCodeRange :: Position -> Position -> V.Vector CodeRange -> CodeRangeKind -> CodeRange
                mkCodeRange start end children crk = CodeRange (Range start end) children crk
            in [
                -- General test
                testCase "Test General Code Block" $ check
                    (mkCodeRange (Position 1 1) (Position 5 10) [] CodeKindRegion)
                    [FoldingRange 1 (Just 1) 5 (Just 10) (Just FoldingRangeRegion)],

                -- Tests for code kind
                testCase "Test Code Kind Region" $ check
                    (mkCodeRange (Position 1 1) (Position 5 10) [] CodeKindRegion)
                    [FoldingRange 1 (Just 1) 5 (Just 10) (Just FoldingRangeRegion)],
                testCase "Test Code Kind Comment" $ check
                    (mkCodeRange (Position 1 1) (Position 5 10) [] CodeKindComment)
                    [FoldingRange 1 (Just 1) 5 (Just 10) (Just FoldingRangeComment)],
                testCase "Test Code Kind Import" $ check
                    (mkCodeRange (Position 1 1) (Position 5 10) [] CodeKindImports)
                    [FoldingRange 1 (Just 1) 5 (Just 10) (Just FoldingRangeImports)],

                -- Test for Code Portions with children
                testCase "Test Children" $ check
                    (mkCodeRange (Position 1 1) (Position 5 10) [
                        mkCodeRange (Position 1 2) (Position 3 6) [] CodeKindRegion,
                        mkCodeRange (Position 3 7) (Position 5 10) [] CodeKindRegion
                    ] CodeKindRegion)
                    [FoldingRange 1 (Just 1) 5 (Just 10) (Just FoldingRangeRegion),
                    FoldingRange 1 (Just 2) 3 (Just 6) (Just FoldingRangeRegion),
                    FoldingRange 3 (Just 7) 5 (Just 10) (Just FoldingRangeRegion)]
            ]
    ]
