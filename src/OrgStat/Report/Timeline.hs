{-# LANGUAGE TemplateHaskell #-}

-- | Timeline reporting. Prouces a svg with columns.

module OrgStat.Report.Timeline
       ( TimelineParams
       , tpColorSalt
       , tpLegend
       , tpTopDay
       , tpColumnWidth

       , processTimeline

       , mm
       ) where

import           Control.Lens         (makeLenses, (^.))
import qualified Data.Attoparsec.Text as A
import           Data.Default         (Default (..))
import           Data.Hashable        (hashWithSalt)
import           Data.List            (lookup, nub, (!!))
import qualified Data.Text            as T
import           Data.Time            (Day, DiffTime, UTCTime (..), fromGregorian)
import           Diagrams.Backend.SVG (B)
import qualified Diagrams.Backend.SVG as DB
import qualified Diagrams.Prelude     as D
import           OrgStat.Parser       (parseOrg)
import qualified Prelude
import           Text.Printf          (printf)
import           Universum

import           OrgStat.Ast          (Clock (..), Org (..))
import           OrgStat.Report.Types (SVGImageReport (..))


----------------------------------------------------------------------------
-- Parameters
----------------------------------------------------------------------------

data TimelineParams = TimelineParams
    { _tpColorSalt   :: Int    -- ^ Salt added when getting color out of task name.
    , _tpLegend      :: Bool   -- ^ Include map legend?
    , _tpTopDay      :: Int    -- ^ How many items to include in top day (under column)
    , _tpColumnWidth :: Double -- ^ Coeff
    } deriving Show

instance Default TimelineParams where
    def = TimelineParams 0 True 5 1

makeLenses ''TimelineParams

----------------------------------------------------------------------------
-- Processing clocks
----------------------------------------------------------------------------

-- [(a, [b])] -> [(a, b)]
allClocks :: [(Text, [(DiffTime, DiffTime)])] -> [(Text, (DiffTime, DiffTime))]
allClocks tasks = do
  (label, clocks) <- tasks
  clock <- clocks
  pure (label, clock)

-- separate list for each day
selectDays :: [Day] -> [(Text, [Clock])] -> [[(Text, [(DiffTime, DiffTime)])]]
selectDays days tasks =
    foreach days $ \day ->
      filter (not . null . snd) $
      map (second (selectDay day)) tasks
  where
    selectDay :: Day -> [Clock] -> [(DiffTime, DiffTime)]
    selectDay day clocks = do
        Clock (UTCTime dFrom tFrom) (UTCTime dTo tTo) <- clocks
        guard $ any (== day) [dFrom, dTo]
        let tFrom' = if dFrom == day then tFrom else fromInteger 0
        let tTo'   = if dTo   == day then tTo   else fromInteger (24*60*60)
        pure (tFrom', tTo')

-- total time for each task
totalTimes :: [(Text, [(DiffTime, DiffTime)])] -> [(Text, DiffTime)]
totalTimes tasks = map (second clocksSum) tasks
  where
    clocksSum :: [(DiffTime, DiffTime)] -> DiffTime
    clocksSum clocks = sum $ map (\(start, end) -> end - start) clocks

-- list of leaves
orgToList :: Org -> [(Text, [Clock])]
orgToList = orgToList' ""
  where
    orgToList' :: Text -> Org -> [(Text, [Clock])]
    orgToList' _pr org =
      --let path = pr <> "/" <> _orgTitle org
      let path = _orgTitle org
      in case _orgSubtrees org of
        [] -> [(path, _orgClocks org)]
        _  -> concatMap (orgToList' path) (_orgSubtrees org)


----------------------------------------------------------------------------
-- Drawing
----------------------------------------------------------------------------


diffTimeSeconds :: DiffTime -> Integer
diffTimeSeconds time = floor $ toRational time

diffTimeMinutes :: DiffTime -> Integer
diffTimeMinutes time = diffTimeSeconds time `div` 60

-- diffTimeHours :: DiffTime -> Integer
-- diffTimeHours time = diffTimeMinutes time `div` 60


labelColour :: TimelineParams -> (Text -> D.Colour Double)
labelColour params _label = colours !! (hashWithSalt (params ^. tpColorSalt) _label)
  where
    colours = map toColour popularColours
    toWord8 a b =
        fromMaybe (panic "labelColour#toColour is broken") $ readMaybe $ "0x"++[a,b]
    toColour [r1,r2,g1,g2,b1,b2] = D.sRGB24 (toWord8 r1 r2) (toWord8 g1 g2) (toWord8 b1 b2)
    toColour _ = panic "toColour called with incorrect color list"
    popularColours :: [[Char]]
    popularColours = ["000000","00FF00","0000FF","FF0000","01FFFE","FFA6FE","FFDB66","006401","010067","95003A","007DB5","FF00F6","FFEEE8","774D00","90FB92","0076FF","D5FF00","FF937E","6A826C","FF029D","FE8900","7A4782","7E2DD2","85A900","FF0056","A42400","00AE7E","683D3B","BDC6FF","263400","BDD393","00B917","9E008E","001544","C28C9F","FF74A3","01D0FF","004754","E56FFE","788231","0E4CA1","91D0CB","BE9970","968AE8","BB8800","43002C","DEFF74","00FFC6","FFE502","620E00","008F9C","98FF52","7544B1","B500FF","00FF78","FF6E41","005F39","6B6882","5FAD4E","A75740","A5FFD2","FFB167","009BFF","E85EBE"];

-- timeline for a single day
timelineDay :: TimelineParams -> [(Text, (DiffTime, DiffTime))] -> D.Diagram B
timelineDay params clocks =
  D.scaleUToY height $
  mconcat
    [ mconcat (map showClock clocks)
    , background
    ]
  where
    width = 140 * (totalHeight / height)
    height = 700

    totalHeight :: Double
    totalHeight = 24*60

    background :: D.Diagram B
    background =
      D.rect width totalHeight
      & D.lw D.none
      & D.fc D.red
      & D.moveOriginTo (D.p2 (-width/2, totalHeight/2))
      & D.moveTo (D.p2 (0, totalHeight))

    showClock :: (Text, (DiffTime, DiffTime)) -> D.Diagram B
    showClock (label, (start, end)) =
      let
        w = width
        h = fromInteger $ diffTimeMinutes $ end - start
      in
        mconcat
          [ D.alignedText 0 0.5 (T.unpack label)
            & D.font "DejaVu Sans"
            & D.fontSize 10
            & D.moveTo (D.p2 (-w/2+10, 0))
          , D.rect w h
            & D.lw (D.output 0.5)
            & D.fc (labelColour params label)
          ]
        & D.moveOriginTo (D.p2 (-w/2, h/2))
        & D.moveTo (D.p2 (0, totalHeight - fromInteger (diffTimeMinutes start)))

-- timelines for several days, with top lists
timelineDays
  :: TimelineParams
  -> [[(Text, (DiffTime, DiffTime))]]
  -> [[(Text, DiffTime)]]
  -> D.Diagram B
timelineDays params clocks topLists =
  D.hsep 10 $
  foreach (zip clocks topLists) $ \(dayClocks, topList) ->
  D.vsep 5
  [ timelineDay params dayClocks
  , taskList params topList
  ]

-- task list, with durations and colours
taskList :: TimelineParams -> [(Text, DiffTime)] -> D.Diagram B
taskList params labels = D.vsep 5 $ map oneTask labels
  where
    oneTask :: (Text, DiffTime) -> D.Diagram B
    oneTask (label, time) =
      D.hsep 5
      [ D.alignedText 1 0.5 (showTime time)
        & D.font "DejaVu Sans"
        & D.fontSize 10
        & D.translateX 30
      , D.rect 12 12
        & D.fc (labelColour params label)
        & D.lw D.none
      , D.alignedText 0 0.5 (T.unpack label)
        & D.font "DejaVu Sans"
        & D.fontSize 10
      ]

    showTime :: DiffTime -> Prelude.String
    showTime time = printf "%d:%02d" hours minutes
      where
        (hours, minutes) = diffTimeMinutes time `divMod` 60

timelineReport :: TimelineParams -> Org -> SVGImageReport
timelineReport params org = SVGImage pic
  where
    lookupDef :: Eq a => b -> a -> [(a, b)] -> b
    lookupDef d a xs = fromMaybe d $ lookup a xs

    -- period to show
    daysToShow =
      foreach [1..7] $ \day ->
      fromGregorian 2017 1 day

    topSize = 5

    -- unfiltered leaves
    tasks :: [(Text, [Clock])]
    tasks = orgToList org

    -- tasks from the given period, split by days
    byDay :: [[(Text, [(DiffTime, DiffTime)])]]
    byDay = selectDays daysToShow tasks

    -- total durations for each task, split by days
    byDayDurations :: [[(Text, DiffTime)]]
    byDayDurations = map totalTimes byDay

    -- total durations for the whole period
    allDaysDurations :: [(Text, DiffTime)]
    allDaysDurations =
      let allTasks = nub $ map fst $ concat byDayDurations in
      foreach allTasks $ \task ->
      (task,) $ sum $ foreach byDayDurations $ \durations ->
      lookupDef (fromInteger 0) task durations

    -- split clocks
    clocks :: [[(Text, (DiffTime, DiffTime))]]
    clocks = map allClocks byDay

    -- top list for each day
    topLists :: [[(Text, DiffTime)]]
    topLists = map (take topSize . reverse . sortOn (\(_task, time) -> time)) byDayDurations

    pic =
      D.vsep 30
      [ timelineDays params clocks topLists
      , taskList params allDaysDurations
      ]

processTimeline :: (MonadThrow m) => TimelineParams -> Org -> m SVGImageReport
processTimeline params org = pure $ timelineReport params org

-- test
mm :: IO ()
mm = do
    txt <- readFile "/home/zhenya/Dropbox/org/proj.org"
    let Right org = A.parseOnly (parseOrg ["!","&","+"]) txt
    let SVGImage pic = timelineReport def org
    DB.renderSVG "./tmp/some.svg" (D.dims2D (D.width pic) (D.height pic)) pic
