{-# LANGUAGE CPP #-}
module Report (
  runModules
, Summary(..)

#ifdef TEST
, Report
, ReportState (..)
, report
, report_
, reportNotEqual
#endif
) where

import           Prelude hiding (putStr, putStrLn, error)
import           Data.Monoid
import           Control.Applicative
import           Control.Monad
import           Text.Printf (printf)
import           System.IO (hPutStrLn, hPutStr, stderr, hIsTerminalDevice)
import           Data.Char

import           Control.Monad.Trans.State
import           Control.Monad.IO.Class

import           Interpreter (Interpreter)
import qualified Interpreter
import           Parse
import           Location
import           Property

-- | Summary of a test run.
data Summary = Summary {
  sExamples :: Int
, sTried    :: Int
, sErrors   :: Int
, sFailures :: Int
} deriving Eq

-- | Format a summary.
instance Show Summary where
  show (Summary examples tried errors failures) =
    printf "Examples: %d  Tried: %d  Errors: %d  Failures: %d" examples tried errors failures

-- | Sum up summaries.
instance Monoid Summary where
  mempty = Summary 0 0 0 0
  (Summary x1 x2 x3 x4) `mappend` (Summary y1 y2 y3 y4) = Summary (x1 + y1) (x2 + y2) (x3 + y3) (x4 + y4)

-- | Run all examples from a list of modules.
runModules :: Interpreter -> [Module DocTest] -> IO Summary
runModules repl modules = do
  isInteractive <- hIsTerminalDevice stderr
  ReportState _ _ s <- (`execStateT` ReportState 0 isInteractive mempty {sExamples = c}) $ do
    forM_ modules $ runModule repl

    -- report final summary
    gets (show . reportStateSummary) >>= report

  return s
  where
    c = (sum . map count) modules

-- | Count number of expressions in given module.
count :: Module DocTest -> Int
count (Module _ examples) = (sum . map f) examples
  where
    f :: DocTest -> Int
    f (Example x)  = length x
    f (Property _) = 1

-- | A monad for generating test reports.
type Report = StateT ReportState IO

data ReportState = ReportState {
  reportStateCount        :: Int     -- ^ characters on the current line
, reportStateInteractive  :: Bool    -- ^ should intermediate results be printed?
, reportStateSummary      :: Summary -- ^ test summary
}

-- | Add output to the report.
report :: String -> Report ()
report msg = do
  overwrite msg

  -- add a newline, this makes the output permanent
  liftIO $ hPutStrLn stderr ""
  modify (\st -> st {reportStateCount = 0})

-- | Add intermediate output to the report.
--
-- This will be overwritten by subsequent calls to `report`/`report_`.
-- Intermediate out may not contain any newlines.
report_ :: String -> Report ()
report_ msg = do
  f <- gets reportStateInteractive
  when f $ do
    overwrite msg
    modify (\st -> st {reportStateCount = length msg})

-- | Add output to the report, overwrite any intermediate out.
overwrite :: String -> Report ()
overwrite msg = do
  n <- gets reportStateCount
  let str | 0 < n     = "\r" ++ msg ++ replicate (n - length msg) ' '
          | otherwise = msg
  liftIO (hPutStr stderr str)

-- | Run all examples from given module.
runModule :: Interpreter -> Module DocTest -> Report ()
runModule repl (Module name examples) = do
  forM_ examples $ \e -> do

    -- report intermediate summary
    gets (show . reportStateSummary) >>= report_

    runDocTest repl name e

reportFailure :: Location -> Expression -> Report ()
reportFailure loc expression = do
  report (printf "### Failure in %s: expression `%s'" (show loc) expression)
  updateSummary (Summary 0 1 0 1)

reportError :: Location -> Expression -> String -> Report ()
reportError loc expression err = do
  report (printf "### Error in %s: expression `%s'" (show loc) expression)
  report err
  updateSummary (Summary 0 1 1 0)

reportSuccess :: Report ()
reportSuccess =
  updateSummary (Summary 0 1 0 0)

updateSummary :: Summary -> Report ()
updateSummary summary = do
  ReportState n f s <- get
  put (ReportState n f $ s `mappend` summary)

reportNotEqual :: [String] -> [String] -> Report ()
reportNotEqual expected actual = do
  outputLines "expected: " expected
  outputLines " but got: " actual
  where

    -- print quotes if any line ends with trailing whitespace
    printQuotes = any isSpace (map last . filter (not . null) $ expected ++ actual)

    -- use show to escape special characters in output lines if any output line
    -- contains any unsafe character
    escapeOutput = any (not . isSafe) (concat $ expected ++ actual)

    isSafe :: Char -> Bool
    isSafe c = c == ' ' || (isPrint c && (not . isSpace) c)

    outputLines message l_ = case l of
      x:xs -> do
        report (message ++ x)
        let padding = replicate (length message) ' '
        forM_ xs $ \y -> report (padding ++ y)
      []   ->
        report message
      where
        l | printQuotes || escapeOutput = map show l_
          | otherwise                   = l_

-- | Run given `DocTest`.
--
-- The interpreter state is zeroed with @:reload@ first.  This means that you
-- can reuse the same 'Interpreter' for several calls to `runDocTest`.
runDocTest :: Interpreter -> String -> DocTest -> Report ()
runDocTest repl module_ docTest = do
  _ <- liftIO $ Interpreter.eval repl   ":reload"
  _ <- liftIO $ Interpreter.eval repl $ ":m *" ++ module_
  case docTest of
    Example xs -> runExample repl xs
    Property (Located loc expression) -> do
      r <- liftIO $ runProperty repl expression
      case r of
        Success ->
          reportSuccess
        Error err -> do
          reportError loc expression err
        Failure msg -> do
          reportFailure loc expression
          report msg

-- |
-- Execute all expressions from given example in given 'Interpreter' and verify
-- the output.
runExample :: Interpreter -> [Located Interaction] -> Report ()
runExample repl = go
  where
    go ((Located loc (Interaction expression expected)) : xs) = do
      r <- fmap lines <$> liftIO (Interpreter.safeEval repl expression)
      case r of
        Left err -> do
          reportError loc expression err
        Right actual -> do
          if expected /= actual
            then do
              reportFailure loc expression
              reportNotEqual expected actual
            else do
              reportSuccess
              go xs
    go [] = return ()
