module Parser where 

import Text.ParserCombinators.Parsec 
import Control.Monad.Error
import Control.Monad.Trans.Except
import Data
import Evaluator
import Control.Monad


-- Main Parser Function that parses sourcecode --
-- into a sequence (LillaVal) expressions -------
-------------------------------------------------
parseExprs :: Int -> Parser [LillaVal]
parseExprs n@indentation = do
    exprs <- many $ (
                (try $ parseFunc n) 
                <|> (try $ parseIfElseBlock n) 
                <|> (try $ parseExprInLine n)
                <|> parseEmptyLine
            )
    return exprs

{- 
Main sub parsers that parse all the main
complex expression types:
 - function definition
 - if-else code block
 - single line expression
-}

-- parses function definition
parseFunc :: Int -> Parser LillaVal
parseFunc n@indent = do
    indentation n >> makeStringParser "function"
    name <- ignoreFirst (char ' ') word
    ignoreFirst (char ' ') (char '(')
    args <- sepBy (ignoreFirst (char ' ') word) (char ',')
    ignoreFirst (char ' ') (char ')')
    ignoreFirst (char ' ') (char '\n')
    bodyExprs <- parseExprs $ n + 1
    return $ LillaFunc args bodyExprs

-- parses if-else code block
parseIfElseBlock :: Int -> Parser LillaVal
parseIfElseBlock n@indent = do
    indentation n >> (makeStringParser "if")
    predicate <- ignoreFirst (char ' ') parseExpr
    colon >> char '\n'
    consExprs <- parseExprs $ n + 1
    indentation n >> makeStringParser "else" >> colon >> char '\n'
    altExprs <- parseExprs $ n + 1
    return $ LillaList [AtomicLilla "if", predicate, 
        LillaList consExprs, AtomicLilla "else", 
        LillaList altExprs] where 
        colon = ignoreFirst (char ' ') (char ':')

-- parses a single Expression on a single line
parseExprInLine :: Int -> Parser LillaVal
parseExprInLine n@indent = do     
    expr <- if n == 0
        then parseExpr
        else indentation n >> parseExpr
    ignoreFirst (char ' ') (char '\n')
    return expr

-- parses an empty line
parseEmptyLine :: Parser LillaVal
parseEmptyLine = do
    many emptyCharParser
    char '\n'
    return Null
    where emptyCharParser = makeParsers char [' ', '\t', '\r']


-- Main Expression parser function that parses --
-- all the diffferent kinds of expressions ------
-------------------------------------------------
parseExpr :: Parser LillaVal
parseExpr = p1 <|> p2 <|> parseEmpty <|> parseExpr where
        p1 = (try parseAssignment) <|> (try parseFuncCall) 
                                   <|> (try parseReturnStatement) 
                                   <|> parseAtom
        p2 = parseNumber <|> parseString 
                         <|> parseBool
        parseEmpty = do
            makeStringParser ""
            return Null

{- 
Main expression parsers that parse all the 
main simple expression types:
Expression types:
 - primitives (Number, Bool, String)
 - variable
 - variable assignment
 - function call
 - return statement
-}

-- parses a numeric value
parseNumber :: Parser LillaVal
parseNumber = liftM (NumericLilla . read) $ many1 digit 

-- parses a boolean vaklue
parseBool :: Parser LillaVal
parseBool = do
    boolVal <- (makeStringParser "True") <|> (makeStringParser "False")
    return $ BooleanLilla . read $ boolVal

-- parses a string 
parseString :: Parser LillaVal
parseString = do
    char '"'
    x <- many (escapeCharParser <|> noneOf "\"")
    char '"'
    return $ StringLilla x where
        escapeCharParser = 
            makeEscapeCharParsers [
                ("\\\n", '\n'), 
                ("\\\r", '\r'),
                ("\\\t", '\t'),
                ("\\", '\\')
            ]

-- parses a variabloe
parseAtom :: Parser LillaVal
parseAtom = do
    atom <- word
    return $ AtomicLilla atom

-- parses variable assignment
parseAssignment :: Parser LillaVal
parseAssignment =  do
    var <- parseAtom
    assignment <- ignoreFirst (char ' ') (makeStringParser "=")
    expr <- ignoreFirst (char ' ') parseExpr
    return $ LillaList [var, AtomicLilla assignment, expr]

-- parses function call
parseFuncCall :: Parser LillaVal
parseFuncCall =  do
    func <- ignoreFirst (char ' ') parseAtom
    ignoreFirst (char ' ') (char '(')
    args <- sepBy (ignoreFirst (char ' ') parseExpr) (char ',')
    ignoreFirst (char ' ') (char ')')
    return $ if elem (unpack func) (fst <$> primitives)
        then LillaList [AtomicLilla "primitive", func, LillaList args]
        else LillaList [func, LillaList args] where
            unpack = (\(AtomicLilla x) -> x)

-- parses return statement
parseReturnStatement :: Parser LillaVal
parseReturnStatement = do
    makeStringParser "return" >> (char ' ')
    expr <- ignoreFirst (char ' ') parseExpr
    return $ LillaList [AtomicLilla "return", expr]


-- PARSER HELPERS --
--------------------

indentation :: Int -> Parser String
indentation n = (makeStringParser $ replicate (n * 4) ' ')

word :: Parser String
word = do
    first <- letter
    rest <- many (letter <|> digit)
    return $ [first] ++ rest

ignoreFirst :: Parser a -> Parser b -> Parser b
ignoreFirst pa pb = many pa >> pb

makeSequenceParser :: [a] -> (a -> Parser a) -> Parser [a]
makeSequenceParser [] _ = return []
makeSequenceParser (x:xs) f = do
    x' <- f x
    xs' <- makeSequenceParser xs f
    return $ x':xs'

makeStringParser :: String -> Parser String
makeStringParser string = makeSequenceParser string char

makeParsers :: (a -> Parser a) -> [a] -> Parser a
makeParsers _ [] = error "Can't make empty parser."
makeParsers p (x:xs) = foldr (\x' acc -> (p x') <|> acc) (p x) xs

makeEscapeCharParser :: String -> Char -> Parser Char
makeEscapeCharParser [] c = return c
makeEscapeCharParser (c:cs) c' = do
    char c
    makeEscapeCharParser cs c' 

makeEscapeCharParsers :: [(String, Char)] -> (Parser Char)
makeEscapeCharParsers [] = error "empty"
makeEscapeCharParsers ((str, c):tail) = 
    foldr (\(str', c') acc -> (makeEscapeCharParser str' c') <|> acc) (makeEscapeCharParser str c) tail

----------------------------
-- TESTS: ------------------
----------------------------

test1 :: String
test1 = "\n    x = plus(5, 6)\n    r = minus(3, 4)\nz=mul(minus(5, 3), 7)\n" -- y = plus(plus(5, 7), 9)\nxs = replicate(5, \"kaka\", 8)\n"

test2 :: String
test2 = "    x = plus(5, \"redf\", replicate(5, 6, minus(10, 2)))\n"

f :: String -> Either ParseError [LillaVal]
f = parse (parseExprs 1) "x"

g :: String -> Either ParseError LillaVal
g = parse (parseExpr) "x"

--h :: Parser a -> String -> Either ParseError a
--h p s = parse p "x"

test3 :: String
test3 = "if gt(5, 6):\n    x = 10\n    y = plus(f, g)\n    z = plus(minus(4, 7), 8)\nelse:\n    v = mul(5, 6)\n    t = min(mul(5, 1), 8)\n"

test4 :: String
test4 = "    x = 10\n\n    y = plus(f, g)\n\n    z = plus(minus(4, 7), 8)\n\n    v = mul(5, 6)\n\n    t = min(mul(5, 1), 8)\n\n"