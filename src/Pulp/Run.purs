module Pulp.Run where

import Prelude
import Data.Maybe (Maybe(..))
import Data.Map as Map
import Data.StrMap (StrMap())
import Data.StrMap as StrMap
import Data.String (replace)
import Control.Monad.Eff.Class (liftEff)
import Node.Path as Path
import Node.FS.Aff as FS
import Node.Buffer as Buffer
import Node.Encoding (Encoding(UTF8))
import Node.Process as Process

import Pulp.Args
import Pulp.Args.Get
import Pulp.Exec
import Pulp.Files
import Pulp.Outputter
import Pulp.System.Files (openTemp)
import Pulp.System.FFI

action :: Action
action = Action \args -> do
  let opts = Map.union args.globalOpts args.commandOpts
  out <- getOutputter args

  cwd <- liftEff Process.cwd
  out.log $ "Building project in" ++ cwd

  globs <- defaultGlobs opts

  buildPath <- getOption' "buildPath" opts

  psc (sources globs) ["-o", buildPath] Nothing
  out.log "Build successful."

  main <- getOption' "main" opts
  src <- liftEff $ Buffer.fromString (makeEntry main) UTF8

  info <- openTemp { prefix: "pulp-run", suffix: ".js" }
  FS.fdAppend info.fd src
  FS.fdClose info.fd

  runtime <- getOption' "runtime" opts
  env <- setupEnv buildPath
  exec runtime ([info.path] ++ args.remainder) (Just env)

-- | Given a build path, create an environment that is just like this process'
-- | environment, except with NODE_PATH set up for commands like `pulp run`.
setupEnv :: String -> AffN (StrMap String)
setupEnv buildPath = do
  env <- liftEff Process.getEnv
  pure $ StrMap.alter (prependPath (Path.resolve [] buildPath))
                      "NODE_PATH"
                      env

prependPath :: String -> Maybe String -> Maybe String
prependPath newPath paths =
  Just $ case paths of
    Nothing -> newPath
    Just p  -> newPath ++ Path.delimiter ++ p

-- | Escape a string for insertion into a JS string literal.
jsEscape :: String -> String
jsEscape = replace "'" "\\'" <<< replace "\\" "\\\\"

-- | Construct a JS string to be used as an entry point from a module name.
makeEntry :: String -> String
makeEntry main = "require('" ++ jsEscape main ++ "').main();\n"
