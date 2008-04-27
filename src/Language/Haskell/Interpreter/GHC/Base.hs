module Language.Haskell.Interpreter.GHC.Base

where

import Control.Monad.Trans     ( MonadIO(liftIO) )
import Control.Monad.Reader    ( ReaderT, ask, runReaderT )
import Control.Monad.Error     ( Error(..), MonadError(..), ErrorT, runErrorT )

import Control.Exception       ( throwDyn )

import Control.Concurrent.MVar ( MVar, newMVar, withMVar )
import Data.IORef              ( IORef, newIORef,
                                 modifyIORef, atomicModifyIORef )

import Data.Typeable           ( Typeable )

import qualified GHC
import qualified Outputable as GHC.O
import qualified SrcLoc     as GHC.S
import qualified ErrUtils   as GHC.E


import qualified Language.Haskell.Interpreter.GHC.Compat as Compat

-- autogenerated by Cabal script
import Language.Haskell.Interpreter.GHC.LibDir ( ghc_libdir )


newtype Interpreter a =
    Interpreter{unInterpreter :: ReaderT SessionState
                                (ErrorT  InterpreterError
                                 IO)     a}
    deriving (Typeable, Functor, Monad, MonadIO)


instance MonadError InterpreterError Interpreter where
    throwError  = Interpreter . throwError
    catchError (Interpreter m) catchE = Interpreter $ m `catchError` (\e ->
                                                       unInterpreter $ catchE e)

data InterpreterError = UnknownError String
                      | WontCompile [GhcError]
                      | NotAllowed  String
                      deriving (Show, Typeable)

instance Error InterpreterError where
    noMsg  = UnknownError ""
    strMsg = UnknownError


-- I'm assuming operations on a ghcSession are not thread-safe. Besides, we need
-- to be sure that messages captured by the log handler correspond to a single
-- operation. Hence, we put the whole state on an MVar, and synchronize on it
newtype InterpreterSession =
    InterpreterSession {sessionState :: MVar SessionState}

data SessionState = SessionState{ghcSession     :: GHC.Session,
                                 ghcErrListRef  :: IORef [GhcError],
                                 ghcErrLogger   :: GhcErrLogger}

-- When intercepting errors reported by GHC, we only get a GHC.E.Message
-- and a GHC.S.SrcSpan. The latter holds the file name and the location
-- of the error. However, SrcSpan is abstract and it doesn't provide
-- functions to retrieve the line and column of the error... we can only
-- generate a string with this information. Maybe I can parse this string
-- later.... (sigh)
data GhcError = GhcError{errMsg :: String} deriving Show

mkGhcError :: GHC.S.SrcSpan -> GHC.O.PprStyle -> GHC.E.Message -> GhcError
mkGhcError src_span style msg = GhcError{errMsg = niceErrMsg}
    where niceErrMsg = GHC.O.showSDoc . GHC.O.withPprStyle style $
                         GHC.E.mkLocMessage src_span msg

type GhcErrLogger = GHC.Severity
                 -> GHC.S.SrcSpan
                 -> GHC.O.PprStyle
                 -> GHC.E.Message
                 -> IO ()

-- ================= Creating a session =========================

-- | Builds a new session using the (hopefully) correct path to the GHC in use.
-- (the path is determined at build time of the package)
newSession :: IO InterpreterSession
newSession = newSessionUsing ghc_libdir

-- | Builds a new session, given the path to a GHC installation
--  (e.g. \/usr\/local\/lib\/ghc-6.6).
newSessionUsing :: FilePath -> IO InterpreterSession
newSessionUsing ghc_root =
    do
        ghc_session      <- Compat.newSession ghc_root
        --
        ghc_err_list_ref <- newIORef []
        let log_handler  =  mkLogHandler ghc_err_list_ref
        --
        let session_state = SessionState{ghcSession     = ghc_session,
                                         ghcErrListRef  = ghc_err_list_ref,
                                         ghcErrLogger   = log_handler}
        --
        -- set HscTarget to HscInterpreted (default is HsAsm!).
        -- setSessionDynFlags loads info on packages availables; this call
        -- is mandatory!
        -- also set a custom log handler, to intercept error messages :S
        dflags <- GHC.getSessionDynFlags ghc_session
        let myFlags = dflags{GHC.hscTarget  = GHC.HscInterpreted,
                             GHC.log_action = log_handler}
        GHC.setSessionDynFlags ghc_session myFlags
        --
        return . InterpreterSession =<< newMVar session_state

mkLogHandler :: IORef [GhcError] -> GhcErrLogger
mkLogHandler r _ src style msg = modifyIORef r (errorEntry :)
    where errorEntry = mkGhcError src style msg


-- ================= Executing the interpreter ==================

-- | Executes the interpreter using a given session. This is a thread-safe
--   operation, if the InterpreterSession is in-use, the call will block until
--   the other one finishes.
--
--   In case of error, it will throw a dynamic InterpreterError exception.
withSession :: InterpreterSession -> Interpreter a -> IO a
withSession s i = withMVar (sessionState s) $ \ss ->
    do err_or_res <- runErrorT . flip runReaderT ss $ unInterpreter i
       either throwDyn return err_or_res


-- ================ Handling the interpreter state =================

fromSessionState :: (SessionState -> a) -> Interpreter a
fromSessionState f = Interpreter $ fmap f ask

-- modifies the session state and returns the old value
modifySessionState :: Show a
                   => (SessionState -> IORef a)
                   -> (a -> a)
                   -> Interpreter a
modifySessionState target f =
    do
        ref     <- fromSessionState target
        old_val <- liftIO $ atomicModifyIORef ref (\a -> (f a, a))
        return old_val