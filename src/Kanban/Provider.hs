module Kanban.Provider
  ( Provider (..),
    ProviderError (..),
    ProviderErrorKind (..),
  )
where

import Data.Text (Text)

data ProviderErrorKind
  = AuthenticationRequired
  | ExecutableMissing
  | UnsupportedVersion
  | RequestTimedOut
  | InvalidResponse
  | RequestFailed
  deriving stock (Eq, Ord, Show)

data ProviderError = ProviderError
  { providerErrorKind :: ProviderErrorKind,
    providerErrorMessage :: Text
  }
  deriving stock (Eq, Show)

data Provider request response = Provider
  { providerName :: Text,
    providerRefresh :: request -> IO (Either ProviderError response)
  }
