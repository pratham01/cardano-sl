module Main
       ( main
       ) where

import           Universum
import qualified Universum.Unsafe as Unsafe (fromJust)

import           Control.Exception.Safe (handle)
import           Data.Constraint (Dict (..))
import           Formatting (sformat, shown, (%))
import           Mockable (Production, runProduction)
import           JsonLog (jsonLog)
import qualified Network.Transport.TCP as TCP (TCPAddr (..))
import qualified System.IO.Temp as Temp
import           System.Wlog (LoggerName, logInfo)

import qualified Pos.Client.CLI as CLI
import           Pos.Communication (OutSpecs)
import           Pos.Communication.Util (ActionSpec (..))
import           Pos.Core (ConfigurationError)
import           Pos.Configuration (networkConnectionTimeout)
import           Pos.DB.DB (initNodeDBs)
import           Pos.Diffusion.Transport.TCP (bracketTransportTCP)
import           Pos.Diffusion.Types (DiffusionLayer (..))
import           Pos.Diffusion.Full (diffusionLayerFull)
import           Pos.Logic.Full (logicLayerFull)
import           Pos.Logic.Types (LogicLayer (..))
import           Pos.Launcher (HasConfigurations, NodeParams (..), NodeResources,
                               bracketNodeResources, loggerBracket, lpConsoleLog, runNode,
                               elimRealMode, withConfigurations)
import           Pos.Network.Types (NetworkConfig (..), Topology (..), topologyDequeuePolicy,
                                    topologyEnqueuePolicy, topologyFailurePolicy)
import           Pos.Txp (txpGlobalSettings)
import           Pos.Update (lastKnownBlockVersion)
import           Pos.Util (logException)
import           Pos.Util.CompileInfo (HasCompileInfo, retrieveCompileTimeInfo, withCompileInfo)
import           Pos.Util.Config (ConfigurationException (..))
import           Pos.Util.UserSecret (usVss)
import           Pos.WorkMode (EmptyMempoolExt, RealMode)
import           Pos.Worker.Types (WorkerSpec)

import           AuxxOptions (AuxxAction (..), AuxxOptions (..), AuxxStartMode (..), getAuxxOptions)
import           Mode (AuxxContext (..), AuxxMode)
import           Plugin (auxxPlugin, rawExec)
import           Repl (WithCommandAction (..), withAuxxRepl)

loggerName :: LoggerName
loggerName = "auxx"

-- 'NodeParams' obtained using 'CLI.getNodeParams' are not perfect for
-- Auxx, so we need to adapt them slightly.
correctNodeParams :: AuxxOptions -> NodeParams -> Production (NodeParams, Bool)
correctNodeParams AuxxOptions {..} np = do
    (dbPath, isTempDbUsed) <- case npDbPathM np of
        Nothing -> do
            tempDir <- liftIO $ Temp.getCanonicalTemporaryDirectory
            dbPath <- liftIO $ Temp.createTempDirectory tempDir "nodedb"
            logInfo $ sformat ("Temporary db created: "%shown) dbPath
            return (dbPath, True)
        Just dbPath -> do
            logInfo $ sformat ("Supplied db used: "%shown) dbPath
            return (dbPath, False)
    let np' = np
            { npNetworkConfig = networkConfig
            , npRebuildDb = npRebuildDb np || isTempDbUsed
            , npDbPathM = Just dbPath }
    return (np', isTempDbUsed)
  where
    topology = TopologyAuxx aoPeers
    networkConfig =
        NetworkConfig
        { ncDefaultPort = 3000
        , ncSelfName = Nothing
        , ncEnqueuePolicy = topologyEnqueuePolicy topology
        , ncDequeuePolicy = topologyDequeuePolicy topology
        , ncFailurePolicy = topologyFailurePolicy topology
        , ncTopology = topology
        , ncTcpAddr = TCP.Unaddressable
        }

runNodeWithSinglePlugin ::
       (HasConfigurations, HasCompileInfo)
    => NodeResources EmptyMempoolExt
    -> (WorkerSpec AuxxMode, OutSpecs)
    -> (WorkerSpec AuxxMode, OutSpecs)
runNodeWithSinglePlugin nr (plugin, plOuts) =
    runNode nr ([plugin], plOuts)

action :: HasCompileInfo => AuxxOptions -> Either WithCommandAction Text -> Production ()
action opts@AuxxOptions {..} command = do
    let runWithoutNode = rawExec Nothing opts Nothing command
    printAction <- either getPrintAction (const $ return putTextLn) command

    let configToDict :: HasConfigurations => Production (Maybe (Dict HasConfigurations))
        configToDict = return (Just Dict)

    hasConfigurations <- case aoStartMode of
        Automatic -> do
            mode <- handle @_ @ConfigurationException  (return . const Nothing)
                  . handle @_ @ConfigurationError      (return . const Nothing)
                  $ withConfigurations conf configToDict
            mode <$ case mode of
                Nothing -> printAction "Mode: light"
                _       -> printAction "Mode: with-config"
        Light -> return Nothing
        _ -> withConfigurations conf configToDict

    case hasConfigurations of
      Nothing -> runWithoutNode
      Just Dict -> do
          CLI.printInfoOnStart aoCommonNodeArgs
          (nodeParams, tempDbUsed) <-
              correctNodeParams opts =<< CLI.getNodeParams loggerName cArgs nArgs
          let
              toRealMode :: AuxxMode a -> RealMode EmptyMempoolExt a
              toRealMode auxxAction = do
                  realModeContext <- ask
                  let auxxContext =
                          AuxxContext
                          { acRealModeContext = realModeContext
                          , acTempDbUsed = tempDbUsed }
                  lift $ runReaderT auxxAction auxxContext
          let vssSK = Unsafe.fromJust $ npUserSecret nodeParams ^. usVss
          let sscParams = CLI.gtSscParams cArgs vssSK (npBehaviorConfig nodeParams)
          bracketNodeResources nodeParams sscParams txpGlobalSettings initNodeDBs $ \nr ->
              elimRealMode nr $ toRealMode $
                  logicLayerFull jsonLog $ \logicLayer ->
                      bracketTransportTCP networkConnectionTimeout (ncTcpAddr (npNetworkConfig nodeParams)) $ \transport ->
                          diffusionLayerFull (npNetworkConfig nodeParams) lastKnownBlockVersion transport Nothing $ \withLogic -> do
                              diffusionLayer <- withLogic (logic logicLayer)
                              let modifier = if aoStartMode == WithNode then runNodeWithSinglePlugin nr else identity
                                  (ActionSpec auxxModeAction, _) = modifier (auxxPlugin opts command)
                              runLogicLayer logicLayer (runDiffusionLayer diffusionLayer (auxxModeAction (diffusion diffusionLayer)))
  where
    cArgs@CLI.CommonNodeArgs {..} = aoCommonNodeArgs
    conf = CLI.configurationOptions (CLI.commonArgs cArgs)
    nArgs =
        CLI.NodeArgs {behaviorConfigPath = Nothing}

main :: IO ()
main = withCompileInfo $(retrieveCompileTimeInfo) $ do
    opts <- getAuxxOptions
    let disableConsoleLog
            | Repl <- aoAction opts =
                  -- Logging in the REPL disrupts the prompt,
                  -- so we disable it.
                  -- TODO: When LW-25 is resolved we also want
                  -- to be able to enable logging in REPL using
                  -- a Haskeline-compatible print action.
                  \lp -> lp { lpConsoleLog = Just False }
            | otherwise = identity
        loggingParams = disableConsoleLog $
            CLI.loggingParams loggerName (aoCommonNodeArgs opts)
    loggerBracket loggingParams . logException "auxx" $ do
        let runAction a = runProduction $ action opts a
        case aoAction opts of
            Repl    -> withAuxxRepl $ \c -> runAction (Left c)
            Cmd cmd -> runAction (Right cmd)
