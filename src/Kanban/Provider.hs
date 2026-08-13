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
  | -- | The provider refused the request because its own budget is spent, and
    -- said so itself. Held apart from 'RequestFailed' because it is the one
    -- failure whose remedy is waiting a known length of time rather than
    -- retrying: 'Kanban.GitHub.Coordinator' schedules against it.
    RateLimited
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
