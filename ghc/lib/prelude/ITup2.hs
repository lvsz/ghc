module PreludeBuiltin where

--- 2-tuples ------------------------------------------

import Cls
import Core
import IInt
import IInteger
import IList
import List	( (++), foldr )
import Prel	( (&&), (.) )
import PS	( _PackedString, _unpackPS )
import Text

instance (Eq a, Eq b) => Eq (a, b) where
    (a,b) == (c,d) = a == c && b == d

instance (Ord a, Ord b) => Ord (a, b) where
    a <  b  = case _tagCmp a b of { _LT -> True;  _EQ -> False; _GT -> False }
    a <= b  = case _tagCmp a b of { _LT -> True;  _EQ -> True;  _GT -> False }
    a >= b  = case _tagCmp a b of { _LT -> False; _EQ -> True;  _GT -> True  }
    a >  b  = case _tagCmp a b of { _LT -> False; _EQ -> False; _GT -> True  }
    max a b = case _tagCmp a b of { _LT -> b; _EQ -> a;  _GT -> a }
    min a b = case _tagCmp a b of { _LT -> a; _EQ -> a;  _GT -> b }
    _tagCmp (a1, b1) (a2, b2) = case (_tagCmp a1 a2) of
				    _LT -> _LT
				    _GT -> _GT
				    _EQ -> _tagCmp b1 b2

instance (Ix a, Ix b) => Ix (a, b) where
    range ((l1,l2),(u1,u2))
      = [ (i1,i2) | i1 <- range (l1,u1), i2 <- range (l2,u2) ]

    index ((l1,l2),(u1,u2)) (i1,i2)
      = index (l1,u1) i1 * (index (l2,u2) u2 + 1){-rangeSize (l2,u2)-} + index (l2,u2) i2

    inRange ((l1,l2),(u1,u2)) (i1,i2)
      = inRange (l1,u1) i1 && inRange (l2,u2) i2

instance (Text a, Text b) => Text (a, b) where
    readsPrec p = readParen False
    	    	    	    (\r -> [((x,y), w) | ("(",s) <- lex r,
						 (x,t)   <- reads s,
						 (",",u) <- lex t,
						 (y,v)   <- reads u,
						 (")",w) <- lex v ] )

    showsPrec p (x,y) = showChar '(' . shows x . showString ", " .
    	    	    	    	       shows y . showChar ')'

{-# SPECIALIZE instance Eq  	(Int, Int) #-}
{-# SPECIALIZE instance Ord 	(Int, Int) #-}
{-# SPECIALIZE instance Ix	(Int, Int) #-}
{-# SPECIALIZE instance Text	(Int, Int) #-}

{-# SPECIALIZE instance Text	(Integer, Integer) #-}

{-# SPECIALIZE instance Eq  	(_PackedString, _PackedString) #-}
{-# SPECIALIZE instance Ord 	(_PackedString, _PackedString) #-}

#if defined(__UNBOXED_INSTANCES__)
-- We generate SPECIALIZED instances for all combinations of unboxed pairs

{-# GENERATE_SPECS instance a b :: Eq (a,b) #-}
{-# GENERATE_SPECS instance a b :: Ord (a,b) #-}
{-# GENERATE_SPECS instance a{Char#,Int#} b{Char#,Int#} :: Ix (a,b) #-}
{-# GENERATE_SPECS instance a b :: Text (a,b) #-}

#endif {-UNBOXED INSTANCES-}
