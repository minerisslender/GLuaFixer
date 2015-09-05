module Main where

import System.Environment
import System.IO
import Control.Monad
import GLua.Lexer
import GLuaFixer.AG.LexLint
import GLua.Parser
import GLuaFixer.AG.ASTLint
import GLua.AG.PrettyPrint
import System.FilePath.Posix
import GLuaFixer.LintSettings
import System.Exit
import qualified Data.ByteString.Lazy as BS
import Data.Aeson
import Data.Maybe
import System.Directory
import Control.Applicative
import GLuaFixer.AG.DarkRPRewrite

version :: String
version = "1.2.1"

-- | Read file in utf8_bom because that seems to work better
doReadFile :: FilePath -> IO String
doReadFile f = do
    handle <- openFile f ReadMode
    hSetEncoding handle utf8_bom
    contents <- hGetContents handle
    return contents


prettyPrint :: IO ()
prettyPrint = do
                lua <- getContents

                lintsettings <- getSettings
                let parsed = parseGLuaFromString lua
                let ast = fst parsed
                let ppconf = lint2ppSetting lintsettings
                let pretty = prettyprintConf ppconf . fixOldDarkRPSyntax $ ast

                putStr pretty


-- | Lint a set of files
lint :: LintSettings -> [FilePath] -> IO ()
lint _ [] = return ()
lint ls (f : fs) = do
    contents <- doReadFile f

    let lexed = execParseTokens contents
    let tokens = fst lexed
    let warnings = map ((++) (takeFileName f ++ ": ")) $ lintWarnings ls tokens

    -- Fixed for positions
    let fixedTokens = fixedLexPositions tokens
    let parsed = parseGLua fixedTokens
    let ast = fst parsed
    let parserWarnings = map ((++) (takeFileName f ++ ": ")) $ astWarnings ls ast

    let syntaxErrors = map ((++) (takeFileName f ++ ": [Error] ") . renderError) $ snd lexed ++ snd parsed

    -- Print syntax errors
    when (lint_syntaxErrors ls) $
        mapM_ putStrLn syntaxErrors

    -- Print all warnings
    mapM_ putStrLn warnings
    mapM_ putStrLn parserWarnings

    -- Lint the other files
    lint ls fs

settingsFromFile :: FilePath -> IO (Maybe LintSettings)
settingsFromFile f = do
                        configContents <- BS.readFile f
                        let jsonDecoded = eitherDecode configContents :: Either String LintSettings
                        case jsonDecoded of Left err -> putStrLn (f ++ " [Error] Could not parse config file. " ++ err) >> exitWith (ExitFailure 1)
                                            Right ls -> return $ Just ls

parseCLArgs :: [String] -> IO (Maybe LintSettings, [FilePath])
parseCLArgs [] = return (Nothing, [])
parseCLArgs ("--pretty-print" : _) = prettyPrint >> exitWith ExitSuccess
parseCLArgs ("--version" : _) = putStrLn version >> exitWith ExitSuccess
parseCLArgs ("--config" : []) = putStrLn "Well give me a config file then you twat" >> exitWith (ExitFailure 1)
parseCLArgs ("--config" : f : xs) = do
                                        settings <- settingsFromFile f
                                        (_, fps) <- parseCLArgs xs
                                        return (settings, fps)
parseCLArgs (f : xs) = do (ls, fs) <- parseCLArgs xs
                          return (ls, f : fs)

settingsFile :: FilePath
settingsFile = "glualint" <.> "json"

homeSettingsFile :: FilePath
homeSettingsFile = ".glualint" <.> "json"

-- Search upwards in the file path until a settings file is found
searchSettings :: FilePath -> IO (Maybe LintSettings)
searchSettings f = do
                        dirExists <- doesDirectoryExist f
                        let up = takeDirectory f
                        if not dirExists || up == takeDirectory up then
                            return Nothing
                        else do
                            exists <- doesFileExist (f </> settingsFile)
                            if exists then
                                settingsFromFile (f </> settingsFile)
                            else
                                searchSettings up

-- Look for the file in the home directory
searchHome :: IO (Maybe LintSettings)
searchHome = do
                home <- getHomeDirectory
                exists <- doesFileExist (home </> homeSettingsFile)
                if exists then
                    settingsFromFile (home </> homeSettingsFile)
                else
                    return Nothing

getSettings :: IO LintSettings
getSettings = do
    cwd <- getCurrentDirectory
    searchedSettings <- searchSettings cwd
    homeSettings <- searchHome
    return . fromJust $ searchedSettings <|> homeSettings <|> Just defaultLintSettings

main :: IO ()
main = do
    args <- getArgs
    (settings, files) <- parseCLArgs args
    defaultSettings <- getSettings

    let config = fromJust $ settings <|> Just defaultSettings

    lint config files
