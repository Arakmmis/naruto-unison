{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE QuasiQuotes #-}

-- | Interface for the PureScript game client.
module Handler.Site
    ( getChangelogR
    , getPlayR
    , getMuteR
    , getUpdateR
    , getHomeR
    ) where

import Preludesque

import qualified Data.List.NonEmpty  as L
import qualified Data.Text           as T
import qualified Data.HashMap.Strict as M

import Data.Text  (Text)
import Text.Hamlet
import Yesod.WebSockets

import Calculus
import Core.Import
import Game.Structure
import Game.Characters
import Handler.Play (gameSocket)

shorten ∷ Text → Text
shorten = T.map shorten' ∘ T.filter (∉ filterOut)
  where filterOut    = " -:()®'/?" ∷ String
        shorten' 'ō' = 'o'
        shorten' 'Ō' = 'O'
        shorten' 'ū' = 'u'
        shorten' 'Ū' = 'U'
        shorten' 'ä' = 'a'
        shorten'  a  =  a

charAvatars ∷ Character → [Text]
charAvatars char = (root ⧺ "icon.jpg")
                 : (((root ⧺) ∘ (⧺ ".jpg")) ↤ shorten ∘ label ∘ head)
                    ↤ L.take 4 (characterSkills char)
  where root = "/img/ninja/" ⧺ shorten (characterName char) ⧺ "/"

avatars ∷ [Text]
avatars = ("/img/icon/" ⧺)
        ↤ [ "default.jpg"
          , "gaaraofthefunk.jpg"
          , "ninjainfocards.jpg"
          , "kabugrin.jpg"
          ]
       ⧺ concatMap charAvatars cs'

isMuted ∷ Maybe User → Bool
isMuted = maybe False userMuted

legalChars ∷ String
legalChars = ['0'..'9'] ⧺ ['a'..'z'] ⧺ ['A'..'z']

(!) ∷ Text → Text → Html
usr ! l = [shamlet| $newline never
<a .skill data-usr=#{usr}>#{l}|]

data LogType = Added | New | Rework
data CharacterType = O | R | S

logLabel ∷ Bool → LogType → Text
logLabel True  Added  = "Character added:"
logLabel False Added  = "Added:"
logLabel True  New    = "New character:"
logLabel False New    = "New:"
logLabel True  Rework = "Character rework:"
logLabel False Rework = "Rework:"

getChangelog ∷ Bool → LogType → Text → CharacterType → Html
getChangelog longlabel logType name characterType = case M.lookup tagName cs of
    Nothing → [shamlet|Error: character #{tagName} not found!|]
    Just Character{..} → [shamlet|
<img data-name=#{tagName} .char.head src="/img/ninja/#{shorten(tagName)}/icon.jpg">
<li>
  #{change logType} 
  <a .name data-name=#{tagName}>#{display characterType}
  <ul>
    $forall skills <- L.take 4 characterSkills
      <li>
        $forall skill <- separate skills
          <a .skill data-name=#{tagName}>#{label skill}
|]
  where separate      = nubBy (eqs label) ∘ toList
        tag O         = name
        tag R         = name ⧺ " (R)"
        tag S         = name ⧺ " (S)"
        tagName       = tag characterType
        change        = logLabel longlabel
        display O     = [shamlet|#{name}|]
        display R     = [shamlet|#{name}
<a .minor data-name=#{tagName}>ℝ|]
        display S     = [shamlet|#{name}
<a .minor data-name=#{tagName}>𝕊|]

s ∷ Html
s = [shamlet|<a .minor>𝕊|]

-- * HANDLERS

-- | Updates a user's profile.
getUpdateR ∷ Text → Text → Text → Handler Value
getUpdateR updateName updateBackground updateAvatar
  | "/img/icon/" ≠ T.take 10 updateAvatar = invalidArgs ["Invalid avatar"]
  | T.any (∉ legalChars) updateName = invalidArgs ["Invalid name"]
  | otherwise = do
    (accId, _) ← requireAuthPair
    user ← runDB $ updateGet accId [ UserName       =. updateName
                                   , UserBackground =. updateBackground''
                                   , UserAvatar     =. updateAvatar
                                   ]     
    returnJson user
  where updateBackground'  = tTail updateBackground
        updateBackground'' | T.null updateBackground' = Nothing
                           | otherwise                = Just updateBackground'

-- | Updates a user's muted status.
getMuteR ∷ Bool → Handler Value
getMuteR mute = do
    (who, _) ← requireAuthPair
    runDB $ update who [ UserMuted =. mute ]
    returnJson mute

-- | Renders the gameplay client.
getPlayR ∷ Handler Html
getPlayR = do
    webSockets gameSocket
    ma ← maybeAuth
    let (_, muser) = case ma of
          Just (Entity who user) → (Just who, Just user)
          Nothing                → (Nothing, Nothing)
    let team          = maybe [] (mapMaybe (`M.lookup` cs)) $ muser ≫= userTeam
    let bg = fromMaybe "/img/bg/valley2.jpg" $ muser ≫= userBackground
    defaultLayout $ do
        setTitle "Naruto Unison"
        addStylesheetRemote "/css/embeds.css"
        $(widgetFile "include/progressbar.min")
        $(widgetFile "include/soundjs.min")
        $(widgetFile "include/normalize")
        $(widgetFile "play/play")
        $(widgetFile "play/ps")

-- | Renders the changelog.
getChangelogR ∷ Handler Html
getChangelogR = defaultLayout $ do
    setTitle "Naruto Unison: Changelog"
    $(widgetFile "tooltip/tooltip")
    $(widgetFile "changelog/changelog")
  where changelog = getChangelog True 

-- | Renders the main site.
getHomeR ∷ Handler Html
getHomeR = defaultLayout $ do
    setTitle "Naruto Unison"
    $(widgetFile "tooltip/tooltip")
    $(widgetFile "home/home")
  where changelog = getChangelog False
