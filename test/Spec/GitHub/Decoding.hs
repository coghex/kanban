-- | Reading GitHub's GraphQL responses, and classifying the ways a gh
-- invocation fails.
module Spec.GitHub.Decoding (spec) where

import Control.Monad (foldM)
import Data.Aeson (eitherDecode)
import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import Data.Foldable (for_)
import Data.List (isInfixOf, isPrefixOf)
import qualified Data.Text
import Kanban.Config
import Kanban.Domain
import Kanban.GitHub
  ( FetchState (..),
    GhFailurePhase (..),
    advanceState,
    classifyFailure,
    compactError,
    decodeGitHubItems,
    ghFailureKind,
    graphqlArguments,
    paginationDecision,
    snapshotWarnings
  )
import Kanban.Provider (ProviderError (..), ProviderErrorKind (..))
import Kanban.Workflow (CardStatus (..), pullRequestStatus)
import Spec.Support.Expect (flagForVariable, isLeft)
import Spec.Support.Fixtures (baseIssue, epoch)
import Spec.Support.Json
  ( checkRunJson,
    completedOnlyCheckRunJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptyLabelsJson,
    emptySubIssuesJson,
    fixtureRepositoryIdentity,
    futureCheckContextJson,
    githubCappedChecksResponse,
    githubChecksResponse,
    githubMixedChecksResponse,
    githubPageWith,
    githubPageWithErrors,
    githubRerunResponse,
    githubResponse,
    graphqlErrorsOnly,
    issueNodeJson,
    namelessCheckRunJson,
    pullRequestNodeJson,
    queuedCheckRunJson,
    rollupJson,
    statusContextJson,
    subIssueConnectionJson,
    subIssueNodeJson,
    subIssuesJson,
    undatedCheckRunJson
  )
import System.IO.Error
  ( doesNotExistErrorType,
    fullErrorType,
    mkIOError,
    permissionErrorType,
    resourceVanishedErrorType
  )
import Test.Hspec

spec :: Spec
spec = do
  describe "GitHub GraphQL decoding" $ do
    it "decodes issue and pull-request fields used by the workflow" $ do
      case decodeGitHubItems (LazyByteString.pack githubResponse) of
        Left message -> expectationFailure message
        Right ([issue], [pullRequest]) -> do
          issue.issueNumber `shouldBe` 41
          issue.issueAssignees `shouldBe` [Assignee "worker"]
          issue.issueLabels `shouldBe` [Label "blocked" "d73a4a"]
          issue.issueLabelOverflow `shouldBe` 2
          issue.issueAssigneeOverflow `shouldBe` 1
          pullRequest.pullRequestLinkedIssues `shouldBe` [41]
          pullRequest.pullRequestLinkedIssueOverflow `shouldBe` 3
          pullRequest.pullRequestReviewDecision `shouldBe` ReviewApproved
          pullRequest.pullRequestMergeState `shouldBe` MergeConflicting
          pullRequest.pullRequestChecks `shouldBe` ChecksFailed 1 2 [CheckDetail "review-approved" CheckFailed]
          let warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [issue] [pullRequest] epoch True True)
          length warnings `shouldBe` 3
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "open issues; board is truncated")
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "open pull requests; board is truncated")
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "+N markers")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "reports configured truncation caps in the board's GitHub warnings" $ do
      let configuredLimits = LimitsConfig {limitsMaxOpenIssues = 5, limitsMaxOpenPullRequests = 9, limitsExcerptLines = 3}
          warnings = snapshotWarnings configuredLimits defaultWorkflowConfig (RepoSnapshot [] [] epoch True True)
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "5+ open issues")
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "9+ open pull requests")

    it "deduplicates rerun checks and treats mergeable policy blocks as protected" $ do
      case decodeGitHubItems (LazyByteString.pack githubRerunResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksPassed 3
          pullRequest.pullRequestMergeState `shouldBe` MergeProtected
          pullRequestStatus defaultWorkflowConfig pullRequest `shouldBe` StatusReady
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The retained per-check list must come out of the same latest-by-identity
    -- selection the aggregate counts use, or a superseded failure could be
    -- listed beside a passing aggregate.
    it "retains only the latest non-passing check of each identity for the details overlay" $ do
      case decodeGitHubItems (LazyByteString.pack githubMixedChecksResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) ->
          pullRequest.pullRequestChecks
            `shouldBe` ChecksFailed
              1
              3
              [ CheckDetail "integration-suite" CheckFailed,
                CheckDetail "smoke" CheckPending
              ]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- A rerun GitHub has queued but not started reports no timestamps at all,
    -- so ranking it by an empty-string timestamp let the completed failure it
    -- supersedes stay current and the card stay red. It is the newest run of
    -- its key by definition.
    it "supersedes a completed failure with the queued rerun that has no timestamps yet" $ do
      let response =
            githubChecksResponse
              2
              [ checkRunJson "review-approved" "FAILURE" "2026-07-17T14:43:13Z",
                queuedCheckRunJson "review-approved"
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) ->
          pullRequest.pullRequestChecks `shouldBe` ChecksPending 0 1 [CheckDetail "review-approved" CheckPending]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Only a run with neither timestamp is a fresh rerun: one reporting just
    -- @completedAt@ has run, and keeps that timestamp as its effective one.
    it "ranks a run reporting only completedAt by that timestamp rather than as unstarted" $ do
      let response =
            githubChecksResponse
              2
              [ completedOnlyCheckRunJson "review-approved" "FAILURE" "2026-07-17T14:50:00Z",
                checkRunJson "review-approved" "SUCCESS" "2026-07-17T14:55:00Z"
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> pullRequest.pullRequestChecks `shouldBe` ChecksPassed 1
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Two runs of one key that are equally untimestamped have no age to
    -- separate them, so the dedup keeps the one GitHub listed last. Reversing
    -- the payload reverses the winner, which is what makes the rule a rule and
    -- not an accident of which state happens to sort higher.
    it "resolves two untimestamped runs of one check by the order GitHub listed them" $ do
      let response nodes = githubChecksResponse 2 nodes
          queued = queuedCheckRunJson "review-approved"
          failed = undatedCheckRunJson "review-approved" "FAILURE"
          checksOf payload = case decodeGitHubItems (LazyByteString.pack (response payload)) of
            Left message -> Left message
            Right ([], [pullRequest]) -> Right pullRequest.pullRequestChecks
            Right values -> Left ("unexpected decoded values: " <> show values)
      checksOf [queued, failed] `shouldBe` Right (ChecksFailed 0 1 [CheckDetail "review-approved" CheckFailed])
      checksOf [failed, queued] `shouldBe` Right (ChecksPending 0 1 [CheckDetail "review-approved" CheckPending])

    -- The other rollup kind reads its age from @createdAt@, and a status
    -- context that arrives without one says nothing about being newer. It has
    -- to rank oldest, or a later payload entry would displace a timestamped
    -- context of the same key purely by position.
    it "does not let a status context with no createdAt displace the timestamped one" $ do
      let response =
            githubChecksResponse
              2
              [ statusContextJson "ci/build" "SUCCESS" (Just "2026-07-17T14:43:00Z"),
                statusContextJson "ci/build" "FAILURE" Nothing
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> pullRequest.pullRequestChecks `shouldBe` ChecksPassed 1
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    it "keeps a rollup past the context cap unknown rather than retaining the partial nodes it saw" $ do
      case decodeGitHubItems (LazyByteString.pack githubCappedChecksResponse) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksUnknown
          -- The cap is the documented §13 behavior, not an anomaly: it must
          -- not pick up the incomplete-data marker or warning that a context
          -- this build could not read would earn.
          pullRequest.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [pullRequest] epoch False False)
            `shouldSatisfy` not . any (Data.Text.isInfixOf "incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- A rollup context type this build has never seen -- GitHub adding a
    -- kind, or an edge case returning a bare node -- used to fail the whole
    -- page, so every refresh of a repository containing one such PR broke
    -- permanently. It degrades that one pull request instead.
    it "keeps a rollup holding an unknown context type unknown instead of failing the page" $ do
      let response =
            githubPageWith
              []
              [ pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 2 [checkRunJson "build-test" "SUCCESS" "2026-01-03T00:00:00Z", futureCheckContextJson]],
                pullRequestNodeJson 10 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 1 [checkRunJson "build-test" "SUCCESS" "2026-01-03T00:00:00Z"]]
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [degraded, intact]) -> do
          degraded.pullRequestNumber `shouldBe` 9
          degraded.pullRequestChecks `shouldBe` ChecksUnknown
          degraded.pullRequestDataGaps `shouldBe` [ChecksUndecodable]
          intact.pullRequestNumber `shouldBe` 10
          intact.pullRequestChecks `shouldBe` ChecksPassed 1
          intact.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [degraded, intact] epoch False False)
            `shouldSatisfy` any (Data.Text.isInfixOf "PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The same fail-closed treatment covers a type this build knows that
    -- arrives without a field its decode needs; "undecodable" is about the
    -- context node, not only about its typename.
    it "keeps a rollup holding a recognized context missing a required field unknown" $ do
      let response =
            githubPageWith
              []
              [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollupJson 1 [namelessCheckRunJson]]]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [pullRequest]) -> do
          pullRequest.pullRequestChecks `shouldBe` ChecksUnknown
          pullRequest.pullRequestDataGaps `shouldBe` [ChecksUndecodable]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- GitHub's schema makes every nested connection nullable, and a
    -- partial-error response nulls out exactly the fields that errored. One
    -- "labels": null used to discard the entire refresh.
    it "decodes a null nested connection as no nodes and a gap on that item alone" $ do
      let response =
            githubPageWith
              []
              [ pullRequestNodeJson 9 ["\"labels\":null", emptyClosingIssuesJson],
                pullRequestNodeJson 10 ["\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]}", emptyClosingIssuesJson]
              ]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([], [degraded, intact]) -> do
          degraded.pullRequestLabels `shouldBe` []
          degraded.pullRequestLabelOverflow `shouldBe` 0
          degraded.pullRequestDataGaps `shouldBe` [LabelsUnavailable]
          intact.pullRequestLabels `shouldBe` [Label "bug" "d73a4a"]
          intact.pullRequestDataGaps `shouldBe` []
          snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [] [degraded, intact] epoch False False)
            `shouldSatisfy` any (Data.Text.isInfixOf "PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Absence is the other form the same anomaly takes, and it has to reach
    -- issues as well as pull requests.
    it "decodes an absent nested connection on an issue as a gap rather than as no assignees" $ do
      let response =
            githubPageWith
              [ issueNodeJson 41 [emptyLabelsJson, emptySubIssuesJson],
                issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson, emptySubIssuesJson]
              ]
              [pullRequestNodeJson 9 [emptyLabelsJson, "\"closingIssuesReferences\":null"]]
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([degraded, intact], [pullRequest]) -> do
          degraded.issueAssignees `shouldBe` []
          degraded.issueAssigneeOverflow `shouldBe` 0
          degraded.issueDataGaps `shouldBe` [AssigneesUnavailable]
          intact.issueDataGaps `shouldBe` []
          pullRequest.pullRequestLinkedIssues `shouldBe` []
          pullRequest.pullRequestDataGaps `shouldBe` [LinkedIssuesUnavailable]
          let warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot [degraded, intact] [pullRequest] epoch False False)
          warnings `shouldSatisfy` any (Data.Text.isInfixOf "Issue #41, PR #9: incomplete data")
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- §12's native membership source: the children in GitHub's order, each
    -- with the repository that owns it, and the summary counts progress is
    -- read from.
    it "decodes native sub-issue relationships with their owning repositories" $ do
      let response =
            githubPageWith
              [ issueNodeJson
                  700
                  [ emptyLabelsJson,
                    emptyAssigneesJson,
                    subIssuesJson
                      0
                      [ subIssueNodeJson 12 fixtureRepositoryIdentity False,
                        subIssueNodeJson 11 "elsewhere/other" True
                      ]
                      1
                      2
                  ]
              ]
              []
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([issue], []) -> do
          issue.issueSubIssues
            `shouldBe` SubIssuesReported
              ( SubIssueRelationships
                  (Data.Text.pack fixtureRepositoryIdentity)
                  [ SubIssueLink 12 (Data.Text.pack fixtureRepositoryIdentity) False,
                    SubIssueLink 11 "elsewhere/other" True
                  ]
                  0
                  1
                  2
              )
          issue.issueDataGaps `shouldBe` []
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- Either half missing leaves nothing that can be read as "this tracker
    -- has no children", so both fail closed to an unreported answer and the
    -- item is marked incomplete rather than empty.
    it "treats an absent, null, or incomplete sub-issue answer as unreported rather than empty" $ do
      let issueWith connections = githubPageWith [issueNodeJson 700 ([emptyLabelsJson, emptyAssigneesJson] <> connections)] []
          decodedGaps response = case decodeGitHubItems (LazyByteString.pack response) of
            Left message -> Left message
            Right ([issue], []) -> Right (issue.issueSubIssues, issue.issueDataGaps)
            Right values -> Left ("unexpected decoded values: " <> show values)
      -- Neither field requested back at all.
      decodedGaps (issueWith []) `shouldBe` Right (SubIssuesUnreported, [SubIssuesUnavailable])
      -- The shape a partial-error response nulls an errored field into.
      decodedGaps (issueWith ["\"subIssues\":null", "\"subIssuesSummary\":{\"total\":0,\"completed\":0}"])
        `shouldBe` Right (SubIssuesUnreported, [SubIssuesUnavailable])
      decodedGaps (issueWith [subIssueConnectionJson 0 [], "\"subIssuesSummary\":null"])
        `shouldBe` Right (SubIssuesUnreported, [SubIssuesUnavailable])
      -- Delivered children, but fewer than GitHub says exist: what arrived is
      -- kept, and the item still says the answer is not the whole story.
      decodedGaps (issueWith [subIssuesJson 1 [subIssueNodeJson 12 fixtureRepositoryIdentity False] 0 2])
        `shouldBe` Right
          ( SubIssuesReported
              ( SubIssueRelationships
                  (Data.Text.pack fixtureRepositoryIdentity)
                  [SubIssueLink 12 (Data.Text.pack fixtureRepositoryIdentity) False]
                  1
                  0
                  2
              ),
            [SubIssuesUnavailable]
          )
      -- And a positively empty answer is neither incomplete nor a gap.
      decodedGaps (issueWith [emptySubIssuesJson])
        `shouldBe` Right (SubIssuesReported (SubIssueRelationships (Data.Text.pack fixtureRepositoryIdentity) [] 0 0 0), [])

    -- A connection GitHub did deliver stays as strict as every other one.
    it "still fails the page when a delivered sub-issue connection is malformed" $ do
      let issueWith connections = LazyByteString.pack (githubPageWith [issueNodeJson 700 ([emptyLabelsJson, emptyAssigneesJson] <> connections)] [])
      -- totalCount below the node list it came with
      decodeGitHubItems (issueWith ["\"subIssues\":{\"totalCount\":0,\"nodes\":[" <> subIssueNodeJson 12 fixtureRepositoryIdentity False <> "]},\"subIssuesSummary\":{\"total\":1,\"completed\":0}"])
        `shouldSatisfy` isLeft
      -- a child with no owning repository, which membership cannot be decided without
      decodeGitHubItems (issueWith ["\"subIssues\":{\"totalCount\":1,\"nodes\":[{\"number\":12,\"state\":\"OPEN\"}]},\"subIssuesSummary\":{\"total\":1,\"completed\":0}"])
        `shouldSatisfy` isLeft
      -- a summary missing a count progress is read from
      decodeGitHubItems (issueWith [subIssueConnectionJson 0 [], "\"subIssuesSummary\":{\"total\":1}"])
        `shouldSatisfy` isLeft

    -- Without GitHub's own identity for the queried repository there is no
    -- way to tell a local child from a foreign one, so no child may be
    -- treated as local.
    it "fails closed when the response never said which repository it is" $ do
      let response =
            "{\"data\":{\"repository\":{\"issues\":{\"nodes\":["
              <> issueNodeJson 700 [emptyLabelsJson, emptyAssigneesJson, subIssuesJson 0 [subIssueNodeJson 12 fixtureRepositoryIdentity False] 0 1]
              <> "],\"pageInfo\":{\"hasNextPage\":false}},\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
      case decodeGitHubItems (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right ([issue], []) -> do
          issue.issueSubIssues `shouldBe` SubIssuesUnreported
          issue.issueDataGaps `shouldBe` [SubIssuesUnavailable]
        Right values -> expectationFailure ("unexpected decoded values: " <> show values)

    -- The banner is one line, so many degraded items are named up to a limit
    -- and the rest counted -- visibly truncated rather than silently dropped.
    it "names the first few incomplete items and counts the rest" $ do
      let issues = [(baseIssue number []) {issueDataGaps = [AssigneesUnavailable]} | number <- [1 .. 5]]
          warnings = snapshotWarnings defaultLimitsConfig defaultWorkflowConfig (RepoSnapshot issues [] epoch False False)
      warnings `shouldSatisfy` any (Data.Text.isInfixOf "Issue #1, Issue #2, Issue #3 +2 more: incomplete data")

    -- A connection GitHub did deliver stays strict. These are not one item's
    -- missing field but a response shape the decoder cannot reason about, and
    -- degrading them would hide real corruption behind an amber card.
    it "still fails the page when a present nested connection is malformed" $ do
      let pageWithLabels labels = LazyByteString.pack (githubPageWith [] [pullRequestNodeJson 9 [labels, emptyClosingIssuesJson]])
      -- totalCount below the node list it came with
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":0,\"nodes\":[{\"name\":\"bug\",\"color\":\"d73a4a\"}]}")
        `shouldSatisfy` isLeft
      -- no totalCount at all
      decodeGitHubItems (pageWithLabels "\"labels\":{\"nodes\":[]}") `shouldSatisfy` isLeft
      -- a totalCount that is not a number
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":\"many\",\"nodes\":[]}") `shouldSatisfy` isLeft
      -- a node missing a field the item parser requires
      decodeGitHubItems (pageWithLabels "\"labels\":{\"totalCount\":1,\"nodes\":[{\"name\":\"bug\"}]}") `shouldSatisfy` isLeft
      -- a connection that is not an object
      decodeGitHubItems (pageWithLabels "\"labels\":5") `shouldSatisfy` isLeft

    -- The rollup's own container is not a per-context anomaly either.
    it "still fails the page when the rollup container itself is malformed" $ do
      let pageWithRollup rollup = LazyByteString.pack (githubPageWith [] [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson, rollup]])
      decodeGitHubItems (pageWithRollup "\"statusCheckRollup\":{\"contexts\":{\"nodes\":[]}}") `shouldSatisfy` isLeft
      decodeGitHubItems (pageWithRollup "\"statusCheckRollup\":{}") `shouldSatisfy` isLeft

    it "rejects a response that reported errors and delivered no repository" $
      decodeGitHubItems "{\"errors\":[{\"message\":\"boom\"}],\"data\":{}}"
        `shouldSatisfy` isLeft

    -- Errors with nothing usable behind them still fail the refresh, but the
    -- line section 17 shows now says what GitHub said. It used to read
    -- "contained errors" and never the rate limit, NOT_FOUND, or field
    -- problem that actually stopped the request.
    it "carries the GraphQL error messages into a fatal failure" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly ["API rate limit exceeded for user ID 1"])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> message `shouldSatisfy` isInfixOf "API rate limit exceeded for user ID 1"

    -- Every message, in the order GitHub reported them, folded onto the one
    -- line the banner has: GraphQL messages routinely arrive with newlines.
    it "joins every GraphQL message in order onto one line" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly ["first problem", "second\\n   problem"])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> message `shouldSatisfy` isInfixOf "first problem; second problem"

    -- The messages are GitHub's and unbounded, and they share that line with
    -- the counts and the snapshot time, so the aggregate is capped exactly
    -- where gh's stderr already is.
    it "caps the joined GraphQL messages at the provider message bound" $
      case decodeGitHubItems (LazyByteString.pack (graphqlErrorsOnly [replicate 400 'a', replicate 400 'b'])) of
        Right values -> expectationFailure ("unexpected decode: " <> show values)
        Left message -> do
          message `shouldSatisfy` isInfixOf (replicate 400 'a' <> "; " <> replicate 98 'b')
          message `shouldSatisfy` (not . isInfixOf (replicate 99 'b'))

    -- A page Aeson cannot read fails on Aeson's own text, which never passed
    -- through the structural checks and so never met the errors GitHub sent.
    -- Those failures are exactly the ones with an explanation available, and
    -- it has to survive them too -- not only the shapes the decoder itself
    -- rejects.
    it "keeps the GraphQL messages when the page itself cannot be decoded" $ do
      let respondWith nodes = LazyByteString.pack (githubPageWithErrors ["Something went wrong while executing your query"] Nothing nodes [])
          -- An item missing a scalar the parser requires.
          numberlessIssue = respondWith ["{\"title\":\"no number here\"}"]
          -- A requested connection that is not an object at all.
          brokenConnection =
            "{\"errors\":[{\"message\":\"Something went wrong while executing your query\"}],"
              <> "\"data\":{\"repository\":{\"issues\":5,\"pullRequests\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false}}}}}"
      for_ [numberlessIssue, brokenConnection] $ \response ->
        case decodeGitHubItems response of
          Right values -> expectationFailure ("unexpected decode: " <> show values)
          Left message -> message `shouldSatisfy` isInfixOf "Something went wrong while executing your query"

    let initialFetchState =
          FetchState
            { fetchedIssues = [],
              fetchedPullRequests = [],
              issueCursor = Nothing,
              pullRequestCursor = Nothing,
              fetchMoreIssues = True,
              fetchMorePullRequests = True,
              issuesTruncated = False,
              pullRequestsTruncated = False,
              fetchSubIssues = True,
              fetchWarnings = []
            }

    -- GraphQL answers a partly-resolvable query with data and errors
    -- together. This page is structurally complete -- both requested
    -- connections, both paginated to the end -- so the board shows what did
    -- arrive and the messages become the warning saying it is not everything.
    it "keeps a structurally complete response that carried errors, as a warning" $ do
      let response =
            githubPageWithErrors
              ["Could not resolve reviewDecision for pull request 9"]
              Nothing
              [issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]]
              [pullRequestNodeJson 9 [emptyLabelsJson, emptyClosingIssuesJson]]
      case eitherDecode (LazyByteString.pack response) of
        Left message -> expectationFailure message
        Right page -> case advanceState defaultLimitsConfig initialFetchState page of
          Left providerError -> expectationFailure ("unexpectedly failed: " <> show providerError)
          Right state -> do
            map (.issueNumber) state.fetchedIssues `shouldBe` [41]
            map (.pullRequestNumber) state.fetchedPullRequests `shouldBe` [9]
            state.fetchWarnings
              `shouldBe` ["GitHub could not resolve part of this refresh: Could not resolve reviewDecision for pull request 9"]

    -- The decoder cannot tell a field GitHub nulled from one nobody asked
    -- for; the fetch can, and a board that stopped asking has no missing
    -- answer to mark every card amber over.
    it "downgrades an unreported sub-issue answer to unrequested once the fetch has stopped asking" $ do
      let response = githubPageWith [issueNodeJson 41 [emptyLabelsJson, emptyAssigneesJson]] []
          foldPage state = case eitherDecode (LazyByteString.pack response) of
            Left message -> Left message
            Right page -> case advanceState defaultLimitsConfig state page of
              Left providerError -> Left (show providerError)
              Right next -> Right [(issue.issueSubIssues, issue.issueDataGaps) | issue <- next.fetchedIssues]
      foldPage initialFetchState `shouldBe` Right [(SubIssuesUnreported, [SubIssuesUnavailable])]
      foldPage initialFetchState {fetchSubIssues = False} `shouldBe` Right [(SubIssuesNotRequested, [])]

    -- A refresh spans pages and only the last one builds the result, so a
    -- warning an earlier page raised has to survive the pages after it -- and
    -- none of the items it arrived with may be dropped on the way.
    it "accumulates one warning per page without losing decoded items" $ do
      let pageJson messages cursor issueNumber pullRequestNumber =
            githubPageWithErrors
              messages
              cursor
              [issueNodeJson issueNumber [emptyLabelsJson, emptyAssigneesJson]]
              [pullRequestNodeJson pullRequestNumber [emptyLabelsJson, emptyClosingIssuesJson]]
          pages =
            [ pageJson ["field errored on issue 41"] (Just "cursor-1") 41 9,
              pageJson ["field errored on issue 42"] Nothing 42 10
            ]
      case traverse (eitherDecode . LazyByteString.pack) pages of
        Left message -> expectationFailure message
        Right decoded -> case foldM (advanceState defaultLimitsConfig) initialFetchState decoded of
          Left providerError -> expectationFailure ("unexpectedly failed: " <> show providerError)
          Right state -> do
            map (.issueNumber) state.fetchedIssues `shouldBe` [41, 42]
            map (.pullRequestNumber) state.fetchedPullRequests `shouldBe` [9, 10]
            state.fetchWarnings
              `shouldBe` [ "GitHub could not resolve part of this refresh: field errored on issue 41",
                           "GitHub could not resolve part of this refresh: field errored on issue 42"
                         ]

    -- Errors beside data the decoder cannot reason about are not a partial
    -- response: a connection this request asked for is missing outright. The
    -- page fails as it always did, and the messages explain the hole instead
    -- of leaving a bare shape complaint with no cause.
    it "fails a response whose errors came with an incomplete page, keeping the messages" $ do
      let response =
            "{\"errors\":[{\"message\":\"Timeout resolving pullRequests\"}],\"data\":{\"repository\":"
              <> "{\"issues\":{\"nodes\":[],\"pageInfo\":{\"hasNextPage\":false,\"endCursor\":null}}}}}"
      case eitherDecode response of
        Left message -> expectationFailure message
        Right page -> case advanceState defaultLimitsConfig initialFetchState page of
          Right state -> expectationFailure ("unexpectedly advanced: " <> show state.fetchWarnings)
          Left providerError -> do
            providerError.providerErrorKind `shouldBe` InvalidResponse
            providerError.providerErrorMessage
              `shouldBe` "GitHub response omitted the pull requests connection: Timeout resolving pullRequests"

    it "marks a capped connection incomplete instead of requesting beyond its limit" $
      paginationDecision 250 250 True (Just "next") `shouldBe` Right (False, Nothing, True)

    it "does not mark an exact cap incomplete when GitHub reports no next page" $
      paginationDecision 250 250 False Nothing `shouldBe` Right (False, Nothing, False)

    it "requires a cursor whenever another page is needed" $
      paginationDecision 250 100 True Nothing `shouldSatisfy` isLeft

  describe "GitHub failure classification" $ do
    -- Verbatim from gh 2.83.1: the signed-out text it prints instead of
    -- running a command, the same state reported by `gh auth status`, and
    -- what it prints when a token is present but rejected. Phrase matching
    -- only earns its keep if it still recognizes these.
    it "reports a real gh authentication failure as authentication" $ do
      classifyFailure
        ( "To get started with GitHub CLI, please run:  gh auth login\n"
            <> "Alternatively, populate the GH_TOKEN environment variable with a GitHub API authentication token."
        )
        `shouldBe` AuthenticationRequired
      classifyFailure "You are not logged into any GitHub hosts. To log in, run: gh auth login" `shouldBe` AuthenticationRequired
      classifyFailure "gh: Bad credentials (HTTP 401)" `shouldBe` AuthenticationRequired
      -- The API's own 401 body, which gh passes through for endpoints that
      -- answer with it rather than with Bad credentials.
      classifyFailure "gh: Requires authentication (HTTP 401)" `shouldBe` AuthenticationRequired
      classifyFailure "GraphQL: Authentication required (repository)" `shouldBe` AuthenticationRequired
      -- Recognition is case-insensitive, and does not depend on a phrase
      -- arriving beside any of the others.
      classifyFailure "BAD CREDENTIALS" `shouldBe` AuthenticationRequired
      classifyFailure "gh: You Are Not Logged Into github.com" `shouldBe` AuthenticationRequired

    -- The word "token" says nothing about credentials. AUTH REQUIRED over a
    -- rate limiter's token bucket sends a fully authenticated user off to log
    -- in again for what is a transient server error.
    it "does not read a bare token mention as an authentication failure" $ do
      classifyFailure "GraphQL: token bucket exhausted, retry after 60s" `shouldBe` RequestFailed
      classifyFailure "GraphQL: invalid pagination token" `shouldBe` RequestFailed
      classifyFailure "gh: OAuth application rate limit reached" `shouldBe` RequestFailed

    -- Reclassifying those is only half of it: what the user is left with has
    -- to be gh's own text, folded onto one line rather than replaced by a
    -- category name.
    it "preserves gh's own text for a failure that is not about credentials" $ do
      compactError "GraphQL: token bucket exhausted,\n  retry after 60s"
        `shouldBe` "GraphQL: token bucket exhausted, retry after 60s"
      compactError "GraphQL: invalid pagination token"
        `shouldBe` "GraphQL: invalid pagination token"

  describe "GraphQL argument construction" $ do
    -- GitHub permits all-numeric accounts and repositories, and gh's typed
    -- -F flag coerces all-digit values to Int and true/false to Boolean.
    -- The fixture below is the worst case: every String! variable holds a
    -- value that -F would coerce into a type the query rejects.
    let numericRepository = Repository "/tmp/board" "12345" "2048"
        pagedState =
          FetchState
            { fetchedIssues = [],
              fetchedPullRequests = [],
              issueCursor = Just "42",
              pullRequestCursor = Just "true",
              fetchMoreIssues = True,
              fetchMorePullRequests = True,
              issuesTruncated = False,
              pullRequestsTruncated = False,
              fetchSubIssues = True,
              fetchWarnings = []
            }
        firstPageState = pagedState {issueCursor = Nothing, pullRequestCursor = Nothing}
        pagedArguments = graphqlArguments defaultLimitsConfig numericRepository pagedState

    it "passes every GraphQL String variable raw" $ do
      flagForVariable "owner" pagedArguments `shouldBe` Just "-f"
      flagForVariable "name" pagedArguments `shouldBe` Just "-f"
      flagForVariable "issueCursor" pagedArguments `shouldBe` Just "-f"
      flagForVariable "pullRequestCursor" pagedArguments `shouldBe` Just "-f"
      flagForVariable "query" pagedArguments `shouldBe` Just "-f"

    it "keeps the genuinely typed variables on the typed flag" $ do
      flagForVariable "issuePageSize" pagedArguments `shouldBe` Just "-F"
      flagForVariable "pullRequestPageSize" pagedArguments `shouldBe` Just "-F"
      flagForVariable "fetchIssues" pagedArguments `shouldBe` Just "-F"
      flagForVariable "fetchPullRequests" pagedArguments `shouldBe` Just "-F"

    it "carries coercible owner, name, and cursor values through verbatim" $ do
      pagedArguments `shouldContain` ["-f", "owner=12345"]
      pagedArguments `shouldContain` ["-f", "name=2048"]
      pagedArguments `shouldContain` ["-f", "issueCursor=42"]
      pagedArguments `shouldContain` ["-f", "pullRequestCursor=true"]

    it "omits absent cursors so the first request starts at the first page" $ do
      let firstPageArguments = graphqlArguments defaultLimitsConfig numericRepository firstPageState
      flagForVariable "issueCursor" firstPageArguments `shouldBe` Nothing
      flagForVariable "pullRequestCursor" firstPageArguments `shouldBe` Nothing

    -- §12's second membership source rides the one paged query rather than
    -- adding a request per tracker, and it asks for GitHub's own identity for
    -- the repository so a child's owner can be compared against something the
    -- same response reported.
    it "asks for native sub-issues and the repository identity inside the single page query" $ do
      let query = concat [argument | argument <- pagedArguments, "query=" `isPrefixOf` argument]
      length (filter ("query=" `isPrefixOf`) pagedArguments) `shouldBe` 1
      query `shouldSatisfy` isInfixOf "subIssues(first: 100)"
      query `shouldSatisfy` isInfixOf "repository { nameWithOwner }"
      query `shouldSatisfy` isInfixOf "subIssuesSummary { total completed }"
      query `shouldSatisfy` isInfixOf "nameWithOwner\n    issues("

    -- A field the schema does not have is rejected at validation, so the only
    -- way to keep refreshing such a deployment is to stop asking for it.
    it "drops the sub-issue selection entirely once the fetch has stopped asking" $ do
      let query = concat [argument | argument <- graphqlArguments defaultLimitsConfig numericRepository pagedState {fetchSubIssues = False}, "query=" `isPrefixOf` argument]
      query `shouldSatisfy` not . isInfixOf "subIssues"
      query `shouldSatisfy` isInfixOf "nameWithOwner"
      query `shouldSatisfy` isInfixOf "assignees(first: 10)"

  -- NOT INSTALLED is a claim about the installation, so only a launch that
  -- failed because there was nothing runnable to launch may make it. The
  -- phase is what carries that distinction: the same errno means opposite
  -- things before and after the child exists.
  describe "gh process failure phases" $ do
    it "reports a gh that is not on PATH as a missing executable" $
      ghFailureKind GhLaunching (mkIOError doesNotExistErrorType "gh" Nothing (Just "gh"))
        `shouldBe` ExecutableMissing

    it "reports a gh that cannot be executed as a missing executable" $
      ghFailureKind GhLaunching (mkIOError permissionErrorType "gh" Nothing (Just "gh"))
        `shouldBe` ExecutableMissing

    it "reports a launch that ran out of resources as a failed request, not a missing gh" $
      ghFailureKind GhLaunching (mkIOError fullErrorType "runInteractiveProcess" Nothing Nothing)
        `shouldBe` RequestFailed

    it "reports a failure after the child exists as a failed request" $
      ghFailureKind GhRunning (mkIOError resourceVanishedErrorType "hGetContents" Nothing Nothing)
        `shouldBe` RequestFailed

    -- The regression itself: gh had already launched, so whatever the errno
    -- says, it is not missing. A classifier that read the exception alone
    -- would send a user with a working gh off to install it.
    it "never blames the installation for a does-not-exist error raised after the child exists" $
      ghFailureKind GhRunning (mkIOError doesNotExistErrorType "hGetContents" Nothing (Just "gh"))
        `shouldBe` RequestFailed
