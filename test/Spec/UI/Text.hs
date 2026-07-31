-- | Sanitizing text that arrives from outside the process.
module Spec.UI.Text (spec) where

import Kanban.Text (excerpt, sanitizeText)
import Test.Hspec

spec :: Spec
spec = do
  describe "external text sanitization" $ do
    it "strips ANSI, control, and bidi sequences" $
      sanitizeText "safe\ESC[31m red\ESC[0m\NUL\x202Etext" `shouldBe` "safe redtext"
    it "selects and normalizes the first meaningful paragraph" $
      excerpt "\n\n  First\tparagraph\nwraps.  \n\nSecond paragraph." `shouldBe` "First paragraph wraps."
    it "excerpts a CRLF single-paragraph body to the full paragraph, not the first line" $
      excerpt "Repro steps:\r\nRun kanban\r\nPress j" `shouldBe` "Repro steps: Run kanban Press j"
    it "excerpts only the first paragraph of a CRLF body with a real paragraph break" $
      excerpt "First paragraph.\r\nstill first.\r\n\r\nSecond paragraph." `shouldBe` "First paragraph. still first."
    it "sanitizes a CRLF body the same as its LF twin" $
      sanitizeText "First paragraph.\r\nstill first.\r\n\r\nSecond paragraph."
        `shouldBe` sanitizeText "First paragraph.\nstill first.\n\nSecond paragraph."
    it "normalizes a lone carriage return to a line break" $
      sanitizeText "left\rright" `shouldBe` "left\nright"
    -- NFC is the final step, so a decomposed base-plus-accent input and its
    -- precomposed twin converge on the identical result.
    it "sanitizes NFC-equivalent composed and decomposed input identically" $ do
      sanitizeText "Caf\233" `shouldBe` sanitizeText "Cafe\769"
      sanitizeText "Cafe\769" `shouldBe` "Caf\233"
    -- A combining mark over a digit has no precomposed form -- Unicode never
    -- defines one -- so it survives both the safe-character filter (general
    -- category Mn, not Format or a bidi control) and NFC, which has nothing
    -- to fold it into.
    it "preserves an ordinary combining mark that has no precomposed form" $
      sanitizeText "5\817" `shouldBe` "5\817"
