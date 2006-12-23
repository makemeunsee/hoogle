
module Hoogle.Search.All where

import Data.Maybe
import Data.List
import Control.Monad

import Hoogle.DataBase.All
import Hoogle.Query.All
import Hoogle.Common.All
import Hoogle.TypeSig.All


-- return all the results
searchAll :: [DataBase] -> Query -> IO [Result DataBase]
searchAll databases query = getResults databases query


-- should be possible to fast-path certain searches, currently not done
-- start (0 based), length
searchRange :: [DataBase] -> Query -> Int -> Int -> IO [Result DataBase]
searchRange databases query from len = do
    res <- getResults databases query
    return $ take len $ drop from res


getResults :: [DataBase] -> Query -> IO [Result DataBase]
getResults databases query = res >>= return . filterResults query
    where
        res = if not (null $ names query) then performTextSearch databases (names query)
              else if isJust (typeSig query) then performTypeSearch databases (fromJust $ typeSig query)
              else error "Search.getResults: Doing a blank search!"

filterResults :: Query -> [Result DataBase] -> [Result DataBase]
filterResults q xs = if null actions then xs
                    else filter (f base actions . modName . fromJust . itemMod . itemResult) xs
    where
        actions = filter isModule $ scope q
        
        isModule (PlusModule  _) = True
        isModule (MinusModule _) = True
        isModule _ = False
        
        base = case head actions of
                    PlusModule _ -> False
                    _ -> True
        
        f z [] y = z
        f z (PlusModule  x:xs) y | doesMatch x y = f True  xs y
        f z (MinusModule x:xs) y | doesMatch x y = f False xs y
        f z (x:xs) y = f z xs y

        -- match if x is further up the tree than y
        doesMatch [] y = True
        doesMatch (x:xs) (y:ys) = x == y && doesMatch xs ys
        doesMatch _ _ = False


performTextSearch :: [DataBase] -> [String] -> IO [Result DataBase]
performTextSearch databases query = do
        res <- concatMapM (`searchName` query) databases
        res <- return $ map head $ groupBy eqItemId $ sortBy cmpItemId res
        return $ sortBy priority res
    where
        cmpItemId x y = getItemId x `compare` getItemId y
        eqItemId x y = getItemId x == getItemId y
        getItemId = fromJust . itemId . itemResult

        priority x y = getStatus x `compare` getStatus y
        getStatus (Result (Just txt) typ item) =
            (negate $ length $ textMatch txt
            ,textElse txt
            ,textCase txt
            ,itemPriority $ itemRest item
            ,(fromJust $ itemName item
             ,length $ modName $ fromJust $ itemMod item
             ,modName $ fromJust $ itemMod item
             )
            )


performTypeSearch :: [DataBase] -> TypeSig -> IO [Result DataBase]
performTypeSearch databases query = do
        res <- concatMapM (`searchType` query) databases
        res <- return $ concat $ sortBy cmpResults res
        return res
    where
        cmpResults xs ys = f xs `compare` f ys
            where
                f = length . typeDiff . fromJust . typeResult . head


concatMapM f x = liftM concat $ mapM f x
