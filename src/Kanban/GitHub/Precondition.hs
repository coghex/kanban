{-# LANGUAGE OverloadedStrings #-}

-- | One item's live state, read on its own.
--
-- Every other GitHub read in this codebase fetches a board: both open
-- connections, every page, uncapped (§13). That is the right shape for a
-- refresh and the wrong shape for the one question this module answers — has
-- /this/ item changed since it was planned against? — which a persistent
-- worker has to ask at the instant it starts, about a single number, without
-- traversing a repository to find out (issue #595, requirement 8).
--
-- So this is @gh issue view@ and @gh pr view@ with an explicit field list,
-- through the same 'Kanban.GitHub.Run.runGh' every page goes through, so the
-- process it starts is recorded, group-led, and cleaned up exactly as a
-- refresh's is.
--
-- Two things bind the answer to the question that was asked, and both live
-- here rather than in either caller, because both callers ask the same way and
-- neither is in a position to check.
--
-- The first is the repository. @--repo@ names it outright on every read, the
-- way the board fetch names it as GraphQL variables and every @gh@ call in
-- "Kanban.Review.Tools" names it, so nothing about the invoking process
-- decides which repository answers: not its working directory, not that
-- directory's remotes, and not a @gh@ default repository configured for it.
-- 'Kanban.GitHub.Run.runGh' sets no @cwd@, and the resolved identity is
-- allowed to differ from the checkout the process happens to sit in (§5), so
-- an unbound read here could answer about a fork, about an unrelated checkout,
-- or fail outright in a directory that is no checkout at all — and both
-- callers would take that answer as the truth about their own target.
--
-- The second is the item. The response's own @number@ is compared with the
-- number that was requested, and a mismatch is refused rather than returned:
-- an answer about a different item is not this item's precondition, however
-- well formed it is. The refusal is an 'InvalidResponse' — the same kind an
-- unparseable body gets — precisely so it cannot be mistaken for the target
-- having moved or gone. Requirement 7 separates \"unknown\" from \"failed\",
-- and a response nobody can attribute to the requested item leaves the target
-- unknown.
--
-- The decoding is deliberately narrow. It reads only the five facts a
-- 'TargetPrecondition' is made of, plus the @number@ that identifies them, and
-- it normalizes GitHub's own spellings into the ones
-- 'Kanban.Domain.targetPreconditionForItem' produces from a board item —
-- because the two readings are compared against each other, and a comparison
-- between @\"OPEN\"@ and @\"open\"@ would report every unchanged target as
-- moved.
module Kanban.GitHub.Precondition
  ( observeTargetPrecondition,
  )
where

import Data.Aeson (Value (Object, String), eitherDecodeStrict', withObject, (.:), (.:?))
import Data.Aeson.Types (Parser, parseEither)
import Data.Char (toLower)
import Data.List (sort)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time (UTCTime)
import Kanban.Domain (ItemId (..), Repository (..), TargetPrecondition (..))
import Kanban.GitHub.Guard (GhFetchGuard)
import Kanban.GitHub.Message (compactError, decodeGhOutput)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.GitHub.Run (runGh)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | The live precondition one item currently satisfies, in the repository it
-- was asked about.
--
-- A failure is a 'ProviderError' rather than a bare message so a caller can
-- tell an unreachable network from a target that has genuinely gone: the first
-- must never be read as the second, which is the whole reason requirement 7
-- separates \"unknown\" from \"failed\".
observeTargetPrecondition :: GhFetchGuard -> Repository -> ItemId -> IO (Either ProviderError TargetPrecondition)
observeTargetPrecondition guard repository item = do
  (code, out, err) <- runGh guard repository arguments
  pure $ case code of
    ExitFailure _ ->
      Left
        ProviderError
          { providerErrorKind = RequestFailed,
            providerErrorMessage = compactError (decodeGhOutput err)
          }
    ExitSuccess -> case eitherDecodeStrict' out of
      Left message ->
        Left
          ProviderError
            { providerErrorKind = InvalidResponse,
              providerErrorMessage = "gh returned invalid JSON for " <> subject <> ": " <> Text.pack message
            }
      Right value -> case parseEither (parsePrecondition item) value of
        Left message ->
          Left
            ProviderError
              { providerErrorKind = InvalidResponse,
                providerErrorMessage = "gh omitted a field " <> subject <> " needs: " <> Text.pack message
              }
        -- Named in the request and named again in the response, and the two
        -- have to agree. Reporting the pair is what makes the refusal
        -- actionable: which item was asked for, and which one came back.
        Right (answered, precondition)
          | answered /= requested ->
              Left
                ProviderError
                  { providerErrorKind = InvalidResponse,
                    providerErrorMessage =
                      "gh answered with #"
                        <> Text.pack (show answered)
                        <> " when asked for "
                        <> subject
                  }
          | otherwise -> Right precondition
  where
    arguments = case item of
      IssueId number -> ["issue", "view", show number, "--repo", slug, "--json", "number,updatedAt,labels,state"]
      PullRequestId number -> ["pr", "view", show number, "--repo", slug, "--json", "number,updatedAt,labels,state,headRefOid"]
    slug = Text.unpack (repository.repositoryOwner <> "/" <> repository.repositoryName)
    requested = case item of
      IssueId number -> number
      PullRequestId number -> number
    subject = case item of
      IssueId number -> "issue #" <> Text.pack (show number)
      PullRequestId number -> "pull request #" <> Text.pack (show number)

-- | The precondition a response describes, paired with the item number it says
-- it is describing.
--
-- @number@ is decoded rather than assumed, and as an 'Int' rather than
-- whatever happened to be there: a response that omits it, nulls it, or spells
-- it as something other than a number leaves the item unidentified, which is
-- the same failure as a response that could not be parsed at all.
parsePrecondition :: ItemId -> Value -> Parser (Int, TargetPrecondition)
parsePrecondition item = withObject "gh item" $ \fields -> do
  number <- fields .: "number" :: Parser Int
  updatedAt <- fields .: "updatedAt" :: Parser UTCTime
  state <- fields .: "state" :: Parser Text
  labels <- fields .: "labels" :: Parser [Value]
  head' <- fields .:? "headRefOid" :: Parser (Maybe Text)
  names <- mapM labelName labels
  pure
    ( number,
      TargetPrecondition
        { preconditionItem = item,
          preconditionUpdatedAt = updatedAt,
          preconditionHead = head',
          preconditionLabels = sort names,
          -- @gh@ spells these @OPEN@, @CLOSED@, and @MERGED@; a board item
          -- spells them lowercase, and these two readings are compared with
          -- each other.
          preconditionState = Text.pack (map toLower (Text.unpack state))
        }
    )
  where
    labelName value = case value of
      Object fields -> fields .: "name"
      String name -> pure name
      _ -> fail "a label was neither an object nor a string"
