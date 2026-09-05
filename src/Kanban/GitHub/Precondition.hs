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
-- The decoding is deliberately narrow. It reads only the five facts a
-- 'TargetPrecondition' is made of, and it normalizes GitHub's own spellings
-- into the ones 'Kanban.Domain.targetPreconditionForItem' produces from a
-- board item — because the two readings are compared against each other, and a
-- comparison between @\"OPEN\"@ and @\"open\"@ would report every unchanged
-- target as moved.
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
import Kanban.Domain (ItemId (..), Repository, TargetPrecondition (..))
import Kanban.GitHub.Guard (GhFetchGuard)
import Kanban.GitHub.Message (compactError, decodeGhOutput)
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.GitHub.Run (runGh)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))

-- | The live precondition one item currently satisfies.
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
        Right precondition -> Right precondition
  where
    arguments = case item of
      IssueId number -> ["issue", "view", show number, "--json", "number,updatedAt,labels,state"]
      PullRequestId number -> ["pr", "view", show number, "--json", "number,updatedAt,labels,state,headRefOid"]
    subject = case item of
      IssueId number -> "issue #" <> Text.pack (show number)
      PullRequestId number -> "pull request #" <> Text.pack (show number)

parsePrecondition :: ItemId -> Value -> Parser TargetPrecondition
parsePrecondition item = withObject "gh item" $ \fields -> do
  updatedAt <- fields .: "updatedAt" :: Parser UTCTime
  state <- fields .: "state" :: Parser Text
  labels <- fields .: "labels" :: Parser [Value]
  head' <- fields .:? "headRefOid" :: Parser (Maybe Text)
  names <- mapM labelName labels
  pure
    TargetPrecondition
      { preconditionItem = item,
        preconditionUpdatedAt = updatedAt,
        preconditionHead = head',
        preconditionLabels = sort names,
        -- @gh@ spells these @OPEN@, @CLOSED@, and @MERGED@; a board item
        -- spells them lowercase, and these two readings are compared with each
        -- other.
        preconditionState = Text.pack (map toLower (Text.unpack state))
      }
  where
    labelName value = case value of
      Object fields -> fields .: "name"
      String name -> pure name
      _ -> fail "a label was neither an object nor a string"
