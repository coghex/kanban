-- | Predicates and expectations shared across the suite.
module Spec.Support.Expect
  ( isLeft,
    isRight,
    isLeftText,
    unsafeConfig,
    errorContains,
    rejectsWithGuidance,
    requireJust,
    requireLeft,
    requireRight,
    shouldMention,
    shouldNotMention,
    countOccurrences,
    flagForVariable,
    isInvalidCache,
    isInvalidUsageCache
  )
where

import qualified Data.ByteString.Char8 as ByteString
import Data.List (find, isPrefixOf)
import Data.Text (Text)
import qualified Data.Text
import Kanban.Cache (CacheLoad (..), UsageCacheLoad (..))
import Kanban.Config
import Test.Hspec

isLeft :: Either left right -> Bool
isLeft (Left _) = True
isLeft (Right _) = False

isRight :: Either left right -> Bool
isRight (Right _) = True
isRight (Left _) = False

isLeftText :: Either Text value -> Bool
isLeftText (Left _) = True
isLeftText (Right _) = False

unsafeConfig :: Either Text (RawConfig, [Text]) -> (RawConfig, [Text])
unsafeConfig = either (error . Data.Text.unpack) id

errorContains :: [Text] -> Either Text value -> Bool
errorContains needles (Left message) = all (`Data.Text.isInfixOf` message) needles
errorContains _ (Right _) = False

-- | A rejected remote must show the offending value and point at the
-- documented escape hatch, so the user can act without reading the source.
rejectsWithGuidance :: Text -> Either Text value -> Bool
rejectsWithGuidance remoteValue = errorContains [remoteValue, "--repo OWNER/NAME"]

-- | The gh flag a GraphQL variable is passed with, or 'Nothing' when the
-- variable is absent from the argument vector.
flagForVariable :: String -> [String] -> Maybe String
flagForVariable variableName =
  fmap fst . find (((variableName <> "=") `isPrefixOf`) . snd) . flaggedArguments
  where
    flaggedArguments (flag : value : rest)
      | flag `elem` ["-f", "-F"] = (flag, value) : flaggedArguments rest
    flaggedArguments (_ : rest) = flaggedArguments rest
    flaggedArguments [] = []

-- Workflow-preflight fixtures ------------------------------------------------

isInvalidCache :: CacheLoad -> Bool
isInvalidCache (CacheInvalid _) = True
isInvalidCache _ = False

isInvalidUsageCache :: UsageCacheLoad -> Bool
isInvalidUsageCache (UsageCacheInvalid _) = True
isInvalidUsageCache _ = False

countOccurrences :: ByteString.ByteString -> ByteString.ByteString -> Int
countOccurrences needle haystack
  | ByteString.null needle = 0
  | otherwise = length (ByteString.breakSubstring needle `iterateWhileFound` haystack)
  where
    iterateWhileFound step remaining = case step remaining of
      (_, match)
        | ByteString.null match -> []
        | otherwise -> () : iterateWhileFound step (ByteString.drop (ByteString.length needle) match)

requireJust :: String -> Maybe value -> IO value
requireJust message = maybe (fail message) pure

requireLeft :: String -> Either Text value -> IO Text
requireLeft message = either pure (const (fail message))

requireRight :: String -> Either Text value -> IO value
requireRight message = either (\failure -> fail (message <> ": " <> Data.Text.unpack failure)) pure

shouldMention :: Text -> Text -> Expectation
shouldMention haystack needle
  | Data.Text.isInfixOf needle haystack = pure ()
  | otherwise = expectationFailure ("expected " <> show haystack <> " to mention " <> show needle)

shouldNotMention :: Text -> Text -> Expectation
shouldNotMention haystack needle
  | Data.Text.isInfixOf needle haystack = expectationFailure ("expected " <> show haystack <> " not to mention " <> show needle)
  | otherwise = pure ()
