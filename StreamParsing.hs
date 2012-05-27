{-# LANGUAGE OverloadedStrings #-}
module StreamParsing
    ( parseStreamLine
    , StreamMessage(..)
    ) where

import Control.Applicative
import Control.Monad
import Data.Aeson
import Data.Aeson.Types
import Data.String
import Network

import qualified Data.Attoparsec as AP
import qualified Data.ByteString as B
import qualified Data.Map as M
import qualified Data.Text as T
import qualified System.IO as IO

data DepthType = Ask | Bid
                 deriving (Show)

data StreamMessage = TickerUpdateUSD { tuBid :: Integer
                                     , tuAsk :: Integer
                                     , tuLast :: Integer
                                     }
                     | DepthUpdateUSD { duPrice :: Integer
                                      , duVolume :: Integer
                                      , duType :: DepthType
                                      }
                     | Subscribed { sChannel :: T.Text }
                     | Unsubscribed { usChannel :: T.Text }
                     | OtherMessage
                     deriving (Show)

instance FromJSON StreamMessage
  where
    parseJSON (Object o) = case getOperation o of
        Just ("subscribe", subscribe) ->
            Subscribed <$> subscribe .: "channel"
        Just ("unsubscribe", unsubscribe) ->
            Unsubscribed <$> unsubscribe .: "channel"
        Just ("ticker", ticker) -> parseTicker ticker
        Just ("depth", depth) -> parseDepth depth
        Just _ -> return OtherMessage
        Nothing -> return OtherMessage
    parseJSON _ = mzero

getOperation ::  M.Map T.Text Value -> Maybe (T.Text, Object)
getOperation o = do
    op' <- M.lookup "op" o >>= extractText
    case op' of
        "private" -> do
            op <- M.lookup "private" o >>= extractText
            payload <- M.lookup op o >>= extractObject
            return (op, payload)
        "subscribe" -> return (op', o)
        "unsubscribe" -> return (op', o)
        _ -> fail "unknown operation"

parseDepth depth = case extractDepthData depth of
    Just (priceV, volumeV, depthType) -> do
        priceS <- parseJSON priceV :: Parser String
        volumeS <- parseJSON volumeV :: Parser String
        return DepthUpdateUSD { duPrice = read priceS
                              , duVolume = read volumeS
                              , duType = depthType
                              }
    Nothing -> mzero

extractDepthData o = do
    currency <- M.lookup "currency" o
    guard (currency == expectedCurrency)
    price <- M.lookup "price_int" o
    volume <- M.lookup "total_volume_int" o
    depthType <- M.lookup "type_str" o >>= convertTypeStr
    return (price, volume, depthType)

convertTypeStr (String "ask") = Just Ask
convertTypeStr (String "bid") = Just Bid
convertTypeStr _ = Nothing

parseTicker ticker = case extractTickerData ticker of
    Just (buyV, sellV, lastV) -> do
        buyS <- parseJSON buyV :: Parser String
        sellS <- parseJSON sellV :: Parser String
        lastS <- parseJSON lastV :: Parser String
        return TickerUpdateUSD { tuBid = read buyS
                               , tuAsk = read sellS
                               , tuLast = read lastS
                               }
    Nothing -> mzero

extractTickerData :: (IsString k, Ord k) => M.Map k Value -> Maybe (Value, Value, Value)
extractTickerData o = do
    buyPrice <- lookupInTicker "buy" o
    sellPrice <- lookupInTicker "sell" o
    lastPrice <- lookupInTicker "last" o
    return (buyPrice, sellPrice, lastPrice)

lookupInTicker ::  Ord k => k -> M.Map k Value -> Maybe Value
lookupInTicker field o = do
        tickerField <- M.lookup field o
                        >>= extractObject
        currency <- M.lookup "currency" tickerField
        guard (currency == expectedCurrency)
        M.lookup "value_int" tickerField

extractObject :: Value -> Maybe Object
extractObject (Object o) = Just o
extractObject _ = Nothing

extractText :: Value -> Maybe T.Text
extractText (String s) = Just s
extractText _ = Nothing

expectedCurrency :: Value
expectedCurrency = "USD"

expectedPrecision :: Integer
expectedPrecision = 5

parseLine :: B.ByteString -> Either String StreamMessage
parseLine = collapseErrors . parseStreamMessage
  where
    parseStreamMessage :: B.ByteString -> Either String (Result StreamMessage)
    parseStreamMessage = AP.parseOnly (fromJSON <$> json)

collapseErrors :: Either String (Result b) -> Either String b
collapseErrors (Left err) = Left err
collapseErrors (Right (Error err)) = Left err
collapseErrors (Right (Success payload)) = Right payload

parseStreamLine :: B.ByteString -> StreamMessage
parseStreamLine line = case parseLine line of
    Right msg -> msg
    Left _ -> OtherMessage