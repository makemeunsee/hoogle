{-# LANGUAGE RecordWildCards #-}

module Web.Response(response) where

import CmdLine.All
import Hoogle
import General.Base
import General.System
import General.Web
import Web.Page
import Data.Generics.Uniplate

import Data.Time.Clock
import Data.Time.Format
import System.Locale
import Network.Wai
import System.IO.Unsafe(unsafeInterleaveIO)
import qualified Paths_hoogle(version)
import Data.Version(showVersion)


logFile = "log.txt"
version = showVersion Paths_hoogle.version


response :: CmdLine -> IO Response
response q = do
    logMessage q
    let response x ys = fmap $ responseOK ((hdrContentType,fromString x) : ys) . fromString

    dbs <- unsafeInterleaveIO $ case queryParsed q of
        Left _ -> return mempty
        Right x -> fmap snd $ loadQueryDatabases (databases q) (fromRight $ queryParsed q)

    case web q of
        Just "suggest" -> response "application/json" [] $ runSuggest q
        Just "embed" -> response "text/html" [hdr] $ return $ runEmbed dbs q
            where hdr = (fromString "Access-Control-Allow-Origin", fromString "*")
        Just "ajax" -> response "text/html" [] $ runQuery True dbs q
        Just "web" -> do
            hdr <- header version version (resources q) (queryText q)
            bod <- runQuery False dbs q
            ftr <- footer version
            response "text/html" [] $ return $ hdr ++ bod ++ ftr
        mode -> response "text/html" [] $ return $ "Unknown webmode: " ++ fromMaybe "none" mode


logMessage :: CmdLine -> IO ()
logMessage q = do
    time <- getCurrentTime
    args <- fmap (fromMaybe [("hoogle",queryText q)]) cgiArgs
    ip <- fmap (fromMaybe "0") $ getEnvVar "REMOTE_ADDR"
    let shw x = if all isAlphaNum x then x else show x
    appendFile logFile $ (++ "\n") $ unwords $
        [formatTime defaultTimeLocale "%FT%T" time
        ,ip] ++
        [shw a ++ "=" ++ shw b | (a,b) <- args]


runSuggest :: CmdLine -> IO String
runSuggest cq@Search{queryText=q} = do
    (_, db) <- loadQueryDatabases (databases cq) mempty
    let res = completions db q
    return $ "[" ++ show q ++ "," ++ show res ++ "]"
runSuggest _ = return ""


runEmbed :: Database -> CmdLine -> String
runEmbed dbs Search{queryParsed = Left err} = "<i>Parse error: " ++& errorMessage err ++ "</i>"
runEmbed dbs cq@Search{queryParsed = Right q}
    | null now = "<i>No results found</i>"
    | otherwise = unlines
        ["<a href='" ++ url ++ "'>" ++ showTagHTML (transform f $ self $ snd x) ++ "</a>"
        | x <- now, let url = fromList "" $ map fst $ locations $ snd x]
    where
        now = take (maybe 10 (max 1) $ count cq) $ search dbs q
        f (TagEmph x) = TagBold x
        f (TagBold x) = x
        f x = x


runQuery :: Bool -> Database -> CmdLine -> IO String
runQuery ajax dbs Search{queryParsed = Left err} =
    parseError (showTagHTMLWith f $ parseInput err) (errorMessage err)
    where
        f (TagEmph x) = Just $ "<span class='error'>" ++ showTagHTMLWith f x ++ "</span>"
        f _ = Nothing


runQuery ajax dbs q | fromRight (queryParsed q) == mempty = welcome


runQuery ajax dbs cq@Search{queryParsed = Right q, queryText = qt} = return $ unlines $
    (if prefix then
        ["<h1>" ++ qstr ++ "</h1>"] ++
        ["<div id='left'>" ++ also ++ "</div>" | not $ null pkgs] ++
        ["<p>" ++ showTag sug ++ "</p>" | Just sug <- [suggestions dbs q]] ++
        if null res then
            ["<p>No results found</p>"]
        else
            concat (pre ++ now)
    else
        concat now) ++
    ["<p><a href=\"" ++& urlMore ++ "\" class='more'>Show more results</a></p>" | not $ null post]
    where
        prefix = not $ ajax && start2 /= 0 -- show from the start, with header
        start2 = maybe 0 (subtract 1 . max 0) $ start cq
        count2 = maybe 20 (max 1) $ count cq

        src = search dbs q
        res = [renderRes i (i /= 0 && i == start2 && prefix) x | (i,(_,x)) <- zip [0..] src]
        (pre,res2) = splitAt start2 res
        (now,post) = splitAt count2 res2

        also = "<ul><li><b>Packages</b></li>" ++ concatMap f (take (5 + length minus) $ nub $ minus ++ pkgs) ++ "</ul>"
            where minus = [x | (False,x) <- queryPackages q]
        f x | (True,lx) `elem` queryPackages q =
                let q2 = showTagText $ renderQuery $ querySetPackage Nothing lx q in
                "<li><a class='minus' href='" ++ searchLink q2 ++ "'>" ++ x ++ "</a></li>"
            | (False,lx) `elem` queryPackages q =
                let q2 = showTagText $ renderQuery $ querySetPackage Nothing lx q in
                "<li><a class='plus pad' href='" ++ searchLink q2 ++ "'>" ++ x ++ "</a></li>"
            | otherwise =
                let link b = searchLink $ showTagText $ renderQuery $ querySetPackage (Just b) lx q in
                "<li><a class='minus' href='" ++ link False ++ "'></a>" ++
                "<a class='plus' href='" ++ link True ++ "'>" ++ x ++ "</a></li>"
            where lx = map toLower x
        pkgs = [x | (_, (_,x):_)  <- concatMap (locations . snd) $ take (start2+count2) src]

        urlMore = searchLink qt ++ "&start=" ++ show (start2+count2+1) ++ "#more"
        qstr = showTagHTML (renderQuery q)


renderRes :: Int -> Bool -> Result -> [String]
renderRes i more Result{..} =
        ["<a name='more'></a>" | more] ++
        ["<div class='ans'>" ++ href selfUrl (showTagHTMLWith url self) ++ "</div>"] ++
        ["<div class='from'>" ++ intercalate ", " [unwords $ zipWith (f u) [1..] ps | (u,ps) <- locations] ++ "</div>" | not $ null locations] ++
        ["<div class='doc " ++ (if '\n' `elem` s then " newline" else "") ++ "'><span>" ++ showTag docs ++ "</span></div>"
            | let s = showTagText docs, s /= ""]
    where
        selfUrl = head $ map fst locations ++ [""]
        f u cls (url,text) = "<a class='p" ++ show cls ++ "' href='" ++  url2 ++ "'>" ++ text ++ "</a>"
            where url2 = if url == takeWhile (/= '#') u then u else url

        url (TagBold x)
            | null selfUrl = Just $ "<span class='a'>" ++ showTagHTML (transform g x) ++ "</span>"
            | otherwise = Just $ "</a><a class='a' href='" ++& selfUrl ++ "'>" ++ showTagHTML (transform g x) ++
                                 "</a><a class='dull' href='" ++& selfUrl ++ "'>"
        url _ = Nothing

        g (TagEmph x) = TagBold x
        g x = x

        href url x = if null url then x else "<a class='dull' href='" ++& url ++ "'>" ++ x ++ "</a>"


showTag :: TagStr -> String
showTag = showTagHTML . transform f
    where
        f (TagLink "" x) = TagLink (if "http:" `isPrefixOf` str then str else searchLink str) x
            where str = showTagText x
        f x = x


searchLink :: String -> URL
searchLink x = "?hoogle=" ++% x
