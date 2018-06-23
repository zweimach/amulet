module Parser.Token where

import Data.Text (unpack, Text)
import Data.Position
import Data.Spanned
import Data.Span

data TokenClass
  = TcArrow -- ^ A @->@ token.
  | TcEqual -- ^ A @=@ token.
  | TcForall -- ^ A @forall@ token.
  | TcImplies -- ^ A @=>@ token.
  | TcPipe -- ^ A @|@ token.
  | TcStar -- ^ A @*@ token.
  | TcTilde -- ^ A @~@ token.
  | TcUnderscore -- ^ A @_@ token.

  | TcLet -- ^ A @let@ token.
  | TcAnd -- ^ An @and@ token.
  | TcFun -- ^ A @fun@ token.
  | TcIf -- ^ An @if@ token.
  | TcThen -- ^ A @then@ token.
  | TcElse -- ^ An @else@ token.
  | TcBegin -- ^ A @begin@ token.
  | TcEnd -- ^ An @end@ token.
  | TcIn -- ^ An @in@ token.
  | TcExternal -- ^ An @external@ token.
  | TcVal -- ^ A @val@ token.
  | TcTrue -- ^ A @true@ token.
  | TcFalse -- ^ A @false@ token.
  | TcMatch -- ^ A @match@ token.
  | TcFunction -- ^ A @function@ token.
  | TcWith -- ^ A @with@ token.
  | TcType -- ^ A @type@ token.
  | TcOf -- ^ An @of@ token.
  | TcModule -- ^ A @module@ token.
  | TcOpen -- ^ An @open@ token.
  | TcLazy

  | TcDot -- ^ A @.@ token.
  | TcComma -- ^ A @,@ token.
  | TcColon -- ^ A @:@ token.
  | TcSemicolon -- ^ A @;@ token.
  | TcTopSep -- ^ A @;;@ token.
  | TcOParen -- ^ A @(@ token.
  | TcCParen -- ^ A @)@ token.
  | TcAtBrace -- ^ A @@{@ token.
  | TcQuestion -- ^ A @?@ token.
  | TcOBrace -- ^ A @{@ token.
  | TcCBrace -- ^ A @}@ token.
  | TcOSquare -- ^ A @[@ token.
  | TcCSquare -- ^ A @]@ token.

  | TcOp Text                     -- ^ Operators (@+@)
  | TcIdentifier Text             -- ^ Identifiers (@foo@)
  | TcOpIdent Text                -- ^ Backtick ops (@`foo`@)
  | TcConIdent Text               -- ^ Constructors (@Foo@)
  | TcIdentifierQual [Text] Text  -- ^ Qualified identifiers (@Foo.bar@)
  | TcOpIdentQual [Text] Text     -- ^ Qualified backtick ops (@`Foo.bar`@)
  | TcConIdentQual [Text] Text    -- ^ Qualified constructors (@Foo.Bar@)
  | TcDotQual [Text]              -- ^ Qualified module, used for "let open ..." (@Foo.@)
  | TcTyvar Text                  -- ^ Type variable (@'foo@)
  | TcAccess Text                 -- ^ Record access (@.foo@)
  | TcHole Text                   -- ^ Hole (@_foo@)

  | TcInteger Integer -- ^ Integer literal
  | TcFloat Double -- ^ Floating-point literal
  | TcString Text -- ^ String literal

  -- "Virtual" tokens. It might be possible merge "end" and "in", but
  -- this allows for easier inspection
  | TcVBegin -- ^ Virtual @begin@ token, @$begin@.
  | TcVEnd   -- ^ Virtual @end@ token, @$end@.
  | TcVSep   -- ^ Virtual @;;@ token, @$sep@.
  | TcVIn    -- ^ Virtual @in@ token, @$in@.

  | TcEOF -- ^ End of file
  deriving Eq

instance Show TokenClass where
  show TcArrow = "->"
  show TcEqual = "="
  show TcForall = "forall"
  show TcImplies = "=>"
  show TcPipe = "|"
  show TcStar = "*"
  show TcTilde = "~"
  show TcUnderscore = "_"

  show TcLet = "let"
  show TcFun = "fun"
  show TcAnd = "and"
  show TcIf = "if"
  show TcThen = "then"
  show TcElse = "else"
  show TcBegin = "begin"
  show TcEnd = "end"
  show TcIn = "in"
  show TcExternal = "external"
  show TcVal = "val"
  show TcTrue = "true"
  show TcFalse = "false"
  show TcMatch = "match"
  show TcWith = "with"
  show TcFunction = "function"
  show TcType = "type"
  show TcOf = "of"
  show TcModule = "module"
  show TcOpen = "open"
  show TcLazy = "lazy"

  show TcComma = ","
  show TcDot = "."
  show TcColon = ":"
  show TcSemicolon = ";"
  show TcTopSep = ";;"
  show TcOParen = "("
  show TcCParen = ")"
  show TcAtBrace = "@{"
  show TcQuestion = "?"
  show TcOBrace = "{"
  show TcCBrace = "}"
  show TcOSquare = "["
  show TcCSquare = "]"

  show (TcOp t) = unpack t
  show (TcIdentifier t) = unpack t
  show (TcOpIdent t) = "`" ++ unpack t ++ "`"
  show (TcConIdent t) = unpack t
  show (TcIdentifierQual ms t) = concatMap (\m -> unpack m ++ ['.']) (reverse ms) ++ unpack t
  show (TcConIdentQual ms t) = concatMap (\m -> unpack m ++ ['.']) (reverse ms) ++ unpack t
  show (TcOpIdentQual ms t) = "`" ++ concatMap (\m -> unpack m ++ ['.']) (reverse ms) ++ unpack t ++ "`"
  show (TcDotQual ms) = concatMap (\m -> unpack m ++ ['.']) ms
  show (TcTyvar t) = '\'':unpack t
  show (TcAccess t) = '.':unpack t
  show (TcHole t) = '_':unpack t
  show (TcString t) = show (unpack t)
  show (TcInteger i) = show i
  show (TcFloat i) = show i

  show TcVBegin = "$begin"
  show TcVEnd = "$end"
  show TcVSep = "$sep"
  show TcVIn = "$in"

  show TcEOF = "<eof>"

-- | A token, with its class, start, and end position.
data Token = Token !TokenClass !SourcePos !SourcePos deriving Show

instance Spanned Token where
  annotation (Token _ s e) = mkSpanUnsafe s e

-- | Determine the friendly name of virtual token
friendlyName :: TokenClass -> String
friendlyName TcVEnd = "end of block"
friendlyName TcVSep = "end of block"
friendlyName TcVIn = "end of block"
friendlyName TcVBegin = "start of block"
friendlyName x = show x
