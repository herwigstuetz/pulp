module Pulp.Args.Parser where

import Prelude

import Control.Monad.Eff.Exception
import Control.Monad.Error.Class
import Control.Monad.Trans
import Control.Alt
import Data.Array (many)
import Data.Either (Either)
import Data.Foldable (find, elem)
import Data.Traversable (traverse)
import Data.List (List)
import Data.List as List
import Data.Maybe (Maybe(..), maybe)
import Data.Tuple (Tuple(..))
import Data.Foreign (toForeign)

import Data.Map as Map

import Text.Parsing.Parser
import Text.Parsing.Parser.Combinators ((<?>), try)
import Text.Parsing.Parser.Token as Token
import Text.Parsing.Parser.Pos as Pos

import Pulp.Args
import Pulp.System.FFI (AffN())

halt :: forall a. String -> OptParser a
halt err = lift $ throwError $ error err
-- halt err = ParserT $ \s ->
--   return { consumed: true, input: s, result: Left (strMsg err) }

matchNamed :: forall a r. (Eq a) => { name :: a | r } -> a -> Boolean
matchNamed o key = o.name == key

matchOpt :: Option -> String -> Boolean
matchOpt o key = elem key o.match

-- | A version of Text.Parsing.Parser.Token.token which lies about the position,
-- | since we don't care about it here.
token :: forall m a. (Monad m) => ParserT (List a) m a
token = Token.token (const Pos.initialPos)

lookup :: forall m a b. (Monad m, Eq b, Show b) => (a -> b -> Boolean) -> Array a -> ParserT (List b) m (Tuple b a)
lookup match table = do
  next <- token
  case find (\i -> match i next) table of
    Just entry -> return $ Tuple next entry
    Nothing -> fail ("Unknown command: " ++ show next)

lookupOpt :: Array Option -> OptParser (Tuple String Option)
lookupOpt = lookup matchOpt

lookupCmd :: Array Command -> OptParser (Tuple String Command)
lookupCmd = lookup matchNamed

opt :: Array Option -> OptParser Options
opt opts = do
  o <- lookupOpt opts
  case o of
    (Tuple key option) -> do
      val <- option.parser.parser key
      return $ Map.singleton option.name val

arg :: Argument -> OptParser Options
arg a | a.required = do
  next <- token <|> fail ("Required argument \"" <> a.name <> "\" missing.")
  val <- a.parser next
  pure (Map.singleton a.name (Just val))
arg a = do
  val <- (try (Just <$> (token >>= a.parser))) <|> pure Nothing
  pure (maybe Map.empty (Map.singleton a.name <<< Just) val)

cmd :: Array Command -> OptParser Command
cmd cmds = do
  o <- lookupCmd cmds <?> "command"
  case o of
    (Tuple key option) -> return option

extractDefault :: Option -> Options
extractDefault o =
  case o.defaultValue of
    Just def ->
      Map.singleton o.name (Just (toForeign def))
    Nothing ->
      Map.empty

parseArgv :: Array Option -> Array Command -> OptParser Args
parseArgv globals commands = do
  globalOpts <- many $ try $ opt globals
  command <- cmd commands
  commandArgs <- traverse arg command.arguments
  commandOpts <- many $ try $ opt command.options
  rest <- many token
  return $ {
    globalOpts: Map.unions (globalOpts ++ defs globals),
    command: command,
    commandOpts: Map.unions (commandOpts ++ defs command.options),
    commandArgs: Map.unions commandArgs,
    remainder: rest
    }
  where
  defs = map extractDefault

parse :: Array Option -> Array Command -> Array String -> AffN (Either ParseError Args)
parse globals commands s =
  runParserT initialState $ parseArgv globals commands
  where
  initialState = PState { input: List.fromFoldable s, position: Pos.initialPos }
