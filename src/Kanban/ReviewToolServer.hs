-- | The stdio MCP re-entry that serves Kanban's review tools to a @claude@
-- review thread (D-15), and the FIFO endpoint it proxies over.
--
-- The @claude@ CLI has no inline tool declaration, so a Claude review
-- thread's tools cannot travel in @thread\/start@ the way the Codex thread's
-- do. What it does have is MCP: the launch hands it a configuration naming
-- Kanban's own binary, re-entered as a stdio MCP server, as the only server
-- the session may load. That re-entered process carries no tool logic and
-- performs no GitHub or user interaction of its own — it answers
-- @initialize@ and @ping@, because those are pure protocol, and forwards
-- everything else over a per-thread FIFO endpoint to the Kanban process that
-- started the review, which is where the schemas, the authorization, and the
-- runners already live.
--
-- Both halves of that exchange are here, beside the endpoint they share, so
-- the paths, the framing, and the shutdown contract have one spelling:
--
-- * the /endpoint/ — a fresh private directory holding two FIFOs, @calls@
--   (server writes, parent reads) and @replies@ (parent writes, server
--   reads), created by the parent before the provider is spawned and
--   unlinked by the parent on every failure and shutdown path;
-- * the /server/ — 'serveReviewTools', what @kanban --review-tools@ runs,
--   a line pump between the CLI's stdio and the endpoint that fails its
--   pending calls and exits when the endpoint is absent, closed, or
--   malformed.
--
-- Framing is one JSON value per line on every stream, each stream written
-- by exactly one process under one lock, so a frame larger than @PIPE_BUF@
-- cannot interleave with another writer's. Requests keep the CLI's own
-- JSON-RPC ids: the endpoint serves one provider process, so those ids are
-- unambiguous here, and the parent keys its state by endpoint, so two
-- processes both asking as @id 1@ never collide.
--
-- Every FIFO end here is driven by polling — nonblocking reads and writes
-- with a short delay between empty attempts — never by waiting on GHC's IO
-- manager. That is not a style choice: the IO manager waits on kqueue, and
-- macOS's kqueue proved unable to report a FIFO's readiness when the data
-- was already present at registration time, so any read that parked mid-
-- frame slept on bytes that had long arrived (observed on Darwin 25, and
-- GHC parks even a blocking descriptor's read there whenever its readiness
-- probe says not-ready). Polling needs no readiness notification at all,
-- and on the parent side it also leaves every serving thread interruptible
-- for teardown. What polling costs is the free end-of-file signal: the
-- re-entered server instead reads the parent's teardown off the endpoint
-- itself — teardown unlinks it, so a server whose idle poll finds the FIFO
-- gone, or whose forward write fails against a closed read end, fails its
-- pending calls and exits.
--
-- Deliberately free of every other Kanban module above "Kanban.Paths" and
-- "Kanban.Review.Diagnostics": the parent's dispatch, events, and tool
-- runners stay in "Kanban.Review", which is what keeps this module usable
-- from @app\/Main.hs@ and the test binary without loading a roster, a
-- configuration, or a repository.
module Kanban.ReviewToolServer
  ( ReviewToolEndpoint (..),
    createReviewToolEndpoint,
    teardownReviewToolEndpoint,
    readEndpointCall,
    writeEndpointReply,
    decodeEndpointCall,
    proxyResult,
    proxyError,
    mcpToolDescriptor,
    mcpToolResult,
    mcpToolAllowance,
    reviewToolServerConfig,
    reviewToolServerFlag,
    reviewToolServerName,
    serveReviewTools,
  )
where

import Control.Concurrent (MVar, forkIO, newEmptyMVar, newMVar, takeMVar, threadDelay, tryPutMVar, withMVar)
import Control.Concurrent.MVar (modifyMVar, modifyMVar_)
import Control.Exception (IOException, try)
import Control.Monad (forever, void, when)
import Data.Aeson (Value (..), eitherDecode, encode, object, (.=))
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as LazyByteString
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Paths (createPrivateDirectory)
import Kanban.Review.Diagnostics (exceptionText)
import System.Directory (XdgDirectory (XdgCache), doesPathExist, getXdgDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (BufferMode (..), Handle, IOMode (..), hClose, hFlush, hPutStrLn, hSetBinaryMode, hSetBuffering, openFile, stderr)
import System.Posix.Files (createNamedPipe, setFileMode)
import System.Posix.Temp (mkdtemp)

-- | The MCP server name the launch configuration registers Kanban's
-- re-entry under, and so the prefix of the tool names the session must be
-- allowed to call.
reviewToolServerName :: Text
reviewToolServerName = "kanban"

-- | The long option that re-enters Kanban as this server, without its
-- leading dashes — the one spelling "Kanban.CLI" parses and
-- 'reviewToolServerConfig' writes into the launch configuration.
reviewToolServerFlag :: String
reviewToolServerFlag = "review-tools"

-- | How the launch names one of this server's tools to the CLI's permission
-- gate: the MCP namespace the CLI derives from the server name.
mcpToolAllowance :: Text -> Text
mcpToolAllowance toolName = "mcp__" <> reviewToolServerName <> "__" <> toolName

-- | The @--mcp-config@ value one review session is launched with: exactly
-- one server, Kanban's own binary re-entered against this thread's endpoint.
--
-- The executable is the caller's to supply because it must be the exact
-- binary that is already running — 'System.Environment.getExecutablePath',
-- the same re-entry precedent "Kanban.Worker" set — rather than whatever
-- @kanban@ a PATH lookup would find.
reviewToolServerConfig :: FilePath -> FilePath -> Value
reviewToolServerConfig executable endpointDirectory =
  object
    [ "mcpServers"
        .= object
          [ Key.fromText reviewToolServerName
              .= object
                [ "type" .= ("stdio" :: Text),
                  "command" .= executable,
                  "args" .= ["--" <> reviewToolServerFlag, endpointDirectory]
                ]
          ]
    ]

-- | One Codex dynamic-tool declaration as MCP lists it: the same name,
-- description, and @inputSchema@, with the @\"type\": \"function\"@ wrapper —
-- the app-server's vocabulary, which MCP does not have — dropped.
--
-- A translation rather than a second declaration, so the served list cannot
-- drift from 'Kanban.ProviderAdapter.adapterReviewTools': whatever the
-- adapter declares, label vocabulary included, is what @tools\/list@ says.
mcpToolDescriptor :: Value -> Value
mcpToolDescriptor (Object fields) = Object (KeyMap.delete "type" fields)
mcpToolDescriptor value = value

-- | An MCP @tools\/call@ result: the text the tool produced, and whether it
-- failed. A refusal travels this way — a tool-level failure the model reads —
-- rather than as a JSON-RPC error or a crash.
mcpToolResult :: Bool -> Text -> Value
mcpToolResult failed text =
  object
    [ "content" .= [object ["type" .= ("text" :: Text), "text" .= text]],
      "isError" .= failed
    ]

-- ---------------------------------------------------------------------------
-- The endpoint
-- ---------------------------------------------------------------------------

-- | The parent's half of one review thread's proxy: the private directory,
-- and the two FIFOs opened read-write so neither open can block and neither
-- stream can reach end-of-file while the parent still holds it. The
-- directory existing /is/ the endpoint being live: teardown unlinks it,
-- and a server whose idle poll finds it gone fails whatever was still
-- pending and exits.
data ReviewToolEndpoint = ReviewToolEndpoint
  { endpointDirectory :: FilePath,
    -- | The stream the server writes requests to; the parent only reads it.
    endpointCalls :: Handle,
    -- | What 'readEndpointCall' has read past the frame it returned. One
    -- reader — the connection's serving loop — so a plain reference.
    endpointReadBuffer :: IORef ByteString.ByteString,
    -- | The stream the parent writes replies to; the server only reads it.
    endpointReplies :: Handle,
    -- | Serializes every parent write to 'endpointReplies', so two replies —
    -- a tool result racing a user's answer, say — cannot interleave however
    -- large either frame is.
    endpointWriteLock :: MVar ()
  }

endpointCallsName :: FilePath
endpointCallsName = "calls"

endpointRepliesName :: FilePath
endpointRepliesName = "replies"

-- | Create one review thread's endpoint: a fresh @0700@ directory under
-- Kanban's private XDG cache root, holding the two @0600@ FIFOs, both
-- already open on the parent side.
--
-- Fresh per thread via 'mkdtemp' rather than named after anything, so two
-- Kanban processes — or two clients in one process — can never hand two
-- provider sessions the same rendezvous. A failure after the directory
-- exists removes it before reporting, so no failure path leaves a FIFO
-- behind.
createReviewToolEndpoint :: IO (Either Text ReviewToolEndpoint)
createReviewToolEndpoint = do
  prepared <- try $ do
    root <- getXdgDirectory XdgCache ("kanban" </> "review-tools")
    createPrivateDirectory XdgCache root
    directory <- mkdtemp (root </> "endpoint.")
    setFileMode directory 0o700
    pure directory
  case prepared of
    Left exception -> pure (Left (creationFailure exception))
    Right directory -> do
      opened <- try $ do
        let callsPath = directory </> endpointCallsName
            repliesPath = directory </> endpointRepliesName
        createNamedPipe callsPath 0o600
        createNamedPipe repliesPath 0o600
        setFileMode callsPath 0o600
        setFileMode repliesPath 0o600
        calls <- openEndpointStream callsPath
        replies <- openEndpointStream repliesPath
        buffered <- newIORef ByteString.empty
        ReviewToolEndpoint directory calls buffered replies <$> newMVar ()
      case opened of
        Right endpoint -> pure (Right endpoint)
        Left exception -> do
          ignoreIOException (removePathForcibly directory)
          pure (Left (creationFailure exception))
  where
    creationFailure :: IOException -> Text
    creationFailure = exceptionText

-- | Open one of the endpoint's FIFOs on the parent side. Read-write on both
-- deliberately: a FIFO opened for reading alone reports end-of-file the
-- moment no writer holds it, and one opened for writing alone cannot be
-- opened at all until a reader does — holding both ends makes the open
-- immediate and leaves the parent's own teardown as the only thing that can
-- end either stream. Unbuffered because the parent's I/O on these is the
-- nonblocking polling this module's header explains, which does its own
-- accumulation.
openEndpointStream :: FilePath -> IO Handle
openEndpointStream path = do
  handle <- openFile path ReadWriteMode
  hSetBinaryMode handle True
  hSetBuffering handle NoBuffering
  pure handle

-- | How long a parent-side poll sleeps when a nonblocking read found no
-- frame or a nonblocking write found the pipe full. Short enough that a
-- tool call's round trip is imperceptible beside the model turn around it.
endpointPollMicros :: Int
endpointPollMicros = 2000

-- | Unlink one endpoint completely: both parent handles, both FIFOs, and
-- the directory. The unlink is what tells a still-running server to fail
-- its pending calls and exit — its idle poll checks for exactly this — and
-- the closed read end is what fails the server's next forward instantly.
-- Every step is best-effort and idempotent, because shutdown and a
-- connection's own terminal cleanup may both reach here.
teardownReviewToolEndpoint :: ReviewToolEndpoint -> IO ()
teardownReviewToolEndpoint endpoint = do
  ignoreIOException (hClose endpoint.endpointReplies)
  ignoreIOException (hClose endpoint.endpointCalls)
  ignoreIOException (removePathForcibly endpoint.endpointDirectory)

-- | One frame the server forwarded, as the parent reads it. Waits — by
-- polling, per the module header — until a whole line has arrived, and
-- throws once the endpoint is torn down (the closed handle fails the next
-- read attempt), which is one of the two ways the serving loop ends.
readEndpointCall :: ReviewToolEndpoint -> IO ByteString.ByteString
readEndpointCall endpoint = do
  line <- pollReadLine endpoint.endpointCalls endpoint.endpointReadBuffer (threadDelay endpointPollMicros >> pure True)
  maybe (ioError (userError "the review tool endpoint reader was asked to stop")) pure line

-- | Write one reply frame, whole, under the endpoint's write lock — again
-- by polling, so a frame larger than the pipe's buffer is pushed as the
-- server drains it, and a teardown that closes the handle fails the write
-- out of its wait instead of leaving it parked.
writeEndpointReply :: ReviewToolEndpoint -> Value -> IO (Either Text ())
writeEndpointReply endpoint value = do
  outcome <-
    try
      ( withMVar endpoint.endpointWriteLock $ \() ->
          pollWriteLine endpoint.endpointReplies (LazyByteString.toStrict (encode value) <> "\n")
      ) ::
      IO (Either IOException ())
  pure $ case outcome of
    Left exception -> Left ("review tool endpoint write failed: " <> exceptionText exception)
    Right () -> Right ()

-- | Read one line off a nonblocking FIFO handle by polling, running @idle@
-- between empty attempts; 'Nothing' when @idle@ says to stop waiting. A
-- closed or invalid handle throws out of the wait as an ordinary
-- 'IOException'.
pollReadLine :: Handle -> IORef ByteString.ByteString -> IO Bool -> IO (Maybe ByteString.ByteString)
pollReadLine handle buffer idle = awaitLine
  where
    awaitLine = do
      buffered <- readIORef buffer
      case ByteString.elemIndex '\n' buffered of
        Just newline -> do
          writeIORef buffer (ByteString.drop (newline + 1) buffered)
          pure (Just (ByteString.take newline buffered))
        Nothing -> do
          chunk <- ByteString.hGetNonBlocking handle 65536
          if ByteString.null chunk
            then do
              continue <- idle
              if continue then awaitLine else pure Nothing
            else writeIORef buffer (buffered <> chunk) >> awaitLine

-- | Push one whole line into a nonblocking FIFO handle by polling, so a
-- frame larger than the pipe's buffer goes out as the far side drains it.
-- A write end whose reader is gone throws, which each caller reads as its
-- own teardown signal.
pollWriteLine :: Handle -> ByteString.ByteString -> IO ()
pollWriteLine handle = push
  where
    push remaining
      | ByteString.null remaining = pure ()
      | otherwise = do
          rest <- ByteString.hPutNonBlocking handle remaining
          if ByteString.length rest == ByteString.length remaining
            then threadDelay endpointPollMicros >> push remaining
            else push rest

-- | Read one forwarded frame into the request it carries: the CLI's own
-- id, the method, and the params (an empty object where the CLI sent none).
decodeEndpointCall :: ByteString.ByteString -> Either Text (Value, Text, Value)
decodeEndpointCall line = case eitherDecode (LazyByteString.fromStrict line) of
  Left message -> Left ("received a frame that is not JSON: " <> Text.pack message)
  Right value -> case (lookupField "id" value, lookupField "method" value) of
    (Just requestId, Just (String method)) ->
      Right (requestId, method, maybe (object []) id (lookupField "params" value))
    _ -> Left "received a frame naming no request id and method"

-- | A reply resolving one forwarded request.
proxyResult :: Value -> Value -> Value
proxyResult requestId result = object ["id" .= requestId, "result" .= result]

-- | A reply refusing one forwarded request at the protocol level. Tool
-- refusals do not travel this way — they are 'mcpToolResult' failures — so
-- this is only for a method the parent does not serve at all.
proxyError :: Value -> Int -> Text -> Value
proxyError requestId code message =
  object ["id" .= requestId, "error" .= object ["code" .= code, "message" .= message]]

-- ---------------------------------------------------------------------------
-- The re-entered server
-- ---------------------------------------------------------------------------

-- | What one forwarded request is still waiting for: the id to answer under
-- and the method it named, which decides the shape a failed endpoint answers
-- it with.
data PendingCall = PendingCall
  { pendingCallId :: Value,
    pendingCallMethod :: Text
  }

-- | The MCP methods the server answers itself. Everything here is protocol
-- rather than tools: @initialize@ negotiates, @ping@ keeps the session
-- alive, and neither says anything the parent knows better.
--
-- Everything else with an id is forwarded verbatim — @tools\/list@ and
-- @tools\/call@ above all, so the served list and every call outcome are the
-- parent's answers and this process carries no tool knowledge to drift.
serveReviewTools :: Handle -> Handle -> FilePath -> IO ExitCode
serveReviewTools input output directory = do
  hSetBinaryMode input True
  hSetBinaryMode output True
  hSetBuffering output LineBuffering
  opened <-
    try
      ( do
          -- The write side first, because its open is the existence probe: a
          -- nonblocking write open succeeds only against the read end the
          -- parent already holds, so an endpoint the parent never created,
          -- already unlinked, or already closed refuses right here.
          calls <- openFile (directory </> endpointCallsName) WriteMode
          hSetBinaryMode calls True
          hSetBuffering calls NoBuffering
          replies <- openFile (directory </> endpointRepliesName) ReadMode
          hSetBinaryMode replies True
          hSetBuffering replies NoBuffering
          pure (calls, replies)
      ) ::
      IO (Either IOException (Handle, Handle))
  case opened of
    Left exception -> do
      hPutStrLn stderr ("kanban review tool server: the endpoint at " <> directory <> " is not usable: " <> Text.unpack (exceptionText exception))
      pure (ExitFailure 1)
    Right (calls, replies) -> do
      pending <- newMVar (Map.empty :: Map LazyByteString.ByteString PendingCall)
      repliesBuffer <- newIORef ByteString.empty
      outputLock <- newMVar ()
      callsLock <- newMVar ()
      finished <- newEmptyMVar
      let finish code = void (tryPutMVar finished code)
          -- Best-effort by design: a write that fails means the CLI is
          -- gone, and its own end-of-file on this process's stdin is what
          -- reports that.
          writeClient value =
            ignoreIOException . withMVar outputLock $ \() -> do
              LazyByteString.hPutStr output (encode value)
              LazyByteString.hPutStr output "\n"
              hFlush output
          forwardCall value = do
            outcome <-
              try
                ( withMVar callsLock $ \() ->
                    pollWriteLine calls (LazyByteString.toStrict (encode value) <> "\n")
                ) ::
                IO (Either IOException ())
            pure (either (const False) (const True) outcome)
          -- The endpoint has failed: everything still waiting is answered
          -- as the tool-level failure the protocol can carry, and the
          -- process exits rather than serving a session it can no longer
          -- proxy.
          failEndpoint = do
            abandoned <- modifyMVar pending (\held -> pure (Map.empty, Map.elems held))
            mapM_ (writeClient . closedEndpointReply) abandoned
            finish (ExitFailure 1)
          -- Read the CLI's requests to their end. End-of-file on stdin is
          -- the CLI closing the session, which is this server's one
          -- successful exit.
          clientLoop = do
            _ <- try (forever (ByteString.hGetLine input >>= handleClientLine pending writeClient forwardCall failEndpoint)) :: IO (Either IOException ())
            finish ExitSuccess
          -- An idle moment on the replies stream: keep waiting exactly as
          -- long as the endpoint still exists on disk. Teardown unlinks it,
          -- which is this server's whole signal that the parent is gone —
          -- polling has no end-of-file to read it from.
          repliesIdle = do
            threadDelay endpointPollMicros
            doesPathExist (directory </> endpointRepliesName)
          -- Read the parent's replies until the endpoint is gone or a frame
          -- cannot be read at all. Either way the calls this server
          -- forwarded must fail rather than hang, and the process must not
          -- go on serving a session it can no longer proxy.
          endpointLoop = do
            outcome <-
              try
                ( forever $ do
                    line <- pollReadLine replies repliesBuffer repliesIdle
                    case line of
                      Nothing -> ioError (userError "the review tool endpoint is gone")
                      Just frame -> do
                        handled <- handleEndpointReply pending writeClient frame
                        when (not handled) (ioError (userError "malformed endpoint frame"))
                ) ::
                IO (Either IOException ())
            case outcome of
              Left _ -> failEndpoint
              Right () -> pure ()
      void (forkIO clientLoop)
      void (forkIO endpointLoop)
      takeMVar finished

-- | Dispatch one request the CLI wrote. Protocol methods are answered here;
-- anything else with an id is recorded as pending and forwarded, so the
-- parent's answer — and only the parent's answer — resolves it.
handleClientLine ::
  MVar (Map LazyByteString.ByteString PendingCall) ->
  (Value -> IO ()) ->
  (Value -> IO Bool) ->
  IO () ->
  ByteString.ByteString ->
  IO ()
handleClientLine pending writeClient forwardCall failEndpoint line =
  case eitherDecode (LazyByteString.fromStrict line) of
    Left message ->
      writeClient
        ( object
            [ "jsonrpc" .= jsonRpcVersion,
              "id" .= Null,
              "error" .= object ["code" .= (-32700 :: Int), "message" .= ("request is not JSON: " <> Text.pack message)]
            ]
        )
    Right value -> case (lookupField "id" value, lookupField "method" value) of
      -- A notification. @notifications/initialized@ and its siblings expect
      -- no answer, and this server has no use for any of them.
      (Nothing, _) -> pure ()
      (Just requestId, Just (String "initialize")) -> writeClient (initializeReply requestId value)
      (Just requestId, Just (String "ping")) ->
        writeClient (object ["jsonrpc" .= jsonRpcVersion, "id" .= requestId, "result" .= object []])
      (Just requestId, Just (String method)) -> do
        modifyMVar_ pending (pure . Map.insert (encode requestId) (PendingCall requestId method))
        let params = maybe (object []) id (lookupField "params" value)
        forwarded <- forwardCall (object ["id" .= requestId, "method" .= method, "params" .= params])
        when (not forwarded) failEndpoint
      (Just requestId, _) ->
        writeClient
          ( object
              [ "jsonrpc" .= jsonRpcVersion,
                "id" .= requestId,
                "error" .= object ["code" .= (-32600 :: Int), "message" .= ("request names no method" :: Text)]
              ]
          )

-- | Resolve one parent reply against the call it answers, forwarding the
-- parent's result or error verbatim under the CLI's own id. 'False' is a
-- frame this server cannot read at all, which the caller treats as the
-- endpoint failing.
handleEndpointReply ::
  MVar (Map LazyByteString.ByteString PendingCall) ->
  (Value -> IO ()) ->
  ByteString.ByteString ->
  IO Bool
handleEndpointReply pending writeClient line =
  case eitherDecode (LazyByteString.fromStrict line) of
    Left _ -> pure False
    Right value -> case lookupField "id" value of
      Nothing -> pure False
      Just requestId -> do
        resolved <- modifyMVar pending $ \held ->
          let key = encode requestId
           in pure (Map.delete key held, Map.member key held)
        -- A reply nothing waits for is dropped: the call it answered was
        -- already failed by a teardown this reply raced.
        when resolved . writeClient . Object . KeyMap.fromList $
          ("jsonrpc", String jsonRpcVersion)
            : ("id", requestId)
            : [ (Key.fromText field, payload)
                | field <- ["result", "error"],
                  Just payload <- [lookupField field value]
              ]
        pure True

-- | The answer @initialize@ deserves: this server's identity, a tools
-- capability, and the client's own protocol version echoed back where it
-- supplied one.
initializeReply :: Value -> Value -> Value
initializeReply requestId request =
  object
    [ "jsonrpc" .= jsonRpcVersion,
      "id" .= requestId,
      "result"
        .= object
          [ "protocolVersion" .= protocolVersion,
            "capabilities" .= object ["tools" .= object []],
            "serverInfo" .= object ["name" .= reviewToolServerName, "version" .= ("1.1.0.0" :: Text)]
          ]
    ]
  where
    protocolVersion = case lookupField "params" request >>= lookupField "protocolVersion" of
      Just (String requested) -> requested
      _ -> "2025-06-18"

-- | What a pending call is answered with once the endpoint is gone. A
-- @tools\/call@ takes the tool-level failure its caller can read; anything
-- else takes the protocol error, because it has no tool result shape.
closedEndpointReply :: PendingCall -> Value
closedEndpointReply call = case call.pendingCallMethod of
  "tools/call" ->
    object ["jsonrpc" .= jsonRpcVersion, "id" .= call.pendingCallId, "result" .= mcpToolResult True closedEndpointMessage]
  _ ->
    object
      [ "jsonrpc" .= jsonRpcVersion,
        "id" .= call.pendingCallId,
        "error" .= object ["code" .= (-32603 :: Int), "message" .= closedEndpointMessage]
      ]

closedEndpointMessage :: Text
closedEndpointMessage = "Kanban's review client closed this thread's tool endpoint"

jsonRpcVersion :: Text
jsonRpcVersion = "2.0"

lookupField :: Text -> Value -> Maybe Value
lookupField field (Object fields) = KeyMap.lookup (Key.fromText field) fields
lookupField _ _ = Nothing

ignoreIOException :: IO () -> IO ()
ignoreIOException action = do
  _ <- try action :: IO (Either IOException ())
  pure ()
