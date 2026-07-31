-- | Persisted user settings.
module Spec.Config.Settings (spec) where

import qualified Data.ByteString.Char8 as ByteString
import Data.Maybe (isJust)
import Kanban.Settings
  ( ChatVerbosity (..),
    Settings (..),
    defaultSettings,
    loadSettings,
    saveSettings,
    settingsPath
  )
import Spec.Support.Env (withEnvironmentValue, withTemporaryCacheRoot)
import Test.Hspec

spec :: Spec
spec = do
  describe "settings" $ do
    it "defaults chat output to standard and persists a selected verbosity" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          loadSettings `shouldReturn` (defaultSettings, Nothing)
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          loadSettings `shouldReturn` (Settings FullChat, Nothing)

    -- The version the writer has always stamped is now read, and it follows
    -- the cache's rule: a file from another version of the format is silently
    -- the defaults, however little of its payload this build understands.
    it "falls back to the defaults silently for a settings file from another schema version" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          path <- settingsPath
          ByteString.writeFile path "{\"schemaVersion\":999,\"chatVerbosity\":{\"mode\":\"full\",\"density\":3}}"
          loadSettings `shouldReturn` (defaultSettings, Nothing)

    it "still warns for settings it cannot decode under a version it does recognise" $
      withTemporaryCacheRoot $ \configRoot ->
        withEnvironmentValue "XDG_CONFIG_HOME" configRoot $ do
          saveSettings (Settings FullChat) `shouldReturn` Right ()
          path <- settingsPath
          let expectWarnedDefaults = do
                (settings, warning) <- loadSettings
                settings `shouldBe` defaultSettings
                warning `shouldSatisfy` isJust
          ByteString.writeFile path "{\"schemaVersion\":1,\"chatVerbosity\":\"deafening\"}"
          expectWarnedDefaults
          ByteString.writeFile path "not JSON"
          expectWarnedDefaults
          ByteString.writeFile path "{\"chatVerbosity\":\"full\"}"
          expectWarnedDefaults
