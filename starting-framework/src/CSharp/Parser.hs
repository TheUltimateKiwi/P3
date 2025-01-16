{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use void" #-}

-- This module implements a parser for
--  (a subset of) the C# programming language

-- This parser is split into two parts:
--  1. A *Lexer* that breaks a string into a list of tokens
--  2. A *Parser* that operates over a list of tokens

-- This Context-Free Grammar for (a subset of) C# is implemented here.
-- In this CFG, all nonterminals start with a capital letter.
-- The terminals [upperid, lowerid, operator, const] are special tokens,
-- all other terminals are presented verbatim.
{-
Class ::= Class upperid { Member∗ }
Member ::= Decl ; | Method
Method ::= Typevoid lowerid ( Decls? ) Block
Decls ::= Decl | Decl , Decls
Decl ::= Type lowerid
Block ::= { Statdecl∗ }
Statdecl ::= Stat | Decl ;
Stat ::= Expr ;
       | if ( Expr ) Stat Else?
       | while ( Expr ) Stat
       | return Expr ;
       | Block
Else ::= else Stat
Typevoid ::= Type | void
Type ::= int | bool
Expr ::= Exprsimple
       | Exprsimple operator Expr
Exprsimple ::= const | lowerid | ( Expr )
-}

module CSharp.Parser where

import CSharp.AbstractSyntax

import ParseLib hiding (braced, bracketed, parenthesised)
import Control.Applicative
import Data.Char
import Data.Maybe

---- Begin Pretty-printing functions for C# syntax ----

-- Concrete syntax of C# types
printType :: Type -> String
printType = \case
  { TyInt -> "int"; TyBool -> "bool"}

-- Concrete syntax of C# binary operators
printOperator :: Operator -> String
printOperator = \case
  { OpAdd -> "+"; OpSub -> "-"; OpMul -> "*"; OpDiv -> "/"
  ; OpMod -> "%"
  ; OpAnd -> "&&"; OpOr -> "||"; OpXor -> "^"
  ; OpLeq -> "<="; OpLt -> "<"
  ; OpGeq -> ">="; OpGt -> ">"
  ; OpEq  -> "=="; OpNeq -> "!="
  ; OpAsg -> "="
  }

-- Concrete syntax of C# keywords
printKeyword :: Keyword -> String
printKeyword = \case
  { KeyIf    -> "if";     KeyElse   -> "else"
  ; KeyWhile -> "while";  KeyReturn -> "return"
  ; KeyTry   -> "try";    KeyCatch  -> "catch"
  ; KeyClass -> "class";  KeyVoid   -> "void"
  }

-- Concrete syntax of C# punctuation
printPunctuation :: Punctuation -> String
printPunctuation = \case
  { POpen     -> "("; PClose    -> ")"
  ; SOpen     -> "["; SClose    -> "]"
  ; COpen     -> "{"; CClose    -> "}"
  ; Comma     -> ","; Semicolon -> ";"
  }

-- Concrete syntax of C# booleans
printBool :: Bool -> String
printBool = \case
  {True -> "true"; False -> "false"}

---- End Pretty-printing functions for C# syntax ----

---- Begin Concrete syntax that is discarded during AST construction ----

data Keyword
  = KeyIf    | KeyElse
  | KeyWhile | KeyReturn
  | KeyTry   | KeyCatch
  | KeyClass | KeyVoid
  deriving (Eq, Show, Ord, Enum, Bounded)

data Punctuation
  = POpen    | PClose      -- parentheses     ()
  | SOpen    | SClose      -- square brackets []
  | COpen    | CClose      -- curly braces    {}
  | Comma    | Semicolon
  deriving (Eq, Show, Ord, Enum, Bounded)

---- End Concrete syntax that is discarded during AST construction ----

----- Begin Lexer -----

data Token  -- What the lexer returns
  = Punctuation Punctuation
  | Keyword     Keyword
  | Type        Type      -- the types that variables can have
  | Operator    Operator  -- the binary operators
  | UpperId     Ident     -- uppercase identifiers
  | LowerId     Ident     -- lowercase identifiers
  | BoolLit     Bool
  | IntLit      Int
  deriving (Eq, Show, Ord)

-- Entry point for the lexer
lexicalScanner :: Parser Char [Token]
lexicalScanner = lexWhiteSpace *> greedy (lexToken <* lexWhiteSpace) <* eof

lexToken :: Parser Char Token
lexToken = greedyChoice
  [ Keyword     <$> lexEnum printKeyword
  , Punctuation <$> lexEnum printPunctuation
  , Type        <$> lexEnum printType
  , Operator    <$> lexEnum printOperator
  , BoolLit     <$> lexEnum printBool
  , IntLit      <$> lexInt
  , lexLowerId
  , lexUpperId
  ]

-- Helper function that can lex values of any data type
--  that is `Bounded`, an `Enum`, and has a `print` function
lexEnum :: (Bounded a, Enum a, Eq s) =>  (a -> [s]) -> Parser s a
lexEnum print = choice $ map (\a -> a <$ token (print a)) [minBound..maxBound]

lexInt :: Parser Char Int
lexInt = read <$> greedy1 (satisfy isDigit)

lexLowerId,lexUpperId :: Parser Char Token
lexLowerId = (\x xs -> LowerId (x:xs)) <$> satisfy isLower <*> lexIdent
lexUpperId = (\x xs -> UpperId (x:xs)) <$> satisfy isUpper <*> lexIdent

lexIdent :: Parser Char Ident
lexIdent = greedy (satisfy isAlphaNum)

lexWhiteSpace :: Parser Char String
lexWhiteSpace = greedy (satisfy isSpace <|> isComment)

isComment :: Parser Char Char
isComment = satisfy (== '/') *> satisfy (== '/') *> greedy (satisfy (/= '\n')) *> pure ' '

greedyChoice :: [Parser s a] -> Parser s a
greedyChoice = foldr (<<|>) empty

----- End Lexer -----

----- Begin Lexer-Parser glue -----

keyword :: Keyword -> Parser Token ()
keyword k = () <$ satisfy (== Keyword k)

punctuation :: Punctuation -> Parser Token ()
punctuation p = () <$ satisfy (== Punctuation p)

sSemi :: Parser Token ()
sSemi = punctuation Semicolon

sIntLit :: Parser Token Int
sIntLit = anySymbol >>= \case
  IntLit x -> pure x
  _ -> failp

sBoolLit :: Parser Token Bool
sBoolLit = anySymbol >>= \case
  BoolLit x -> pure x
  _ -> failp

sType :: Parser Token Type
sType = anySymbol >>= \case
  Type x -> pure x
  _ -> failp

sUpperId, sLowerId :: Parser Token Ident
sUpperId = anySymbol >>= \case
  UpperId x -> pure x
  _ -> failp
sLowerId = anySymbol >>= \case
  LowerId x -> pure x
  _ -> failp

sOperator :: Parser Token Operator
sOperator = anySymbol >>= \case
  Operator x -> pure x
  _ -> failp

----- End Lexer-Parser glue -----

----- Begin Parser ----

-- Entry point to the parser
pClass :: Parser Token Class
pClass = Class <$ keyword KeyClass <*> sUpperId <*> braced (many pMember)

pMember :: Parser Token Member
pMember =  MemberD <$> pDeclSemi
       <|> MemberM <$> pRetType <*> sLowerId <*> methArgList <*> pBlock
    where
  methArgList = parenthesised (option (listOf pDecl (punctuation Comma)) [])

pBlock :: Parser Token Stat
pBlock = StatBlock <$> braced (many pStatDecl)

pStatDecl :: Parser Token Stat
pStatDecl =  pStat
         <|> StatDecl <$> pDeclSemi

pStat :: Parser Token Stat
pStat =  StatExpr <$> pExpr <*  sSemi
     <|> StatIf     <$ keyword KeyIf     <*> parenthesised pExpr <*> pStat <*> optionalElse
     <|> StatWhile  <$ keyword KeyWhile  <*> parenthesised pExpr <*> pStat
     <|> StatReturn <$ keyword KeyReturn <*> pExpr               <*  sSemi
     <|> pBlock
     where optionalElse = option (keyword KeyElse *> pStat) (StatBlock [])

pLiteral :: Parser Token Literal
pLiteral =  LitBool <$> sBoolLit
        <|> LitInt  <$> sIntLit

pExprSimple :: Parser Token Expr
pExprSimple =  ExprLit  <$> pLiteral
           <|> ExprVar  <$> sLowerId
           <|> parenthesised pExpr

pExpr :: Parser Token Expr
pExpr = chainr pExprSimple (ExprOper <$> sOperator)

pDecl :: Parser Token Decl
pDecl = Decl <$> pRetType <*> sLowerId

pDeclSemi :: Parser Token Decl
pDeclSemi = pDecl <* sSemi

pType :: Parser Token Type
pType = sType

pRetType :: Parser Token RetType
pRetType = NV <$> pType
       <|> TyVoid <$ keyword KeyVoid

-- The `Token` equivalents to some parser combinators
parenthesised, bracketed, braced :: Parser Token b -> Parser Token b
parenthesised p = pack (punctuation POpen) p (punctuation PClose) --(p)
bracketed     p = pack (punctuation SOpen) p (punctuation SClose) --[p]
braced        p = pack (punctuation COpen) p (punctuation CClose) --{p}

--- End Parser ----
