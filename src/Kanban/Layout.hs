module Kanban.Layout
  ( minimumColumnWidth,
    responsiveOpenColumnWidths,
    responsiveColumnWidths,
  )
where

minimumColumnWidth :: Int
minimumColumnWidth = 32

responsiveColumnWidths :: Int -> [Int]
responsiveColumnWidths = responsiveWidths 5

responsiveOpenColumnWidths :: Int -> [Int]
responsiveOpenColumnWidths = responsiveWidths 6

responsiveWidths :: Int -> Int -> [Int]
responsiveWidths frameWidth availableWidth
  | distributableWidth < columnCount * minimumColumnWidth = replicate columnCount minimumColumnWidth
  | otherwise =
      replicate remainder (baseWidth + 1)
        <> replicate (columnCount - remainder) baseWidth
  where
    columnCount = 4
    distributableWidth = max 0 (availableWidth - frameWidth)
    (baseWidth, remainder) = distributableWidth `divMod` columnCount
