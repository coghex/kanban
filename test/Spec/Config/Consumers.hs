-- | Resolved configuration reaching the runtime consumers that act on it.
module Spec.Config.Consumers (spec) where

import Kanban.CLI (Options (..))
import Kanban.Config
import Kanban.UI
  ( cacheEnabled,
    cardExcerptLimit,
    claudeRefreshTimeoutMicros,
    codexRefreshTimeoutMicros,
    githubRefreshTimeoutMicros
  )
import Spec.Support.Fixtures (testOptions, testResolvedConfig)
import Test.Hspec

spec :: Spec
spec = do
  describe "cache precedence" $ do
    it "lets --no-cache disable the cache even when configuration enables it" $
      cacheEnabled (testOptions {optionNoCache = True}) (testResolvedConfig {resolvedCache = True}) `shouldBe` False
    it "lets configuration disable the cache without --no-cache" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = False}) `shouldBe` False
    it "enables the cache only when neither --no-cache nor configuration disables it" $
      cacheEnabled (testOptions {optionNoCache = False}) (testResolvedConfig {resolvedCache = True}) `shouldBe` True

  describe "configured provider timeouts and excerpt height reaching their runtime consumers" $ do
    it "converts the configured GitHub timeout from seconds to the microseconds System.Timeout.timeout takes" $
      githubRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 5000000
    it "converts the configured Codex timeout from seconds to microseconds" $
      codexRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 7000000
    it "converts the configured Claude timeout from seconds to microseconds" $
      claudeRefreshTimeoutMicros (testResolvedConfig {resolvedTimeouts = TimeoutsConfig 5 7 9}) `shouldBe` 9000000
    it "passes the configured excerpt line count through to the card-rendering limit" $ do
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 3}) `shouldBe` 3
      cardExcerptLimit (testResolvedConfig {resolvedLimits = LimitsConfig 250 100 9}) `shouldBe` 9
