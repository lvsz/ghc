--!!! instances with empty where parts: duplicate
--
module M where

data NUM = ONE | TWO
instance Num NUM
instance Num NUM
instance Eq NUM
instance Text NUM
