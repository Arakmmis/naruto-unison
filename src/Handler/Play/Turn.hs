module Handler.Play.Turn
  ( Turn(..)
  , new
  ) where

import ClassyPrelude

import Data.Aeson ((.=), ToJSON(..), Value, object)

import qualified Class.Parity as Parity
import qualified Game.Engine.Cooldown as Cooldown
import qualified Game.Engine.Ninjas as Ninjas
import           Game.Model.Chakra (Chakras)
import qualified Game.Model.Channel as Channel
import qualified Game.Model.Character as Character
import           Game.Model.Class (Class(..))
import           Game.Model.Effect (Effect(..))
import           Game.Model.Game (Game(..))
import qualified Game.Model.Game as Game
import           Game.Model.Ninja (Ninja, is)
import qualified Game.Model.Ninja as Ninja
import           Game.Model.Player (Player)
import           Game.Model.Requirement (Requirement(..))
import qualified Game.Model.Requirement as Requirement
import           Game.Model.Skill (Skill, Target(..))
import qualified Game.Model.Skill as Skill
import           Game.Model.Slot (Slot)
import qualified Game.Model.Slot as Slot
import qualified Game.Model.Status as Status
import qualified Game.Model.Trap as Trap
import qualified Game.Model.Variant as Variant
import           Util ((!!), (∈), (∉), intersects)

data Turn = Turn { chakra  :: Chakras
                 , playing :: Player
                 , victor  :: [Player]
                 , ninjas  :: [Ninja]
                 , targets :: [[[Slot]]]
                 }

instance ToJSON Turn where
    toJSON Turn{..} = object
        [ "chakra"  .= chakra
        , "playing" .= playing
        , "victor"  .= victor
        , "ninjas"  .= (ninjaToJSON <$> ninjas)
        , "targets" .= targets
        ]

new :: Player -> [Ninja] -> Game -> Turn
new player ninjas game = Turn { chakra  = Parity.getOf player $ Game.chakra game
                              , playing = Game.playing game
                              , victor  = Game.victor game
                              , ninjas  = censored
                              , targets
                              }
  where
    censored = censor player ninjas <$> ninjas
    targets  = do
        n <- censored
        return do
            skill    <- Ninjas.skills n
            let targs = skillTargets skill $ Ninja.slot n
            return do
                nt   <- censored
                let t = Ninja.slot nt
                guard $ Requirement.targetable skill n nt && t ∈ targs
                return t

censor :: Player -> [Ninja] -> Ninja -> Ninja
censor player ninjas n
  | Parity.allied player n = n'
  | n `is` Reveal          = n'
  | otherwise              = n'
      { Ninja.cooldowns = mempty
      , Ninja.charges   = mempty
      , Ninja.variants  = (Variant.none :| []) <$ Ninja.variants n
      , Ninja.channels  = filter filt $ Ninja.channels n
      , Ninja.lastSkill = Nothing
      }
  where
    filt chan = not $ Invisible ∈ Skill.classes (Channel.skill chan)
    n'   = n { Ninja.statuses = mapMaybe mst $ Ninja.statuses n
             , Ninja.traps    = [ trap | trap <- Ninja.traps n
                                , Parity.allied player (Trap.user trap)
                                  || Invisible ∉ Trap.classes trap
                                  || revealed (Trap.user trap) ]
             }
    revealed slot = ninjas !! Slot.toInt slot `is` Reveal
    mst st
      | Parity.allied player $ Status.user st = Just st
      | Invisible ∈ Status.classes st
        && not (revealed $ Status.user st) = Nothing
      | otherwise = case Status.effects st of
          []       -> Just st
          [Reveal] -> Nothing
          _        -> Just st
              { Status.effects = Reveal `delete` Status.effects st }

-- | All targets that a @Skill@ from a a specific 'Ninja' affects.
skillTargets :: Skill -> Slot -> [Slot]
skillTargets skill c = filter target Slot.all
  where
    ts = Skill.targets skill
    target t
      | Everyone ∈ ts                = True
      | not $ Parity.allied c t      = ts `intersects` harmTargets
      | ts `intersects` xAllyTargets = c /= t
      | ts `intersects` allyTargets  = True
      | c == t                       = not $ ts `intersects` harmTargets
      | otherwise                    = False
    harmTargets  = setFromList [Enemy, Enemies, REnemy, XEnemies]
    xAllyTargets = setFromList [XAlly, XAllies]
    allyTargets  = setFromList [Ally, Allies, RAlly]

ninjaToJSON :: Ninja -> Value
ninjaToJSON n = object
    [ "slot"      .= Ninja.slot n
    , "character" .= Character.format (Ninja.character n)
    , "health"    .= Ninja.health n
    , "defense"   .= Ninja.defense n
    , "barrier"   .= Ninja.barrier n
    , "statuses"  .= filter ((Hidden ∉) . Status.classes) (Ninja.statuses n)
    , "charges"   .= Ninja.charges n
    , "cooldowns" .= Cooldown.active n
    , "variants"  .= Ninja.variants n
    , "copies"    .= Ninja.copies n
    , "channels"  .= Ninja.channels n
    , "traps"     .= filter ((Hidden ∉) . Trap.classes) (Ninja.traps n)
    , "face"      .= Ninja.face n
    , "lastSkill" .= Ninja.lastSkill n
    , "skills"    .= (usable <$> Ninjas.skills n)
    ]
  where
    usable skill = skill { Skill.require = fulfill $ Skill.require skill }
    fulfill req@HasI{}
      | Requirement.succeed req (Ninja.slot n) n = Usable
      | otherwise                                = Unusable
    fulfill x = x