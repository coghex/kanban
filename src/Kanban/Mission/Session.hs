-- | The session tree a mission's snapshot carries, and the five ways a list of
-- nodes can fail to be one.
--
-- D-14 asks for a tree rather than a bag of nodes that happen to name parents,
-- and the difference is only visible when the naming is checked: a parent that
-- does not exist, a parent belonging to another mission, two nodes claiming
-- one identity, and a lineage that loops all round-trip through JSON
-- perfectly well. Every one of them makes \"walk up to the root\" a question
-- with no answer, and each is what a crash, a resumed mission, or a restored
-- store can leave behind.
--
-- The checks run in a fixed order and the first failure is returned, because
-- the later checks are not meaningful once an earlier one has failed: a
-- lineage walk over a node set with duplicate identities is walking an
-- ambiguous graph, not a broken tree.
--
-- This module is internal — "Kanban.Mission" re-exports the parts of it that
-- module's public contract promises.
module Kanban.Mission.Session
  ( MissionSessionTreeError (..),
    validateMissionSessionTree,
    missionSessionTreeErrorMessage,
  )
where

import Data.List (sort)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Kanban.Mission.Types
  ( MissionId (..),
    MissionSessionId (..),
    MissionSessionNode (..),
  )

-- | Why a list of nodes is not this mission's session tree.
data MissionSessionTreeError
  = -- | Two nodes share one identity, so naming a parent names both.
    MissionSessionDuplicate MissionSessionId
  | -- | A child names a parent no node in the list provides.
    MissionSessionMissingParent MissionSessionId MissionSessionId
  | -- | A child names a parent that exists but belongs to another mission.
    -- Distinct from a missing parent on purpose: the repair is not to create
    -- the parent, it is that this child was attributed to the wrong mission.
    MissionSessionCrossMissionParent MissionSessionId MissionSessionId
  | -- | A node in this mission's list records another mission as its own.
    MissionSessionForeign MissionSessionId MissionId
  | -- | A lineage that never reaches a root. The cycle's members are
    -- reported sorted, so the message does not depend on which member the
    -- walk happened to start from.
    MissionSessionCycle [MissionSessionId]
  deriving stock (Eq, Show)

-- | Whether @sessions@ is a session tree of @mission@.
--
-- Every non-root child resolves to exactly one parent in the same mission,
-- every identity is unique, and every lineage terminates. A node with no
-- parent is a root, and any number of roots is allowed: a mission that
-- dispatched three independent steps has three.
validateMissionSessionTree :: MissionId -> [MissionSessionNode] -> Either MissionSessionTreeError ()
validateMissionSessionTree mission sessions = do
  duplicates
  missingParents
  crossMissionParents
  foreignNodes
  cycles
  where
    identities = map missionSessionId sessions
    byIdentity = Map.fromList [(session.missionSessionId, session) | session <- sessions]

    duplicates = case firstDuplicate (sort identities) of
      Just identity -> Left (MissionSessionDuplicate identity)
      Nothing -> Right ()

    missingParents = firstError
      [ MissionSessionMissingParent session.missionSessionId parent
        | session <- sessions,
          Just parent <- [session.missionSessionParent],
          not (Map.member parent byIdentity)
      ]

    crossMissionParents = firstError
      [ MissionSessionCrossMissionParent session.missionSessionId parent
        | session <- sessions,
          Just parent <- [session.missionSessionParent],
          Just parentNode <- [Map.lookup parent byIdentity],
          parentNode.missionSessionMission /= session.missionSessionMission
      ]

    foreignNodes = firstError
      [ MissionSessionForeign session.missionSessionId session.missionSessionMission
        | session <- sessions,
          session.missionSessionMission /= mission
      ]

    cycles = firstError
      [ MissionSessionCycle (sort (Set.toList members))
        | Just members <- map (lineageCycle byIdentity) sessions
      ]

firstError :: [error] -> Either error ()
firstError errors = case errors of
  [] -> Right ()
  first : _ -> Left first

firstDuplicate :: Ord value => [value] -> Maybe value
firstDuplicate values = case values of
  first : second : rest
    | first == second -> Just first
    | otherwise -> firstDuplicate (second : rest)
  _ -> Nothing

-- | The set of identities on a cycle reachable from @session@, if its lineage
-- loops.
--
-- Bounded by the nodes it has already seen rather than by a step count, so a
-- long legitimate lineage is never mistaken for a loop. Parents that do not
-- resolve stop the walk without complaint: the missing-parent check has
-- already reported those, and reporting them again as a broken lineage would
-- name the same defect twice in two vocabularies.
lineageCycle :: Map.Map MissionSessionId MissionSessionNode -> MissionSessionNode -> Maybe (Set.Set MissionSessionId)
lineageCycle byIdentity = walk Set.empty
  where
    walk seen session
      | Set.member session.missionSessionId seen = Just seen
      | otherwise = case session.missionSessionParent of
          Nothing -> Nothing
          Just parent -> case Map.lookup parent byIdentity of
            Nothing -> Nothing
            Just parentNode -> walk (Set.insert session.missionSessionId seen) parentNode

missionSessionTreeErrorMessage :: MissionSessionTreeError -> Text
missionSessionTreeErrorMessage failure = case failure of
  MissionSessionDuplicate identity ->
    "two sessions share the identity " <> quoted identity.unMissionSessionId
  MissionSessionMissingParent child parent ->
    "session " <> quoted child.unMissionSessionId <> " names the parent " <> quoted parent.unMissionSessionId <> ", which this mission has no session for"
  MissionSessionCrossMissionParent child parent ->
    "session " <> quoted child.unMissionSessionId <> " names the parent " <> quoted parent.unMissionSessionId <> ", which belongs to another mission"
  MissionSessionForeign identity mission ->
    "session " <> quoted identity.unMissionSessionId <> " records the mission " <> quoted mission.unMissionId <> " rather than the one it was read for"
  MissionSessionCycle members ->
    "the sessions " <> Text.intercalate ", " (map (quoted . unMissionSessionId) members) <> " form a lineage that never reaches a root"

quoted :: Text -> Text
quoted value = "\"" <> value <> "\""
