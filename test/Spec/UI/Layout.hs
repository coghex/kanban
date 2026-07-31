-- | The responsive board layout.
module Spec.UI.Layout (spec) where

import Kanban.Layout (responsiveColumnWidths, responsiveOpenColumnWidths)
import Test.Hspec

spec :: Spec
spec = do
  describe "responsive board layout" $ do
    it "shares a wide board across all four columns" $
      responsiveColumnWidths 167 `shouldBe` [41, 41, 40, 40]
    it "keeps readable columns and relies on scrolling below the threshold" $
      responsiveColumnWidths 100 `shouldBe` [32, 32, 32, 32]
    it "accounts for two-cell gutters in the open layout" $
      responsiveOpenColumnWidths 170 `shouldBe` [41, 41, 41, 41]
