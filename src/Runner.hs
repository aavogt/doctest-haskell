{-# LANGUAGE CPP, PatternGuards #-}
module Runner (
  runModules
, Summary(..)

#ifdef TEST
, Report
, ReportState (..)
, report
, report_
#endif
) where

import           Prelude hiding (putStr, putStrLn, error)
import           Data.Monoid
import           Control.Applicative
import           Control.Monad hiding (forM_)
import           Text.Printf (printf)
import           System.IO (hPutStrLn, hPutStr, stderr, hIsTerminalDevice)
import           Data.Foldable (forM_)

import           Control.Monad.Trans.State
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Error

import           Interpreter (Interpreter)
import qualified Interpreter
import           Parse
import           Location
import           Property
import           Runner.Example
import           Text.PrettyPrint.ANSI.Leijen hiding ((<>), (<$>))
import           Text.Read (readMaybe)

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

instance Pretty Summary where
  pretty (Summary examples tried errors failures) =
   foldr1 (\a b -> a <> text "  " <> b) [
    dullgreen (text "Examples:") <+> int examples ,
    dullgreen (text "Tried:")    <+> int tried    ,
    dullgreen (text "Errors:")   <+> good errors  ,
    dullgreen (text "Failures:") <+> good failures]
   where
    good 0 = dullgreen (int 0)
    good n = red (int n)

-- | Sum up summaries.
instance Monoid Summary where
  mempty = Summary 0 0 0 0
  (Summary x1 x2 x3 x4) `mappend` (Summary y1 y2 y3 y4) = Summary (x1 + y1) (x2 + y2) (x3 + y3) (x4 + y4)

-- | Run all examples from a list of modules.
runModules :: Interpreter -> [Module [Located DocTest]] -> IO Summary
runModules repl modules = do
  isInteractive <- hIsTerminalDevice stderr
  ReportState _ _ s <- (`execStateT` ReportState 0 isInteractive mempty {sExamples = c}) $ do
    forM_ modules $ runModule repl

    -- report final summary
    gets (pretty . reportStateSummary) >>= report

  return s
  where
    c = (sum . map count) modules

-- | Count number of expressions in given module.
count :: Module [Located DocTest] -> Int
count (Module _ setup tests) = sum (map length tests) + maybe 0 length setup

-- | A monad for generating test reports.
type Report = StateT ReportState IO

data ReportState = ReportState {
  reportStateCount        :: Int     -- ^ characters on the current line
, reportStateInteractive  :: Bool    -- ^ should intermediate results be printed?
, reportStateSummary      :: Summary -- ^ test summary
}

-- | Add output to the report.
report :: Doc -> Report ()
report msg = do
  overwrite msg

  -- add a newline, this makes the output permanent
  liftIO $ hPutStrLn stderr ""
  modify (\st -> st {reportStateCount = 0})

-- | Add intermediate output to the report.
--
-- This will be overwritten by subsequent calls to `report`/`report_`.
-- Intermediate out may not contain any newlines.
report_ :: Doc -> Report ()
report_ msg = do
  f <- gets reportStateInteractive
  when f $ do
    overwrite msg
    modify (\st -> st {reportStateCount = length (show msg)})

-- | Add output to the report, overwrite any intermediate out.
overwrite :: Doc -> Report ()
overwrite msg = do
  n <- gets reportStateCount
  let str | 0 < n     = "\r" ++ show msg ++ replicate (n - length (show msg)) ' '
          | otherwise = show msg
  liftIO (hPutStr stderr str)

-- | Run all examples from given module.
runModule :: Interpreter -> Module [Located DocTest] -> Report ()
runModule repl (Module module_ setup examples) = do

  Summary _ _ e0 f0 <- gets reportStateSummary

  forM_ setup $
    runTestGroup repl reload

  Summary _ _ e1 f1 <- gets reportStateSummary

  -- only run tests, if setup does not produce any errors/failures
  when (e0 == e1 && f0 == f1) $
    forM_ examples $
      runTestGroup repl setup_
  where
    reload :: IO ()
    reload = do
      -- NOTE: It is important to do the :reload first!  There was some odd bug
      -- with a previous version of GHC (7.4.1?).
      void $ Interpreter.eval repl   ":reload"
      ensureDoctestEq repl
      void $ Interpreter.eval repl $ ":m *" ++ module_

    setup_ :: IO ()
    setup_ = do
      reload
      forM_ setup $ \l -> forM_ l $ \(Located _ x) -> case x of
        Property _  -> return ()
        Example e _ -> void $ Interpreter.eval repl e

infoDoc :: String -> Location -> Expression -> Doc
infoDoc header loc expression =
    onred (red (text "###")) <+> 
        dullgreen (text header <+> text "in") <+>
        pretty loc <> dullgreen (colon <+> text "expression") <+>
        enclose (text "`")
                (text "'")
                (text expression)


reportFailure :: Location -> Expression -> Report ()
reportFailure loc expression = do
  report $ infoDoc "Failure" loc expression
  updateSummary (Summary 0 1 0 1)

reportError :: Location -> Expression -> Doc -> Report ()
reportError loc expression err = do
  report $ infoDoc "Error" loc expression
  report err
  updateSummary (Summary 0 1 1 0)

reportSuccess :: Report ()
reportSuccess =
  updateSummary (Summary 0 1 0 0)

updateSummary :: Summary -> Report ()
updateSummary summary = do
  ReportState n f s <- get
  put (ReportState n f $ s `mappend` summary)

-- | Run given test group.
--
-- The interpreter state is zeroed with @:reload@ first.  This means that you
-- can reuse the same 'Interpreter' for several test groups.
runTestGroup :: Interpreter -> IO () -> [Located DocTest] -> Report ()
runTestGroup repl setup tests = do

  -- report intermediate summary
  gets (pretty . reportStateSummary) >>= report_

  liftIO setup
  runExampleGroup repl examples

  forM_ properties $ \(loc, expression) -> do
    r <- liftIO $ do
      setup
      runProperty repl expression
    case r of
      Success ->
        reportSuccess
      Error err -> do
        reportError loc expression (text err)
      Failure msg -> do
        reportFailure loc expression
        report (text msg)
  where
    properties = [(loc, p) | Located loc (Property p) <- tests]

    examples :: [Located Interaction]
    examples = [Located loc (e, r) | Located loc (Example e r) <- tests]

newtype ReportedError = ReportedError { getReportedError :: Report () }

instance Error ReportedError where
    strMsg m = ReportedError (reportError (UnhelpfulLocation "ReportedError") "" (text ""))

-- |
-- Execute all expressions from given example in given 'Interpreter' and verify
-- the output.
runExampleGroup :: Interpreter -> [Located Interaction] -> Report ()
runExampleGroup repl interactions = either getReportedError return =<< runErrorT (go interactions)
  where

    evErr :: Location -> String -> ErrorT ReportedError Report String
    evErr loc expression = do
      result <- liftIO (Interpreter.safeEval repl expression)
      case result of
        Left err -> throwError (ReportedError (reportError loc expression (text err)))
        Right result -> return result


    go :: [Located Interaction] -> ErrorT ReportedError Report ()
    go ((Located loc (expression, expected)) : xs) = do
      actual <- evErr loc expression
      cleanedExpected <- evErr loc ("doctestCleanExpected "
                                      ++ show (unlines expected))
      cleanedActual <- evErr loc ("doctestCleanActual "
                                      ++ show actual)
      comparisonResult <- evErr loc (show cleanedActual
                                      ++ " `doctestEq` "
                                      ++ show cleanedExpected
                                      ++ " :: Prelude.Bool")

      let ppActualCleaned =
                  dullgreen (text "actual:         ") </> hang 2 (text actual)
            <$$>  dullgreen (text "cleanedActual:  ") </> hang 2 (text cleanedActual)
            <$$>  dullgreen (text "cleanedExpected:") </> hang 2 (text cleanedExpected)
            <$$>  dullgreen (text "comparisonResult:") </> hang 2 (text comparisonResult)
            <$$>  hang 4 (text "where" <$$> hang 2
                         (text "comparisonResult = doctestEq actualCleaned expectCleaned" <$$>
                          text "actualCleaned = doctestCleanActual actual" <$$>
                          text "expectCleaned = doctestCleanExpected expected"))

      case readMaybe comparisonResult of
        Nothing -> throwError $ ReportedError $ reportError loc "read comparisonResult" $
                  ppActualCleaned
        Just True -> do
          lift reportSuccess
          go xs
        Just False -> do
          throwError $ ReportedError $ do
            reportFailure loc expression
            report ppActualCleaned
    go [] = return ()


ensureDoctestEq :: Interpreter -> IO ()
ensureDoctestEq repl = do
 Right _ <- Interpreter.safeEval repl $ unwords
    ["let doctestEq a b = let",
     "g . f = g Prelude.. f;",
     "stripEnd = Prelude.reverse . Prelude.dropWhile Data.Char.isSpace . ",
        "Prelude.reverse;",
     "keepNonempty = Prelude.filter (Prelude./= \"\");",
     "f = Prelude.unlines . keepNonempty . Prelude.map stripEnd . Prelude.lines",
     "in f a Prelude.== f b"]
 Right _ <- Interpreter.safeEval repl "let doctestCleanActual = Prelude.id :: Prelude.String -> Prelude.String"
 Right _ <- Interpreter.safeEval repl "let doctestCleanExpected = Prelude.id :: Prelude.String -> Prelude.String"
 return ()
