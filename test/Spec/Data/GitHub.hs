-- | GitHub GraphQL decoding and argument construction.
module Spec.Data.GitHub (spec) where

import qualified Data.ByteString.Lazy.Char8 as LazyByteString
import qualified Data.Text
import Kanban.Config
import Kanban.Domain
import Kanban.GitHub
  ( FetchState (..),
    decodeGitHubItems,
    graphqlArguments,
    paginationDecision,
    snapshotWarnings
  )
import Kanban.Workflow (CardStatus (..), pullRequestStatus)
import Spec.Support.Expect (flagForVariable, isLeft)
import Spec.Support.Fixtures (baseIssue, epoch)
import Spec.Support.Json
  ( checkRunJson,
    completedOnlyCheckRunJson,
    emptyAssigneesJson,
    emptyClosingIssuesJson,
    emptyLabelsJson,
    futureCheckContextJson,
    githubCappedChecksResponse,
    githubChecksResponse,
    githubMixedChecksResponse,
    githubPageWith,
    githubRerunResponse,
    githubResponse,
    issueNodeJson,
    namelessCheckRunJson,
    pullRequestNodeJson,
    queuedCheckRunJson,
    rollupJson,
    statusContextJson,
    undatedCheckRunJson
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
              [ issueNodeJson 41 [emptyLabelsJson],
                issueNodeJson 42 [emptyLabelsJson, emptyAssigneesJson]
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

    it "rejects GraphQL error responses" $
      decodeGitHubItems "{\"errors\":[{\"message\":\"boom\"}],\"data\":{}}"
        `shouldSatisfy` isLeft

    it "marks a capped connection incomplete instead of requesting beyond its limit" $
      paginationDecision 250 250 True (Just "next") `shouldBe` Right (False, Nothing, True)

    it "does not mark an exact cap incomplete when GitHub reports no next page" $
      paginationDecision 250 250 False Nothing `shouldBe` Right (False, Nothing, False)

    it "requires a cursor whenever another page is needed" $
      paginationDecision 250 100 True Nothing `shouldSatisfy` isLeft

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
              pullRequestsTruncated = False
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
