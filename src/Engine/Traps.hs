-- 'Trap.Trap' processing.
module Engine.Traps
  ( run
  , track
    -- Performing 'Trap.Trap's
  , runTurn
    -- Collecting 'Trap.Trap's
  , get, getOf
  , broken
  ) where

import ClassyPrelude hiding ((\\), toList)

import Data.List ((\\), nub)

import           Core.Util ((∈), (∉))
import qualified Class.Parity as Parity
import qualified Class.Play as P
import           Class.Play (MonadGame)
import           Class.Random (MonadRandom)
import qualified Model.Character as Character
import qualified Model.Context as Context
import           Model.Context (Context)
import qualified Model.Defense as Defense
import qualified Model.Ninja as Ninja
import           Model.Ninja (Ninja)
import qualified Model.Runnable as Runnable
import           Model.Runnable (Runnable)
import           Model.Player (Player)
import           Model.Slot (Slot)
import qualified Model.Trap as Trap
import           Model.Trap (Trap, Trigger(..))

run :: Slot -> Trap -> Runnable Context
run user trap = case Trap.direction trap of
    Trap.From -> Runnable.retarget (\ctx -> ctx { Context.target = user }) play
    _         -> play
  where
      play = Trap.effect trap $ Trap.tracker trap

getOf :: Slot -> Trigger -> Ninja -> [Runnable Context]
getOf user trigger n =
    run user <$> filter ((trigger ==) . Trap.trigger) (Ninja.traps n)

get :: Slot -> Ninja -> [Runnable Context]
get user n =
    run user <$> filter ((∈ Ninja.triggers n) . Trap.trigger) (Ninja.traps n)

-- | Adds a value to 'Trap.tracker' of 'Ninja.traps' with a certain @Trigger@.
track :: Trigger -> Int -> Ninja -> Ninja
track trigger amount n = n { Ninja.traps = tracked <$> Ninja.traps n }
  where
    tracked trap
      | Trap.trigger trap == trigger =
          trap { Trap.tracker = amount + Trap.tracker trap }
      | otherwise = trap

-- | 'OnBreak' effects of 'Ninja.defense' removed during a turn.
broken :: Ninja -- ^ Old.
       -> Ninja -- ^ New.
       -> Ninja
broken n n' =
    n' { Ninja.traps    = filter ((∉ triggers) . Trap.trigger) $ Ninja.traps n'
       , Ninja.triggers = foldl' (flip insertSet) (Ninja.triggers n') triggers
       }
  where
    triggers = OnBreak <$> nub (Defense.name <$> Ninja.defense n)
                        \\ nub (Defense.name <$> Ninja.defense n')

-- | Conditionally returns 'Trap.Trap's that accept a numeric value.
getPer :: Bool -- ^ If False, returns @mempty@ instead.
       -> Trigger -- ^ Filter.
       -> Int -- ^ Value to pass to 'Trap.effect'.
       -> Ninja -- 'Ninja.traps' owner.
       -> [Runnable Context]
getPer False _  _   _ = mempty
getPer True  tr amt n = [Trap.effect trap amt | trap <- Ninja.traps n
                                              , Trap.trigger trap == tr]

-- | Conditionally returns 'Character.hooks'.
getHooks :: Bool -- ^ If False, returns @mempty@ instead.
         -> Trigger -- ^ Filter.
         -> Int -- ^ Value to pass to 'Character.hooks' effects.
         -> Ninja -- ^ 'Character.hooks' owner.
         -> [(Slot, Ninja -> Ninja)]
getHooks False _  _   _ = mempty
getHooks True  tr amt n = [(Ninja.slot n, f amt)
                              | (p, f) <- Character.hooks $ Ninja.character n
                              , tr == p]

-- | Tallies 'PerHealed' and 'PerDamaged' hooks.
getTurnHooks :: Player -- ^ Player during the current turn.
             -> Ninja -- ^ Old.
             -> Ninja -- ^ New.
             -> [(Slot, Ninja -> Ninja)]
getTurnHooks player n n'
  | hp < 0 && allied     = getHooks True PerHealed (-hp) n'
  | hp > 0 && not allied = getHooks True PerDamaged hp n'
  | otherwise            = mempty
  where
    allied = Parity.allied player n'
    hp     = Ninja.health n - Ninja.health n'

-- | Tallies 'PerHealed' and 'PerDamaged' traps.
getTurnPer :: Player -- ^ Player during the current turn.
           -> Ninja -- ^ Old.
           -> Ninja -- ^ New.
           -> [Runnable Context]
getTurnPer player n n'
  | hp < 0 && allied     = getPer True PerHealed (-hp) n'
  | hp > 0 && not allied = getPer True PerDamaged hp n'
  | otherwise            = mempty
  where
    allied = Parity.allied player n'
    hp   = Ninja.health n - Ninja.health n'

-- | Returns 'OnNoAction' 'Trap.Trap's.
getTurnNot :: Player -- ^ Player during the current turn.
           -> Ninja -- ^ 'Ninja.flags' owner.
           -> [Runnable Context]
getTurnNot player n
  | Ninja.acted n             = mempty
  | Parity.allied player user = getOf user OnNoAction n
  | otherwise                 = mempty
  where
    user = Ninja.slot n

-- | Processes and runs all 'Trap.Trap's at the end of a turn.
runTurn :: ∀ m. (MonadGame m, MonadRandom m) => Vector Ninja -> m ()
runTurn ninjas = do
    player  <- P.player
    ninjas' <- P.ninjas
    traverses (uncurry P.modify) $ zipWith (getTurnHooks player) ninjas ninjas'
    traverses P.launch $ zipWith (getTurnPer player) ninjas ninjas'
    traverses P.launch $ getTurnNot player <$> ninjas'
  where
    traverses f = traverse_ $ traverse_ f
