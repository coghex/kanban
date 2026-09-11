-- | Sanitizing text that arrives from outside the process.
module Spec.UI.Text (spec) where

import Kanban.Text (excerpt, oneLineText, sanitizeText)
import Test.Hspec

spec :: Spec
spec = do
  sanitizationSpec
  excerptSelectionSpec
  oneLineSpec

sanitizationSpec :: Spec
sanitizationSpec = do
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

-- | The boundary beside 'excerpt': text normalized for one line without any
-- of it being read as Markdown.
--
-- Provider event types travel through this rather than through 'excerpt'
-- ("Kanban.Solve.Parse"), and a type shaped like a heading or a comment is a
-- type like any other. Reading one as structure would leave it blank and fold
-- every such type in with the payloads that genuinely name none.
oneLineSpec :: Spec
oneLineSpec = describe "one-line normalization" $ do
  it "collapses whitespace and trims, as an excerpt does" $ do
    oneLineText "  spread\tacross\nlines  " `shouldBe` "spread across lines"
    oneLineText "   " `shouldBe` ""

  it "reads none of its input as Markdown structure" $ do
    oneLineText "## alpha" `shouldBe` "## alpha"
    oneLineText "<!-- beta -->" `shouldBe` "<!-- beta -->"
    -- The same two inputs an excerpt does skip, which is the whole
    -- difference between the two.
    excerpt "## alpha" `shouldBe` ""
    excerpt "<!-- beta -->" `shouldBe` ""

  it "sanitizes like everything else that arrives from outside" $
    oneLineText "safe\ESC[31m red\ESC[0m\NULtext" `shouldBe` "safe redtext"

-- | #646. Which paragraph an excerpt comes from, once the structure a body
-- opens with is no longer eligible to be it (§11).
--
-- Every issue in this repository is filed from a template whose body opens
-- with an instructional HTML comment and then @## Background@, and an
-- agent-filed one opens with its origin marker, so before this the cards
-- showed the template rather than the issue.
excerptSelectionSpec :: Spec
excerptSelectionSpec = describe "body excerpt selection" $ do
  it "skips a leading heading and excerpts the prose under it" $
    excerpt "## Background\n\nThe board loses useful context." `shouldBe` "The board loses useful context."

  -- A heading needs no blank line after it to be one, which is the shape
  -- 'Kanban.Fixture' writes and the shape a hand-written body most often has.
  it "skips a leading heading the next line follows immediately" $
    excerpt "## Background\nProse." `shouldBe` "Prose."

  it "skips every heading a body opens with, not just the first" $
    excerpt "# One\n\n### Two\n\nProse." `shouldBe` "Prose."

  -- Both halves of the heading test. A cross-reference is one hash followed by
  -- a digit, and seven hashes are not an ATX heading at all; each is content.
  it "keeps a cross-reference and an over-long hash run as content" $ do
    excerpt "#123 context\n\nProse." `shouldBe` "#123 context"
    excerpt "####### context\n\nProse." `shouldBe` "####### context"

  it "skips a single-line comment such as an origin marker" $
    excerpt "<!-- issue-origin:claude -->\n\nReal description here." `shouldBe` "Real description here."

  -- The issue template's instructional comment holds a blank line, so a
  -- selector that filtered blank-line-delimited blocks would leak its
  -- remainder onto the card.
  it "skips a leading comment that spans a blank line, as the issue template's does" $
    excerpt
      "<!--\nKeep the five headings below, in this order.\n\nLeave the origin marker off.\n-->\n\n## Background\n\nWhat is true today."
      `shouldBe` "What is true today."

  it "resumes at content following the closing marker on its own line" $
    excerpt "<!-- note --> Prose follows here." `shouldBe` "Prose follows here."

  -- Fail closed. A comment its author never closed is still markup written to
  -- be invisible, so none of it reaches a card.
  it "consumes an unclosed comment rather than printing its markup" $
    excerpt "<!-- unclosed\n\nProse that is still inside it." `shouldBe` ""

  it "excerpts a body of nothing but headings and comments to the empty text" $ do
    excerpt "## Background\n\n<!-- issue-origin:claude -->" `shouldBe` ""
    excerpt "" `shouldBe` ""

  -- Structure is only what /opens/ a body. Once the paragraph has begun it is
  -- taken as it stands, heading- and comment-shaped lines included.
  it "keeps a list that opens the content as the excerpt" $
    excerpt "## Children\n- [x] #711 - A1: Save envelope\n- [ ] #712 - A2: Cache reader"
      `shouldBe` "- [x] #711 - A1: Save envelope - [ ] #712 - A2: Cache reader"

  it "keeps a fenced code block, and the heading and comment shapes inside it" $
    excerpt "```\n## Not a heading\n<!-- not a comment -->\n```\n\nProse."
      `shouldBe` "``` ## Not a heading <!-- not a comment --> ```"

  it "keeps a block quote that opens the content as the excerpt" $
    excerpt "## Background\n\n> Quoted from the report.\n\nProse." `shouldBe` "> Quoted from the report."

  -- Indentation deep enough to be an indented code block is content too, which
  -- is where CommonMark puts the boundary.
  it "keeps a four-space-indented hash line as content" $
    excerpt "    ## indented code\n\nProse." `shouldBe` "## indented code"

  it "skips a heading and a comment a CRLF body opens with" $ do
    excerpt "## Background\r\n\r\nProse." `shouldBe` "Prose."
    excerpt "<!-- issue-origin:claude -->\r\nProse." `shouldBe` "Prose."

