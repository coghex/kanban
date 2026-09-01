-- | The stdio MCP re-entry that serves Kanban's review tools to a Claude
-- review thread (MODEL-15, D-15): the FIFO endpoint, the re-entered server,
-- the schema translation, and the whole proxied path driven end to end
-- through a fake @claude@ that spawns the server off its own recorded
-- launch configuration.
--
-- The end-to-end fixtures re-enter this suite's own binary — @Spec.main@
-- diverts on the same argv @kanban --review-tools@ takes — so the process
-- the fake spawns runs the real 'serveReviewTools' against the real client,
-- exactly as an install's @claude@ would. The in-process groups drive that
-- same server function over pipes with the test standing in as each side,
-- which is where the protocol edges live: correlation, oversized frames,
-- and every way an endpoint can fail.
module Spec.Agent.ToolReentry (spec) where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Exception (finally)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Bits ((.&.))
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.List (isPrefixOf)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as TextEncoding
import Kanban.Domain (WorkflowConfig (..), defaultWorkflowConfig)
import Kanban.Models (ProviderName (..), defaultRoster)
import Kanban.Review
  ( ReviewAnswer (..),
    ReviewEvent (..),
    ReviewQuestion (..),
    ReviewQuestionKind (..),
    ReviewRequestId (..),
    answerReviewQuestion,
    beginIssueReview,
    githubIssueViewArguments,
    stopReviewClient,
  )
import Kanban.ReviewToolServer
  ( ReviewToolEndpoint (..),
    createReviewToolEndpoint,
    mcpToolDescriptor,
    readEndpointCall,
    serveReviewTools,
    teardownReviewToolEndpoint,
    writeEndpointReply,
  )
import Kanban.Solve (ProviderAdapter (..), adapterFor)
import Spec.Support.Env (withTemporaryCacheRoot)
import Spec.Support.Expect (shouldMention, shouldNotMention)
import Spec.Support.Process
  ( ClaudeReviewFixture (..),
    claudeMcpToolCall,
    claudeReviewTurn,
    protocolWarnings,
    recordedClaudeInput,
    recordedGitHubInvocations,
    recordedMcpServerPid,
    recordedMcpTraffic,
    shouldHaveBeenSwept,
    turnCompletions,
    waitForReviewEvents,
    withClaudeMcpReviewClient,
  )
import System.Directory (doesDirectoryExist, getXdgDirectory, listDirectory, XdgDirectory (XdgCache))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, hClose, hFlush, hSetBinaryMode, hSetBuffering)
import System.Posix.Files (fileMode, getFileStatus, isNamedPipe)
import System.Process (createPipe)
import System.Timeout (timeout)
import Test.Hspec

spec :: Spec
spec = do
  describe "the review tool endpoint" $ do
    -- The review's isolation clause: a fresh private directory per thread,
    -- 0700 whatever the umask, holding the two 0600 FIFOs and nothing else.
    it "creates a fresh 0700 directory of 0600 FIFOs under the private review-tools root, and unlinks it whole" $
      withTemporaryCacheRoot $ \_ -> do
        root <- getXdgDirectory XdgCache ("kanban" </> "review-tools")
        first <- requireEndpoint =<< createReviewToolEndpoint
        second <- requireEndpoint =<< createReviewToolEndpoint
        first.endpointDirectory `shouldNotBe` second.endpointDirectory
        mapM_ (\endpoint -> endpoint.endpointDirectory `shouldSatisfy` (root `isPrefixOf`)) [first, second]
        directoryStatus <- getFileStatus first.endpointDirectory
        (fileMode directoryStatus .&. 0o777) `shouldBe` 0o700
        entries <- listDirectory first.endpointDirectory
        entries `shouldMatchList` ["calls", "replies"]
        mapM_
          ( \entry -> do
              status <- getFileStatus (first.endpointDirectory </> entry)
              isNamedPipe status `shouldBe` True
              (fileMode status .&. 0o777) `shouldBe` 0o600
          )
          entries
        teardownReviewToolEndpoint first
        doesDirectoryExist first.endpointDirectory `shouldReturn` False
        teardownReviewToolEndpoint second
        listDirectory root `shouldReturn` []

  describe "the re-entered server's own protocol" $ do
    -- The two methods that are protocol rather than tools are answered in
    -- the server, and nothing about them reaches the endpoint: the parent
    -- would have nothing truer to say.
    it "answers initialize with its identity, echoing the client's protocol version" $
      withReentryServer $ \server -> do
        reply <- roundTrip server (request 1 "initialize" (object ["protocolVersion" .= ("2024-11-05" :: Text)]))
        textAt ["result", "protocolVersion"] reply `shouldBe` Just "2024-11-05"
        textAt ["result", "serverInfo", "name"] reply `shouldBe` Just "kanban"
        textAt ["jsonrpc"] reply `shouldBe` Just "2.0"

    -- Notifications expect no answer and get none; every other id-bearing
    -- method is forwarded rather than judged, because knowing what is
    -- servable is the parent's knowledge — its loop is what answers an
    -- unservable method with the protocol error, and the server relays the
    -- refusal verbatim. That the forwarded frame here is the request /after/
    -- the notification is also the proof the notification went nowhere.
    it "answers ping, ignores notifications, and relays the parent's refusal of an unknown method" $
      withReentryServer $ \server -> do
        sendToServer server (object ["jsonrpc" .= jsonRpc, "method" .= ("notifications/initialized" :: Text)])
        ping <- roundTrip server (request 2 "ping" (object []))
        fieldAt ["result"] ping `shouldBe` Just (object [])
        sendToServer server (request 3 "resources/list" (object []))
        forwarded <- nextForwarded server
        textAt ["method"] forwarded `shouldBe` Just "resources/list"
        writeEndpointReply
          server.serverEndpoint
          (object ["id" .= (3 :: Int), "error" .= object ["code" .= (-32601 :: Int), "message" .= ("unservable" :: Text)]])
          `shouldReturn` Right ()
        refused <- nextServed server
        fieldAt ["id"] refused `shouldBe` Just (Number 3)
        fieldAt ["error", "code"] refused `shouldBe` Just (Number (-32601))

  describe "the re-entered server's proxying" $ do
    it "forwards tools requests verbatim and answers each under its own id, however the replies are ordered" $
      withReentryServer $ \server -> do
        sendToServer server (request 1 "tools/call" (object ["name" .= ("kanban_prompt_user" :: Text), "arguments" .= object []]))
        sendToServer server (request 2 "tools/list" (object []))
        firstForwarded <- nextForwarded server
        secondForwarded <- nextForwarded server
        fieldAt ["id"] firstForwarded `shouldBe` Just (Number 1)
        textAt ["method"] firstForwarded `shouldBe` Just "tools/call"
        textAt ["params", "name"] firstForwarded `shouldBe` Just "kanban_prompt_user"
        fieldAt ["id"] secondForwarded `shouldBe` Just (Number 2)
        -- The parent answers the later request first; each reply must still
        -- land under the id that asked.
        replyFromParent server (Number 2) (object ["tools" .= ([] :: [Value])])
        replyFromParent server (Number 1) (object ["content" .= ([] :: [Value]), "isError" .= False])
        first <- nextServed server
        second <- nextServed server
        fieldAt ["id"] first `shouldBe` Just (Number 2)
        fieldAt ["id"] second `shouldBe` Just (Number 1)

    -- The review's concurrency clause: a frame larger than any pipe buffer
    -- crosses whole in both directions — the request with the 100,000-char
    -- comment the GitHub tool admits, and a reply larger still.
    it "carries frames larger than the pipe buffer whole, in both directions" $
      withReentryServer $ \server -> do
        let bigComment = Text.replicate 100000 "c"
        sendToServer server (request 4 "tools/call" (object ["name" .= ("kanban_github_issue" :: Text), "arguments" .= object ["operation" .= ("update" :: Text), "issue" .= (1 :: Int), "comment" .= bigComment]]))
        forwarded <- nextForwarded server
        textAt ["params", "arguments", "comment"] forwarded `shouldBe` Just bigComment
        let bigAnswer = Text.replicate 200000 "x"
            bigResult = object ["content" .= [object ["type" .= ("text" :: Text), "text" .= bigAnswer]], "isError" .= False]
        replyFromParent server (Number 4) bigResult
        served <- nextServed server
        fieldAt ["id"] served `shouldBe` Just (Number 4)
        fieldAt ["result"] served `shouldBe` Just bigResult

    it "exits cleanly when the CLI closes the session" $
      withReentryServer $ \server -> do
        hClose server.serverInput
        awaitServerExit server `shouldReturn` ExitSuccess

  describe "the re-entered server's endpoint failures" $ do
    it "refuses an endpoint that does not exist, without serving anything" $ do
      (inputRead, inputWrite) <- createPipe
      (_, outputWrite) <- createPipe
      exitCode <- serveReviewTools inputRead outputWrite "/nonexistent/endpoint"
      exitCode `shouldBe` ExitFailure 1
      hClose inputWrite

    -- Requirement 5's teardown half, at the server: an endpoint that is
    -- gone fails the calls still waiting as tool-level failures the model
    -- reads, and the process exits rather than serving on.
    it "fails a pending call and exits when the endpoint is torn down" $
      withReentryServer $ \server -> do
        sendToServer server (request 7 "tools/call" (object ["name" .= ("kanban_prompt_user" :: Text), "arguments" .= object []]))
        _ <- nextForwarded server
        teardownReviewToolEndpoint server.serverEndpoint
        failed <- nextServed server
        fieldAt ["id"] failed `shouldBe` Just (Number 7)
        fieldAt ["result", "isError"] failed `shouldBe` Just (Bool True)
        awaitServerExit server `shouldReturn` ExitFailure 1

    it "fails a pending call and exits on a frame it cannot read at all" $
      withReentryServer $ \server -> do
        sendToServer server (request 8 "tools/call" (object ["name" .= ("kanban_prompt_user" :: Text), "arguments" .= object []]))
        _ <- nextForwarded server
        ByteString.hPutStr server.serverEndpoint.endpointReplies "not a frame\n"
        failed <- nextServed server
        fieldAt ["id"] failed `shouldBe` Just (Number 8)
        fieldAt ["result", "isError"] failed `shouldBe` Just (Bool True)
        awaitServerExit server `shouldReturn` ExitFailure 1

    -- A frame that parses but resolves nothing is malformed all the same: an
    -- id with no payload must not consume the call it names and hand the CLI
    -- a response carrying no result — the call fails and the server exits,
    -- exactly as it does for a frame that is not JSON.
    it "fails a pending call and exits on a reply carrying an id but no payload" $
      withReentryServer $ \server -> do
        sendToServer server (request 8 "tools/call" (object ["name" .= ("kanban_prompt_user" :: Text), "arguments" .= object []]))
        _ <- nextForwarded server
        writeEndpointReply server.serverEndpoint (object ["id" .= (8 :: Int)]) `shouldReturn` Right ()
        failed <- nextServed server
        fieldAt ["id"] failed `shouldBe` Just (Number 8)
        fieldAt ["result", "isError"] failed `shouldBe` Just (Bool True)
        awaitServerExit server `shouldReturn` ExitFailure 1

    it "fails a pending call and exits on a reply carrying both a result and an error" $
      withReentryServer $ \server -> do
        sendToServer server (request 9 "tools/call" (object ["name" .= ("kanban_prompt_user" :: Text), "arguments" .= object []]))
        _ <- nextForwarded server
        writeEndpointReply
          server.serverEndpoint
          (object ["id" .= (9 :: Int), "result" .= object [], "error" .= object ["code" .= (-32603 :: Int)]])
          `shouldReturn` Right ()
        failed <- nextServed server
        fieldAt ["id"] failed `shouldBe` Just (Number 9)
        fieldAt ["result", "isError"] failed `shouldBe` Just (Bool True)
        awaitServerExit server `shouldReturn` ExitFailure 1

  describe "the served tool list" $ do
    -- The translation itself, held to the adapter's declarations by
    -- construction and to the contract by value: the two tools, no
    -- revision tool (D-14 as amended), no app-server wrapper, and the
    -- workflow label vocabulary of the configuration in force.
    it "is the Claude adapter's declarations translated, label vocabulary included" $ do
      let served = map mcpToolDescriptor ((adapterFor ClaudeProvider).adapterReviewTools defaultRoster blessedConfig)
      map (textAt ["name"]) served `shouldBe` [Just "kanban_prompt_user", Just "kanban_github_issue"]
      map (textAt ["type"]) served `shouldBe` [Nothing, Nothing]
      let renderedGithub = encodedText (served !! 1)
      renderedGithub `shouldMention` "reviewed:blessed"
      renderedGithub `shouldMention` "inputSchema"
      mapM_ (\descriptor -> encodedText descriptor `shouldNotMention` "kanban_run_claude") served

  describe "the proxied path, end to end" $ do
    -- The acceptance's first bullet: a fake claude calls the GitHub tool
    -- through the re-entry and receives the parent's answer — the same gh
    -- vocabulary, the same events, the same authorization — while the
    -- session's own handshake and tool list came off the same wire.
    it "serves a kanban_github_issue read through the re-entry, with the Codex path's events" $
      withClaudeMcpReviewClient defaultWorkflowConfig issueEchoGh (githubReadTurn 844) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <-
          waitForReviewEvents
            "the github call and the verdict"
            fixture.claudeReviewEvents
            (\events -> not (null (turnCompletions events)) && not (null [() | ReviewGitHubFinished _ _ <- events]))
        traffic <- recordedMcpTraffic fixture.claudeReviewRecordings 0
        (initializeReply, listReply, callReply) <- threeFrames traffic
        initializeReply `shouldMention` "\"protocolVersion\":\"2025-06-18\""
        listReply `shouldMention` "kanban_prompt_user"
        listReply `shouldMention` "kanban_github_issue"
        listReply `shouldNotMention` "kanban_run_claude"
        callReply `shouldMention` "gh-answer-for-844"
        callReply `shouldMention` "\"isError\":false"
        [(started, finished)] <- pure [(started, finished) | ReviewGitHubStarted _ started <- recorded, ReviewGitHubFinished _ finished <- recorded]
        started `shouldMention` "Reading issue #844"
        either (const "failed") id finished `shouldMention` "gh-answer-for-844"
        invocations <- recordedGitHubInvocations fixture.claudeReviewRecordings
        invocations `shouldBe` [map Text.pack (githubIssueViewArguments "coghex/kanban" 844)]

    -- The acceptance's refusal bullet, per the review's event correction: a
    -- cross-issue call is a tool failure the caller reads beside the
    -- existing protocol warning, with no start or finish event and no gh
    -- process at all.
    -- Also the wire's own proof that the served list is the configuration
    -- in force: this client runs a non-default approval label, and the
    -- tools/list reply this same session read back carries it.
    it "refuses a call naming another thread's issue as a tool failure, spawning nothing" $
      withClaudeMcpReviewClient blessedConfig issueEchoGh (githubReadTurn 999) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        recorded <- waitForReviewEvents "the refusal and the verdict" fixture.claudeReviewEvents (\events -> not (null (turnCompletions events)) && not (null (protocolWarnings events)))
        traffic <- recordedMcpTraffic fixture.claudeReviewRecordings 0
        (_, listReply, callReply) <- threeFrames traffic
        listReply `shouldMention` "reviewed:blessed"
        callReply `shouldMention` "\"isError\":true"
        callReply `shouldMention` "may only access the issue owned by this review thread"
        [message | ReviewProtocolWarning _ message <- recorded]
          `shouldBe` ["kanban_github_issue may only access the issue owned by this review thread"]
        [event | event@ReviewGitHubStarted {} <- recorded] `shouldBe` []
        [event | event@ReviewGitHubFinished {} <- recorded] `shouldBe` []
        recordedGitHubInvocations fixture.claudeReviewRecordings `shouldReturn` []

    -- Requirement 5: the call blocks — the fake sits in a read on the reply
    -- — until the user's answer arrives through the same entry point the
    -- app-server path uses, and the answer document is the same one.
    it "blocks kanban_prompt_user until the user answers, and completes with that answer" $
      withClaudeMcpReviewClient defaultWorkflowConfig issueEchoGh questionTurn $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        asked <- waitForReviewEvents "the question" fixture.claudeReviewEvents (not . null . questionRequests)
        (requestId, question) <- soleQuestion asked
        question.reviewQuestionText `shouldBe` "Ship it?"
        question.reviewQuestionKind `shouldBe` QuestionChoice
        -- Still blocked: the turn cannot have completed, because the fake
        -- reads the reply before it writes its verdict.
        turnCompletions asked `shouldBe` []
        answerReviewQuestion fixture.claudeReviewClient requestId (ReviewAnswer ["yes"] Nothing) `shouldReturn` Right ()
        _ <- waitForReviewEvents "the verdict after the answer" fixture.claudeReviewEvents (not . null . turnCompletions)
        traffic <- recordedMcpTraffic fixture.claudeReviewRecordings 0
        (_, _, answerReply) <- threeFrames traffic
        -- The answer document travels as the reply's text content, so it
        -- appears here in its escaped form.
        answerReply `shouldMention` "\\\"selected\\\":[\\\"yes\\\"]"
        answerReply `shouldMention` "\"isError\":false"

    -- Requirement 7 and the acceptance's shutdown bullet: a client stopped
    -- with a question outstanding fails that call rather than hanging,
    -- sweeps the server process, and leaves no endpoint behind.
    it "fails an outstanding question on shutdown and leaves no server process and no FIFO behind" $
      withClaudeMcpReviewClient defaultWorkflowConfig issueEchoGh questionTurn $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        asked <- waitForReviewEvents "the question" fixture.claudeReviewEvents (not . null . questionRequests)
        (requestId, _) <- soleQuestion asked
        serverPid <- recordedMcpServerPid fixture.claudeReviewRecordings 0
        stopReviewClient fixture.claudeReviewClient
        answered <- answerReviewQuestion fixture.claudeReviewClient requestId (ReviewAnswer ["yes"] Nothing)
        answered `shouldSatisfy` either (const True) (const False)
        shouldHaveBeenSwept serverPid "the re-entered review tool server"
        root <- getXdgDirectory XdgCache ("kanban" </> "review-tools")
        rootExists <- doesDirectoryExist root
        leftBehind <- if rootExists then listDirectory root else pure []
        leftBehind `shouldBe` []

    -- The review's correlation clause: two thread endpoints, the same MCP
    -- request id on each, and each caller reads its own thread's answer —
    -- which is also the per-thread authorization holding across two live
    -- threads at once.
    it "keeps colliding request ids on two thread endpoints apart" $
      withClaudeMcpReviewClient defaultWorkflowConfig issueEchoGh perIssueGithubTurn $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        beginIssueReview fixture.claudeReviewClient 845 `shouldReturn` Right ()
        _ <- waitForReviewEvents "both verdicts" fixture.claudeReviewEvents ((>= 2) . length . turnCompletions)
        -- Each process is identified by the opening message it read, not by
        -- its position in the spawn log: the two spawns race to record
        -- themselves, so spawn order is not begin order. What must hold is
        -- that each process's one reply answers the issue that process
        -- asked about, and that both issues were asked about at all.
        answered <- mapM
          ( \index -> do
              written <- recordedClaudeInput fixture.claudeReviewRecordings index
              opening <- case written of
                first : _ -> pure first
                [] -> fail "a fake read no opening message"
              ownIssue <-
                if "#844" `Text.isInfixOf` opening
                  then pure ("844" :: Text)
                  else
                    if "#845" `Text.isInfixOf` opening
                      then pure "845"
                      else fail ("an opening message names neither issue: " <> Text.unpack opening)
              (_, _, callReply) <- threeFrames =<< recordedMcpTraffic fixture.claudeReviewRecordings index
              callReply `shouldMention` ("gh-answer-for-" <> ownIssue)
              callReply `shouldNotMention` (if ownIssue == "844" then "gh-answer-for-845" else "gh-answer-for-844")
              pure ownIssue
          )
          [0, 1]
        answered `shouldMatchList` ["844", "845"]

    it "carries a tool answer larger than the pipe buffer whole through the re-entry" $
      withClaudeMcpReviewClient defaultWorkflowConfig bigOutputGh (githubReadTurn 844) $ \fixture -> do
        beginIssueReview fixture.claudeReviewClient 844 `shouldReturn` Right ()
        _ <- waitForReviewEvents "the verdict" fixture.claudeReviewEvents (not . null . turnCompletions)
        traffic <- recordedMcpTraffic fixture.claudeReviewRecordings 0
        (_, _, callReply) <- threeFrames traffic
        Text.length callReply `shouldSatisfy` (> 200000)
        callReply `shouldMention` "\"isError\":false"

-- ---------------------------------------------------------------------------
-- The in-process server fixture
-- ---------------------------------------------------------------------------

-- | 'serveReviewTools' running in-process over pipes, against a real
-- endpoint the test drives through the parent-side helpers — the same code
-- the client's serving loop uses, so the two halves under test are exactly
-- the two halves an install runs.
data ReentryServer = ReentryServer
  { serverEndpoint :: ReviewToolEndpoint,
    serverInput :: Handle,
    serverOutput :: Handle,
    serverExit :: MVar ExitCode
  }

withReentryServer :: (ReentryServer -> IO result) -> IO result
withReentryServer action =
  withTemporaryCacheRoot $ \_ -> do
    endpoint <- requireEndpoint =<< createReviewToolEndpoint
    (inputRead, inputWrite) <- createPipe
    (outputRead, outputWrite) <- createPipe
    hSetBinaryMode inputWrite True
    hSetBuffering inputWrite LineBuffering
    hSetBinaryMode outputRead True
    exitVar <- newEmptyMVar
    _ <- forkIO (serveReviewTools inputRead outputWrite endpoint.endpointDirectory >>= putMVar exitVar)
    -- Torn down even on a failed assertion, so a red example does not leave
    -- an endpoint on disk or a served loop behind: the teardown is also what
    -- makes a still-running server exit.
    action (ReentryServer endpoint inputWrite outputRead exitVar)
      `finally` teardownReviewToolEndpoint endpoint

requireEndpoint :: Either Text ReviewToolEndpoint -> IO ReviewToolEndpoint
requireEndpoint = either (fail . ("the endpoint could not be created: " <>) . Text.unpack) pure

request :: Int -> Text -> Value -> Value
request requestId method params =
  object ["jsonrpc" .= jsonRpc, "id" .= requestId, "method" .= method, "params" .= params]

jsonRpc :: Text
jsonRpc = "2.0"

sendToServer :: ReentryServer -> Value -> IO ()
sendToServer server value = do
  LazyByteString.hPutStr server.serverInput (encode value)
  LazyByteString.hPutStr server.serverInput "\n"
  hFlush server.serverInput

-- | One line of what the server wrote back to its client, decoded. Bounded,
-- so a reply that never comes fails the test instead of hanging it.
nextServed :: ReentryServer -> IO Value
nextServed server = decodeFrame "a served reply" =<< awaitFor "a served reply" (ByteString.hGetLine server.serverOutput)

-- | One frame the server forwarded to the parent, read through the
-- parent-side helper the client's own serving loop uses.
nextForwarded :: ReentryServer -> IO Value
nextForwarded server = decodeFrame "a forwarded frame" =<< awaitFor "a forwarded frame" (readEndpointCall server.serverEndpoint)

replyFromParent :: ReentryServer -> Value -> Value -> IO ()
replyFromParent server requestId result =
  writeEndpointReply server.serverEndpoint (object ["id" .= requestId, "result" .= result]) `shouldReturn` Right ()

roundTrip :: ReentryServer -> Value -> IO Value
roundTrip server value = sendToServer server value >> nextServed server

awaitServerExit :: ReentryServer -> IO ExitCode
awaitServerExit server = awaitFor "the server's exit" (takeMVar server.serverExit)

awaitFor :: String -> IO a -> IO a
awaitFor what action = maybe (fail ("timed out waiting for " <> what)) pure =<< timeout 10000000 action

decodeFrame :: String -> ByteString.ByteString -> IO Value
decodeFrame what line = case eitherDecode (LazyByteString.fromStrict line) of
  Left message -> fail (what <> " is not JSON (" <> message <> "): " <> show line)
  Right value -> pure value

-- ---------------------------------------------------------------------------
-- The end-to-end scripts and helpers
-- ---------------------------------------------------------------------------

-- | A fake @gh@ whose answer names the issue it was asked about, so two
-- concurrent threads' replies are distinguishable by content.
issueEchoGh :: [ByteString.ByteString]
issueEchoGh = ["printf '{\"payload\":\"gh-answer-for-%s\"}\\n' \"$3\""]

-- | A fake @gh@ whose answer is far larger than any pipe buffer.
bigOutputGh :: [ByteString.ByteString]
bigOutputGh =
  [ "payload=$(head -c 200000 /dev/zero | tr '\\0' 'x')",
    "printf '{\"payload\":\"%s\"}\\n' \"$payload\""
  ]

-- | One turn that calls the GitHub tool for @issueNumber@ and then closes
-- with a verdict. The thread's own issue is 844 in every test that uses
-- this, so 844 is the authorized call and anything else the refused one.
githubReadTurn :: Int -> [ByteString.ByteString]
githubReadTurn issueNumber =
  claudeReviewTurn "weighing it" "reviewing it"
    <> [ claudeMcpToolCall 1 "kanban_github_issue" ("{\"operation\":\"read\",\"issue\":" <> ByteString.pack (show issueNumber) <> "}"),
         verdictLine 844
       ]

-- | One turn that asks the user a question — and, exactly like a real
-- tool-using turn, cannot write its verdict until the answer arrives,
-- because @mcp_ask@ blocks on the reply.
questionTurn :: [ByteString.ByteString]
questionTurn =
  claudeReviewTurn "weighing it" "reviewing it"
    <> [ claudeMcpToolCall 7 "kanban_prompt_user" "{\"id\":\"q1\",\"question\":\"Ship it?\",\"kind\":\"choice\",\"options\":[{\"id\":\"yes\",\"label\":\"Yes\"},{\"id\":\"no\",\"label\":\"No\"}]}",
         verdictLine 844
       ]

-- | One turn that reads its own review's issue, told apart by the opening
-- prompt — both processes deliberately use MCP request id 1, which is the
-- collision under test.
perIssueGithubTurn :: [ByteString.ByteString]
perIssueGithubTurn =
  claudeReviewTurn "weighing it" "reviewing it"
    <> [ "case \"$message\" in",
         "  *'#844'*) " <> claudeMcpToolCall 1 "kanban_github_issue" "{\"operation\":\"read\",\"issue\":844}" <> " ; " <> verdictLine 844 <> " ;;",
         "  *) " <> claudeMcpToolCall 1 "kanban_github_issue" "{\"operation\":\"read\",\"issue\":845}" <> " ; " <> verdictLine 845 <> " ;;",
         "esac"
       ]

-- | The result line closing a turn with a schema-satisfying verdict.
verdictLine :: Int -> ByteString.ByteString
verdictLine issueNumber =
  "printf '%s\\n' '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"structured_output\":{\"issue\":"
    <> ByteString.pack (show issueNumber)
    <> ",\"stage\":\"revision\",\"approved\":false,\"reviewerRoute\":\"codex\",\"models\":[\"Opus 5 xhigh\"],\"commentUrl\":null,\"blockingReasons\":[]}}'"

-- | The three replies every MCP session here records: the bootstrap's
-- @initialize@ and @tools\/list@, then the one tool call the turn made.
threeFrames :: [Text] -> IO (Text, Text, Text)
threeFrames traffic = case traffic of
  [initializeReply, listReply, callReply] -> pure (initializeReply, listReply, callReply)
  other -> fail ("expected the two bootstrap replies and one call reply, got " <> show other)

questionRequests :: [ReviewEvent] -> [(ReviewRequestId, ReviewQuestion)]
questionRequests recorded = [(requestId, question) | ReviewQuestionRequested _ requestId question <- recorded]

soleQuestion :: [ReviewEvent] -> IO (ReviewRequestId, ReviewQuestion)
soleQuestion recorded = case questionRequests recorded of
  [one] -> pure one
  other -> fail ("expected exactly one question, got " <> show (length other))

blessedConfig :: WorkflowConfig
blessedConfig = defaultWorkflowConfig {approvalLabel = "reviewed:blessed"}

encodedText :: Value -> Text
encodedText = TextEncoding.decodeUtf8 . LazyByteString.toStrict . encode

textAt :: [Text] -> Value -> Maybe Text
textAt path value = case fieldAt path value of
  Just (String text) -> Just text
  _ -> Nothing

fieldAt :: [Text] -> Value -> Maybe Value
fieldAt [] value = Just value
fieldAt (key : keys) (Object fields) = KeyMap.lookup (Key.fromText key) fields >>= fieldAt keys
fieldAt _ _ = Nothing
