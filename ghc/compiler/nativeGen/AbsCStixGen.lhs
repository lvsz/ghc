%
% (c) The AQUA Project, Glasgow University, 1993-1995
%

\begin{code}
#include "HsVersions.h"

module AbsCStixGen (
	genCodeAbstractC,

	-- and, of course, that's not enough...
	AbstractC, Target, StixTree, SplitUniqSupply, SUniqSM(..)
    ) where

import AbsCSyn
import AbsPrel		( PrimOp(..), primOpNeedsWrapper, isCompareOp
			  IF_ATTACK_PRAGMAS(COMMA tagOf_PrimOp)
			  IF_ATTACK_PRAGMAS(COMMA pprPrimOp)
			)
import CgCompInfo   	( mIN_UPD_SIZE )
import ClosureInfo	( infoTableLabelFromCI, entryLabelFromCI, fastLabelFromCI, 
			  closureUpdReqd
			)
import MachDesc	    
import Maybes	    	( Maybe(..), maybeToBool )
import Outputable     
import PrimKind	    	( isFloatingKind )
import SMRep	    	( SMRep(..), SMSpecRepKind(..), SMUpdateKind(..) )
import Stix	
import StixInfo	    	( genCodeInfoTable )
import SplitUniq
import Unique
import Util
\end{code}

For each independent chunk of AbstractC code, we generate a list of @StixTree@s,
where each tree corresponds to a single Stix instruction.  We leave the chunks
separated so that register allocation can be performed locally within the chunk.

\begin{code}

genCodeAbstractC 
    :: Target 
    -> AbstractC
    -> SUniqSM [[StixTree]]

genCodeAbstractC target absC = 
    mapSUs (genCodeTopAbsC target) (mkAbsCStmtList absC)	`thenSUs` \ trees ->
    returnSUs ([StComment SLIT("Native Code")] : trees)

\end{code}

Here we handle top-level things, like @CCodeBlock@s and
@CClosureInfoTable@s.

\begin{code}

genCodeTopAbsC 
    :: Target 
    -> AbstractC
    -> SUniqSM [StixTree]

genCodeTopAbsC target (CCodeBlock label absC) =
    genCodeAbsC target absC				`thenSUs` \ code ->
    returnSUs (StSegment TextSegment : StFunBegin label : code [StFunEnd label])

genCodeTopAbsC target stmt@(CStaticClosure label _ _ _) = 
    genCodeStaticClosure target stmt			`thenSUs` \ code ->
    returnSUs (StSegment DataSegment : StLabel label : code [])

genCodeTopAbsC target stmt@(CRetUnVector _ _) = returnSUs []

genCodeTopAbsC target stmt@(CFlatRetVector label _) =
    genCodeVecTbl target stmt				`thenSUs` \ code ->
    returnSUs (StSegment TextSegment : code [StLabel label])

genCodeTopAbsC target stmt@(CClosureInfoAndCode cl_info slow Nothing _ _)

  | slow_is_empty
  = genCodeInfoTable target stmt			`thenSUs` \ itbl ->
    returnSUs (StSegment TextSegment : itbl [])

  | otherwise
  = genCodeInfoTable target stmt			`thenSUs` \ itbl ->
    genCodeAbsC target slow				`thenSUs` \ slow_code ->
    returnSUs (StSegment TextSegment : itbl (StFunBegin slow_lbl : 
              slow_code [StFunEnd slow_lbl]))
  where
    slow_is_empty = not (maybeToBool (nonemptyAbsC slow))
    slow_lbl = entryLabelFromCI cl_info

genCodeTopAbsC target stmt@(CClosureInfoAndCode cl_info slow (Just fast) _ _) =
-- ToDo: what if this is empty? ------------------------^^^^
    genCodeInfoTable target stmt			`thenSUs` \ itbl ->
    genCodeAbsC target slow				`thenSUs` \ slow_code ->
    genCodeAbsC target fast				`thenSUs` \ fast_code ->
    returnSUs (StSegment TextSegment : itbl (StFunBegin slow_lbl : 
              slow_code (StFunEnd slow_lbl : StFunBegin fast_lbl :
              fast_code [StFunEnd fast_lbl])))
  where
    slow_lbl = entryLabelFromCI cl_info
    fast_lbl = fastLabelFromCI cl_info

genCodeTopAbsC target absC =
    genCodeAbsC target absC				`thenSUs` \ code ->
    returnSUs (StSegment TextSegment : code [])

\end{code}

Now the individual AbstractC statements.

\begin{code}

genCodeAbsC 
    :: Target 
    -> AbstractC
    -> SUniqSM StixTreeList

\end{code}

@AbsCNop@s just disappear.

\begin{code}

genCodeAbsC target AbsCNop = returnSUs id

\end{code}

OLD:@CComment@s are passed through as the corresponding @StComment@s.

\begin{code}

--UNUSED:genCodeAbsC target (CComment s) = returnSUs (\xs -> StComment s : xs)

\end{code}

Split markers are a NOP in this land.

\begin{code}

genCodeAbsC target CSplitMarker = returnSUs id

\end{code}

AbstractC instruction sequences are handled individually, and the
resulting StixTreeLists are joined together.

\begin{code}

genCodeAbsC target (AbsCStmts c1 c2) =
    genCodeAbsC target c1				`thenSUs` \ b1 ->
    genCodeAbsC target c2				`thenSUs` \ b2 ->
    returnSUs (b1 . b2)

\end{code}

Initialising closure headers in the heap...a fairly complex ordeal if
done properly.	For now, we just set the info pointer, but we should
really take a peek at the flags to determine whether or not there are
other things to be done (setting cost centres, age headers, global
addresses, etc.)

\begin{code}

genCodeAbsC target (CInitHdr cl_info reg_rel _ _) =
    let
	lhs = amodeToStix target (CVal reg_rel PtrKind)
    	lbl = infoTableLabelFromCI cl_info
    in
	returnSUs (\xs -> StAssign PtrKind lhs (StCLbl lbl) : xs)

\end{code}

Assignment, the curse of von Neumann, is the center of the code we
produce.  In most cases, the type of the assignment is determined
by the type of the destination.  However, when the destination can
have mixed types, the type of the assignment is ``StgWord'' (we use
PtrKind for lack of anything better).  Think:  do we also want a cast
of the source?  Be careful about floats/doubles.

\begin{code}

genCodeAbsC target (CAssign lhs rhs)
  | getAmodeKind lhs == VoidKind = returnSUs id
  | otherwise =
    let pk = getAmodeKind lhs
    	pk' = if mixedTypeLocn lhs && not (isFloatingKind pk) then IntKind else pk
    	lhs' = amodeToStix target lhs
    	rhs' = amodeToStix' target rhs
    in
        returnSUs (\xs -> StAssign pk' lhs' rhs' : xs)

\end{code}

Unconditional jumps, including the special ``enter closure'' operation.
Note that the new entry convention requires that we load the InfoPtr (R2)
with the address of the info table before jumping to the entry code for Node.

\begin{code}

genCodeAbsC target (CJump dest) =
    returnSUs (\xs -> StJump (amodeToStix target dest) : xs)

genCodeAbsC target (CFallThrough (CLbl lbl _)) =
    returnSUs (\xs -> StFallThrough lbl : xs)

genCodeAbsC target (CReturn dest DirectReturn) =
    returnSUs (\xs -> StJump (amodeToStix target dest) : xs)

genCodeAbsC target (CReturn table (StaticVectoredReturn n)) =
    returnSUs (\xs -> StJump dest : xs)
  where 
    dest = StInd PtrKind (StIndex PtrKind (amodeToStix target table)
    	    	    	    	    	  (StInt (toInteger (-n-1))))

genCodeAbsC target (CReturn table (DynamicVectoredReturn am)) =
    returnSUs (\xs -> StJump dest : xs)
  where 
    dest = StInd PtrKind (StIndex PtrKind (amodeToStix target table) dyn_off)
    dyn_off = StPrim IntSubOp [StPrim IntNegOp [amodeToStix target am], StInt 1]

\end{code}

Now the PrimOps, some of which may need caller-saves register wrappers.

\begin{code}

genCodeAbsC target (COpStmt results op args liveness_mask vols)
  -- ToDo (ADR?): use that liveness mask
  | primOpNeedsWrapper op =
    let
        saves = volatileSaves target vols
    	restores = volatileRestores target vols
    in
    	primToStix target (nonVoid results) op (nonVoid args)
    	    	    	    		    	      	`thenSUs` \ code ->
    	returnSUs (\xs -> saves ++ code (restores ++ xs))

  | otherwise = primToStix target (nonVoid results) op (nonVoid args)
    where
        nonVoid = filter ((/= VoidKind) . getAmodeKind)

\end{code}

Now the dreaded conditional jump.

Now the if statement.  Almost *all* flow of control are of this form.
@
	if (am==lit) { absC } else { absCdef }
@ 
	=>
@
	IF am = lit GOTO l1:
	absC 
	jump l2:
   l1:
	absCdef
   l2:
@

\begin{code}

genCodeAbsC target (CSwitch discrim alts deflt) 
  = case alts of
      [] -> genCodeAbsC target deflt

      [(tag,alt_code)] -> case maybe_empty_deflt of
				Nothing -> genCodeAbsC target alt_code
			        Just dc -> mkIfThenElse target discrim tag alt_code dc

      [(tag1@(MachInt i1 _), alt_code1),
       (tag2@(MachInt i2 _), alt_code2)] 
	| deflt_is_empty && i1 == 0 && i2 == 1
	-> mkIfThenElse target discrim tag1 alt_code1 alt_code2
	| deflt_is_empty && i1 == 1 && i2 == 0
	-> mkIfThenElse target discrim tag2 alt_code2 alt_code1
 
	-- If the @discrim@ is simple, then this unfolding is safe.
      other | simple_discrim -> mkSimpleSwitches target discrim alts deflt

	-- Otherwise, we need to do a bit of work.
      other ->  getSUnique		      	  `thenSUs` \ u ->
		genCodeAbsC target (AbsCStmts
	        (CAssign (CTemp u pk) discrim)
	        (CSwitch (CTemp u pk) alts deflt))

  where
    maybe_empty_deflt = nonemptyAbsC deflt
    deflt_is_empty = case maybe_empty_deflt of
			Nothing -> True
			Just _  -> False

    pk = getAmodeKind discrim

    simple_discrim = case discrim of
			CReg _    -> True
			CTemp _ _ -> True
			other	  -> False
\end{code}



Finally, all of the disgusting AbstractC macros.

\begin{code}

genCodeAbsC target (CMacroStmt macro args) = macroCode target macro args

genCodeAbsC target (CCallProfCtrMacro macro _) =
    returnSUs (\xs -> StComment macro : xs)

genCodeAbsC target (CCallProfCCMacro macro _) =
    returnSUs (\xs -> StComment macro : xs)

\end{code}

Here, we generate a jump table if there are more than four (integer) alternatives and
the jump table occupancy is greater than 50%.  Otherwise, we generate a binary
comparison tree.  (Perhaps this could be tuned.)

\begin{code}

intTag :: BasicLit -> Integer
intTag (MachChar c) = toInteger (ord c)
intTag (MachInt i _) = i
intTag _ = panic "intTag"

fltTag :: BasicLit -> Rational

fltTag (MachFloat f) = f
fltTag (MachDouble d) = d
fltTag _ = panic "fltTag"

mkSimpleSwitches 
    :: Target 
    -> CAddrMode -> [(BasicLit,AbstractC)] -> AbstractC
    -> SUniqSM StixTreeList

mkSimpleSwitches target am alts absC =
    getUniqLabelNCG 	    	    	    	    	`thenSUs` \ udlbl ->
    getUniqLabelNCG 	    	    	    	    	`thenSUs` \ ujlbl ->
    let am' = amodeToStix target am
    	joinedAlts = map (\ (tag,code) -> (tag, mkJoin code ujlbl)) alts
    	sortedAlts = naturalMergeSortLe leAlt joinedAlts
    	    	     -- naturalMergeSortLe, because we often get sorted alts to begin with

    	lowTag = intTag (fst (head sortedAlts))
    	highTag = intTag (fst (last sortedAlts))

    	-- lowest and highest possible values the discriminant could take
    	lowest = if floating then targetMinDouble else targetMinInt
    	highest = if floating then targetMaxDouble else targetMaxInt

    	-- These should come from somewhere else, depending on the target arch
    	-- (Note that the floating point values aren't terribly important.)
    	-- ToDo: Fix!(JSM)
    	targetMinDouble = MachDouble (-1.7976931348623157e+308)
    	targetMaxDouble = MachDouble (1.7976931348623157e+308)
    	targetMinInt = mkMachInt (-2147483647)
    	targetMaxInt = mkMachInt 2147483647
    in
    	(
    	if not floating && choices > 4 && highTag - lowTag < toInteger (2 * choices) then
    	    mkJumpTable target am' sortedAlts lowTag highTag udlbl
    	else
    	    mkBinaryTree target am' floating sortedAlts choices lowest highest udlbl
    	)
    	    	    	    	    	    	    	`thenSUs` \ alt_code ->
        genCodeAbsC target absC				`thenSUs` \ dflt_code ->

    	returnSUs (\xs -> alt_code (StLabel udlbl : dflt_code (StLabel ujlbl : xs)))

    where
    	floating = isFloatingKind (getAmodeKind am)
    	choices = length alts

    	(x@(MachChar _),_)  `leAlt` (y,_) = intTag x <= intTag y
    	(x@(MachInt _ _),_) `leAlt` (y,_) = intTag x <= intTag y
    	(x,_)               `leAlt` (y,_) = fltTag x <= fltTag y

\end{code}

We use jump tables when doing an integer switch on a relatively dense list of
alternatives.  We expect to be given a list of alternatives, sorted by tag,
and a range of values for which we are to generate a table.  Of course, the tags of 
the alternatives should lie within the indicated range.  The alternatives need
not cover the range; a default target is provided for the missing alternatives.

If a join is necessary after the switch, the alternatives should already finish
with a jump to the join point.

\begin{code}

mkJumpTable
    :: Target 
    -> StixTree  	    	-- discriminant
    -> [(BasicLit, AbstractC)] 	-- alternatives
    -> Integer 	    	    	-- low tag
    -> Integer 	    	    	-- high tag
    -> CLabel	    	    	-- default label
    -> SUniqSM StixTreeList

mkJumpTable target am alts lowTag highTag dflt =
    getUniqLabelNCG 	    	    	    	    	`thenSUs` \ utlbl ->
    mapSUs genLabel alts 	  	    	    	`thenSUs` \ branches ->
    let	cjmpLo = StCondJump dflt (StPrim IntLtOp [am, StInt lowTag])
    	cjmpHi = StCondJump dflt (StPrim IntGtOp [am, StInt highTag])

    	offset = StPrim IntSubOp [am, StInt lowTag]
    	jump = StJump (StInd PtrKind (StIndex PtrKind (StCLbl utlbl) offset))

    	tlbl = StLabel utlbl
    	table = StData PtrKind (mkTable branches [lowTag..highTag] [])
    in    
    	mapSUs mkBranch branches       	    	    	`thenSUs` \ alts ->

        returnSUs (\xs -> cjmpLo : cjmpHi : jump : 
                         StSegment DataSegment : tlbl : table : 
                         StSegment TextSegment : foldr1 (.) alts xs)

    where
    	genLabel x = getUniqLabelNCG `thenSUs` \ lbl -> returnSUs (lbl, x)

    	mkBranch (lbl,(_,alt)) =
            genCodeAbsC target alt  	    		`thenSUs` \ alt_code ->
    	    returnSUs (\xs -> StLabel lbl : alt_code xs)

    	mkTable _  []     tbl = reverse tbl
    	mkTable [] (x:xs) tbl = mkTable [] xs (StCLbl dflt : tbl)
    	mkTable alts@((lbl,(tag,_)):rest) (x:xs) tbl
    	  | intTag tag == x = mkTable rest xs (StCLbl lbl : tbl)
    	  | otherwise = mkTable alts xs (StCLbl dflt : tbl)

\end{code}

We generate binary comparison trees when a jump table is inappropriate.
We expect to be given a list of alternatives, sorted by tag, and for
convenience, the length of the alternative list.  We recursively break
the list in half and do a comparison on the first tag of the second half
of the list.  (Odd lists are broken so that the second half of the list
is longer.)  We can handle either integer or floating kind alternatives,
so long as they are not mixed.  (We assume that the type of the discriminant
determines the type of the alternatives.)

As with the jump table approach, if a join is necessary after the switch, the 
alternatives should already finish with a jump to the join point.

\begin{code}

mkBinaryTree 
    :: Target 
    -> StixTree  	    	-- discriminant
    -> Bool 	    	    	-- floating point?
    -> [(BasicLit, AbstractC)] 	-- alternatives
    -> Int  	    	    	-- number of choices
    -> BasicLit     	    	-- low tag
    -> BasicLit     	    	-- high tag
    -> CLabel	    	    	-- default code label
    -> SUniqSM StixTreeList

mkBinaryTree target am floating [(tag,alt)] _ lowTag highTag udlbl 
  | rangeOfOne = genCodeAbsC target alt
  | otherwise = 
    let	tag' = amodeToStix target (CLit tag)
    	cmpOp = if floating then DoubleNeOp else IntNeOp
    	test = StPrim cmpOp [am, tag']
    	cjmp = StCondJump udlbl test
    in
    	genCodeAbsC target alt 	    	    	    	`thenSUs` \ alt_code ->
        returnSUs (\xs -> cjmp : alt_code xs)

    where 
    	rangeOfOne = not floating && intTag lowTag + 1 >= intTag highTag
    	-- When there is only one possible tag left in range, we skip the comparison

mkBinaryTree target am floating alts choices lowTag highTag udlbl =
    getUniqLabelNCG					`thenSUs` \ uhlbl ->
    let tag' = amodeToStix target (CLit splitTag)
    	cmpOp = if floating then DoubleGeOp else IntGeOp
    	test = StPrim cmpOp [am, tag']
    	cjmp = StCondJump uhlbl test
    in
    	mkBinaryTree target am floating alts_lo half lowTag splitTag udlbl
    	    	    	    	    	    	  	`thenSUs` \ lo_code ->
    	mkBinaryTree target am floating alts_hi (choices - half) splitTag highTag udlbl
    	    	    	    	    		    	`thenSUs` \ hi_code ->

        returnSUs (\xs -> cjmp : lo_code (StLabel uhlbl : hi_code xs))

    where
    	half = choices `div` 2
    	(alts_lo, alts_hi) = splitAt half alts
    	splitTag = fst (head alts_hi)

\end{code}

\begin{code}

mkIfThenElse 
    :: Target 
    -> CAddrMode    	    -- discriminant
    -> BasicLit     	    -- tag
    -> AbstractC    	    -- if-part
    -> AbstractC    	    -- else-part
    -> SUniqSM StixTreeList

mkIfThenElse target discrim tag alt deflt =
    getUniqLabelNCG					`thenSUs` \ ujlbl ->
    getUniqLabelNCG					`thenSUs` \ utlbl ->
    let discrim' = amodeToStix target discrim
    	tag' = amodeToStix target (CLit tag)
    	cmpOp = if (isFloatingKind (getAmodeKind discrim)) then DoubleNeOp else IntNeOp
    	test = StPrim cmpOp [discrim', tag']
    	cjmp = StCondJump utlbl test
    	dest = StLabel utlbl
    	join = StLabel ujlbl
    in
        genCodeAbsC target (mkJoin alt ujlbl)		`thenSUs` \ alt_code ->
        genCodeAbsC target deflt			`thenSUs` \ dflt_code ->
        returnSUs (\xs -> cjmp : alt_code (dest : dflt_code (join : xs)))

mkJoin :: AbstractC -> CLabel -> AbstractC

mkJoin code lbl 
  | mightFallThrough code = mkAbsCStmts code (CJump (CLbl lbl PtrKind))
  | otherwise = code

\end{code}

%---------------------------------------------------------------------------

This answers the question: Can the code fall through to the next
line(s) of code?  This errs towards saying True if it can't choose,
because it is used for eliminating needless jumps.  In other words, if
you might possibly {\em not} jump, then say yes to falling through.

\begin{code}
mightFallThrough :: AbstractC -> Bool

mightFallThrough absC = ft absC True
 where
  ft AbsCNop	   if_empty = if_empty

  ft (CJump _)       if_empty = False
  ft (CReturn _ _)   if_empty = False
  ft (CSwitch _ alts deflt) if_empty 
	= ft deflt if_empty ||
	  or [ft alt if_empty | (_,alt) <- alts]

  ft (AbsCStmts c1 c2) if_empty = ft c2 (ft c1 if_empty)
  ft _ if_empty = if_empty

{- Old algorithm, which called nonemptyAbsC for every subexpression! =========
fallThroughAbsC (AbsCStmts c1 c2) =
    case nonemptyAbsC c2 of
	Nothing -> fallThroughAbsC c1
	Just x -> fallThroughAbsC x
fallThroughAbsC (CJump _)	 = False
fallThroughAbsC (CReturn _ _)	 = False
fallThroughAbsC (CSwitch _ choices deflt)
  = (not (isEmptyAbsC deflt) && fallThroughAbsC deflt)
    || or (map (fallThroughAbsC . snd) choices)
fallThroughAbsC other		 = True

isEmptyAbsC :: AbstractC -> Bool
isEmptyAbsC = not . maybeToBool . nonemptyAbsC
================= End of old, quadratic, algorithm -}
\end{code}

Vector tables are trivial!

\begin{code}

genCodeVecTbl 
    :: Target 
    -> AbstractC
    -> SUniqSM StixTreeList

genCodeVecTbl target (CFlatRetVector label amodes) =
    returnSUs (\xs -> vectbl : xs)
  where
    vectbl = StData PtrKind (reverse (map (amodeToStix target) amodes))

\end{code}

Static closures are not so hard either.

\begin{code}

genCodeStaticClosure 
    :: Target 
    -> AbstractC
    -> SUniqSM StixTreeList

genCodeStaticClosure target (CStaticClosure _ cl_info cost_centre amodes) =
    returnSUs (\xs -> table : xs)
  where
    table = StData PtrKind (StCLbl info_lbl : body)
    info_lbl = infoTableLabelFromCI cl_info

    body = if closureUpdReqd cl_info then 
    	    	take (max mIN_UPD_SIZE (length amodes')) (amodes' ++ zeros)
    	   else
    	    	amodes'

    zeros = StInt 0 : zeros

    amodes' = map amodeZeroVoid amodes

    	-- Watch out for VoidKinds...cf. PprAbsC
    amodeZeroVoid item 
      | getAmodeKind item == VoidKind = StInt 0
      | otherwise = amodeToStix target item

\end{code}

