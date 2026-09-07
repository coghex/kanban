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
  | -- | A lineage that never reaches a root. The members are exactly the
    -- sessions on the loop, reported sorted: a session whose lineage merely
    -- leads into one is not among them, and when a node set holds more than
    -- one loop the reported members are the least of their sorted member
    -- lists. So neither the session a walk started from nor the order the
    -- nodes arrived in changes the message.
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

    -- Every walk that loops names one whole loop, and a node set can hold
    -- several, so which one is reported is decided by the members themselves
    -- — the least sorted member list — rather than by whichever walk the
    -- input order happened to run first.
    cycles = case sort [sort (Set.toList members) | Just members <- map (lineageCycle byIdentity) sessions] of
      [] -> Right ()
      least : _ -> Left (MissionSessionCycle least)

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

-- | The set of identities on the cycle @session@'s lineage reaches, if it
-- reaches one.
--
-- The walk's history and the cycle are different sets, and it is the second
-- one this answers with: a session that leads into a loop is visited on the
-- way and is not on it, so what is returned is the suffix of the walk
-- beginning at the identity the walk arrived at twice. That makes the answer a
-- property of the loop rather than of where the walk started, which is what
-- lets every walk reaching one loop report the same members.
--
-- Bounded by the nodes it has already seen rather than by a step count, so a
-- long legitimate lineage is never mistaken for a loop. Parents that do not
-- resolve stop the walk without complaint: the missing-parent check has
-- already reported those, and reporting them again as a broken lineage would
-- name the same defect twice in two vocabularies.
lineageCycle :: Map.Map MissionSessionId MissionSessionNode -> MissionSessionNode -> Maybe (Set.Set MissionSessionId)
lineageCycle byIdentity = walk Set.empty []
  where
    -- @walked@ holds the identities behind the walk, most recent first, so the
    -- suffix that is the loop is the prefix of that list up to and including
    -- the repeated identity.
    walk seen walked session
      | Set.member identity seen = Just (Set.fromList (identity : takeWhile (/= identity) walked))
      | otherwise = case session.missionSessionParent of
          Nothing -> Nothing
          Just parent -> case Map.lookup parent byIdentity of
            Nothing -> Nothing
            Just parentNode -> walk (Set.insert identity seen) (identity : walked) parentNode
      where
        identity = session.missionSessionId

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
