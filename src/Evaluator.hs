{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE ExistentialQuantification #-}

module Evaluator where

import Data.List hiding (insert, tail)
import Control.Monad.Trans.State.Lazy
import Control.Monad.Error
import Control.Monad.Trans.Except
import Data

-- TODO: change this to some builtin Map type
type LillaEnvironment = [(String, LillaVal)]
type LillaProgram = [LillaVal]
type ThrowsLillaError = Either LillaError
type LillaProgramExecution = StateT LillaEnvironment ThrowsLillaError LillaVal

data ExecutionContext = 
      Global
    | Function
    deriving (Eq, Show)

-- when new builtin Map type is introduced this will no longer be necessary
insert :: (Eq a) => a -> b -> [(a, b)] -> [(a, b)]
-- inserts a LillaVal mapped to a String ID into a LillaEnvironment
insert k v [] = [(k, v)]
insert k v ((k', v'):kvs) 
    | k == k'   = (k', v): kvs
    | otherwise = (k', v'): insert k v kvs  

run :: LillaProgram -> ThrowsLillaError (LillaVal, LillaEnvironment)
-- runs a LillaProgram with empty environment initialised 
run lp = execute Global lp (return (Null, []))

execute :: ExecutionContext -> LillaProgram -> ThrowsLillaError (LillaVal, LillaEnvironment) -> 
           ThrowsLillaError (LillaVal, LillaEnvironment)
-- evaluates a LillaProgram expression by expression recursively
execute _ [] inp = inp
execute Function ((LillaList [AtomicLilla "return", expr]):_) inp = evaluate Function expr inp
execute context (expr:exprs) inp = execute context exprs (evaluate context expr inp)

evaluate :: ExecutionContext -> LillaVal -> ThrowsLillaError (LillaVal, LillaEnvironment) -> 
            ThrowsLillaError (LillaVal, LillaEnvironment)
-- intermediary function to transfer environments between evaluation ticks
evaluate _ exp (Left err) = throwError err
evaluate context exp (Right (_, env)) = case runStateT ((return exp) >>= (eval context)) env of
    Left err        -> throwError err
    Right result    -> Right result

bindVars :: (Eq a) => [(a, b)] -> [(a, b)] -> [(a, b)]
-- chains together two environments and keeps left values in case of overlapping keysets
bindVars [] env = env
bindVars ((var, val):vs) env = bindVars vs (insert var val env)

eval :: ExecutionContext -> LillaVal -> LillaProgramExecution
-- evaluates a Lilla Expression
eval _ Null = return Null
eval _ val@(NumericLilla _) = return val
eval _ val@(StringLilla _) = return val
eval _ val@(BooleanLilla _) = return val
eval _ val@(AtomicLilla var) = do
    env <- get
    case lookup var env of
        Nothing  -> throwError $ Default $ "NameError: " ++ (show var) ++ " is not defined."
        Just x   -> return x
eval context (LillaList [AtomicLilla var, AtomicLilla "=", val]) = do
    x <- (eval context) val
    modify (insert var x)
    return val
eval context (LillaList [AtomicLilla "return", expr]) = case context of
    Function  -> (eval context) expr
    Global    -> throwError $ Default "Cannot return in Global context." 

eval context (LillaList [AtomicLilla "if", pred, LillaList conseqs, 
              AtomicLilla "else", LillaList alts]) = do
        result <- (eval context) pred
        env <- get
        case result of 
            BooleanLilla x -> case execute context (if x then conseqs else alts) (return (Null, env)) of
                Left err  -> throwError $ err
                Right (val, env) -> do
                    put env
                    return val
            x@_              -> throwError $ Default $ "TypeError: " ++ (show x) ++ " expecting Bool."

eval context (LillaList [AtomicLilla "primitive", AtomicLilla func, args@(LillaList _)]) = do
    args' <- (eval context) args
    case evaluatePrimitiveFunc func args' of
        Left err  -> throwError err
        Right val -> return val

eval context (LillaList [AtomicLilla func, args@(LillaList _)]) = do
    env   <- get
    args' <- (eval context) args
    case evaluateUserDefinedFunc func env args' of
        Left err  -> throwError $ err
        Right val -> return val

eval context (LillaList xs) = do
    env <- get
    case mapM (\x -> runStateT (return x >>= (eval context)) env) xs of
        Left err -> throwError err
        Right ls -> return $ LillaList $ fst <$> ls

eval _ _ = throwError $ Default "Bad special form." 

evaluateUserDefinedFunc ::  String -> LillaEnvironment -> LillaVal -> ThrowsLillaError LillaVal
evaluateUserDefinedFunc func env (LillaList args) = case lookup func env of
    Nothing -> throwError $ Default $ "NameError: " ++ func ++ " is not defined."
    Just func'@(LillaFunc args' body) -> case (length args) == (length args') of
        True -> case execute Function body (return (Null, bindVars env $ zip args' args)) of
            Right (val, _) -> return val
            Left err       -> throwError err
        False -> throwError $ Default $ "TypeError: " ++ func ++ " is expecting " ++ (show $ length args') 
    Just _                            -> throwError $ Default $ "TypeError: "  ++ func ++ " is not callable."
    Nothing                           -> throwError $ Default $ "NameError: " ++ func ++ " is not defined."
evaluateUserDefinedFunc _ _ _ = throwError $ Default "Bad special form." 

evaluatePrimitiveFunc :: String -> LillaVal -> ThrowsLillaError LillaVal
evaluatePrimitiveFunc func (LillaList args) = case lookup func primitives of
    Nothing    -> throwError $ Default $ "NameError: " ++ func ++ " is not defined."
    Just func' -> case func' args of
        Left  err -> throwError err
        Right val -> return val
evaluatePrimitiveFunc _ _ = throwError $ Default "Bad special form." 

primitives :: [(String, [LillaVal] -> ThrowsLillaError LillaVal)]
primitives = [
        ("plus", numericBinop (+)), 
        ("minus", numericBinop (-)), 
        ("mul", numericBinop (*)), 
        ("div", numericBinop div),
        ("mod", numericBinop mod), 
        ("quotient", numericBinop quot), 
        ("remainder", numericBinop rem),
        ("eqv", numBoolBinop (==)),
        ("lt", numBoolBinop (<)),
        ("gt", numBoolBinop (>)),
        ("ne", numBoolBinop (/=)),
        ("gte", numBoolBinop (>=)),
        ("lte", numBoolBinop (<=)),
        ("_eqv", strBoolBinop (==)),
        ("_lt", strBoolBinop (<)),
        ("_gt", strBoolBinop (>)),
        ("_ne", strBoolBinop (/=)),
        ("_gte", strBoolBinop (>=)),
        ("_lte", strBoolBinop (<=)),
        ("and", boolBoolBinop (&&)),
        ("or", boolBoolBinop (||)),
        ("head", head'),
        ("tail", tail'),
        ("cons", cons),
        ("concat", conc),
        ("replicate", repl)
    ]

head' :: [LillaVal] -> ThrowsLillaError LillaVal
head' [LillaList (x:_)] = return x
head' [LillaList _] = throwError $ Default "Error: no head of empty list."
head' (x:xs) = throwError $ Default "TypeError: head takes exactly 1 argument."
head' _ = throwError $ Default "Bad special form."

tail' :: [LillaVal] -> ThrowsLillaError LillaVal
tail' [LillaList (_:xs)] = return $ LillaList xs
tail' [LillaList _] = throwError $ Default "Error: no tail of empty list."
tail' (x:xs) = throwError $ Default "TypeError: head takes exactly 1 argument."
tail' _ = throwError $ Default "Bad special form."

cons :: [LillaVal] -> ThrowsLillaError LillaVal
cons [x, LillaList []] = return $ LillaList [x]
cons [x, LillaList xs] = return $ LillaList (x:xs)
cons [_, _] = throwError $ Default "TypeError: expecting List as 2nd argument."
cons _ = throwError $ Default "TypeError: cons takes exactly 2 arguments."

conc :: [LillaVal] -> ThrowsLillaError LillaVal
conc [LillaList xs, LillaList xs'] = return $ LillaList $ xs ++ xs'
conc [_, _] = throwError $ Default "TypeError: concat takes exactly 2 arguments of type List."
conc _ =throwError $ Default "TypeError: concat takes exactly 2 arguments."

repl :: [LillaVal] -> ThrowsLillaError LillaVal
repl [NumericLilla n, LillaList xs] = return $ LillaList $ concat $ replicate (fromIntegral n) xs
repl [_, LillaList _] = throwError $ Default "TypeError: expecting Integer as 1st argument."
repl [NumericLilla _, _] = throwError $ Default "TypeError: expecting List as 2nd argument."
repl [_, _] = throwError $ Default "TypeError: expecting arguments of types Integer and List."
repl _ = throwError $ Default "TypeError: repl takes exactly 2 arguments."

boolBinop :: (LillaVal -> ThrowsLillaError a) -> (a -> a -> Bool) -> [LillaVal] -> ThrowsLillaError LillaVal
boolBinop unpacker op args 
    | length args /= 2 = 
        throwError $ Default $ "TypeError: function is expecting 2 args, currently has:"  ++ (show $ length args) ++ "."
    | otherwise        = do
        left <- unpacker $ args !! 0
        right <- unpacker $ args !! 1
        return . BooleanLilla $ left `op` right

numBoolBinop = boolBinop unpackNum
strBoolBinop = boolBinop unpackStr
boolBoolBinop = boolBinop unpackBool

unpackStr :: LillaVal -> ThrowsLillaError String
unpackStr (StringLilla s) = return s
unpackStr notString = throwError $ Default "Typerror: expecting String." 

unpackBool :: LillaVal -> ThrowsLillaError Bool
unpackBool (BooleanLilla b) = return b
unpackBool notBool = throwError $ Default "Typerror: expecting Bool."

numericBinop :: (Integer -> Integer -> Integer) -> [LillaVal] -> ThrowsLillaError LillaVal
numericBinop op [_] = throwError $ Default "TypeError: expecting 2 arguments, got 1 instead."
numericBinop op params = mapM unpackNum params >>= return . NumericLilla . foldl1 op

unpackNum :: LillaVal -> ThrowsLillaError Integer
unpackNum (NumericLilla n) = return n
unpackNum notNum = throwError $ Default "Typerror: expecting Integer."
