%
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1995
%
%********************************************************
%*							*
\section[CgCase]{Converting @StgCase@ expressions}
%*							*
%********************************************************

\begin{code}
#include "HsVersions.h"

module CgCase (
	cgCase,
    	saveVolatileVarsAndRegs,

	-- and to make the interface self-sufficient...
	StgExpr, Id, StgCaseAlternatives, CgState
    ) where

IMPORT_Trace		-- ToDo: rm (debugging)
import Outputable
import Pretty

import StgSyn
import CgMonad
import AbsCSyn

import AbsPrel		( PrimOp(..), primOpCanTriggerGC
			  IF_ATTACK_PRAGMAS(COMMA tagOf_PrimOp)
			  IF_ATTACK_PRAGMAS(COMMA pprPrimOp)
			)
import AbsUniType	( kindFromType, getTyConDataCons,
			  getUniDataSpecTyCon, getUniDataSpecTyCon_maybe,
			  isEnumerationTyCon,
			  UniType
			)
import CgBindery	-- all of it
import CgCon		( buildDynCon, bindConArgs )
import CgExpr		( cgExpr, getPrimOpArgAmodes )
import CgHeapery	( heapCheck )
import CgRetConv	-- lots of stuff
import CgStackery	-- plenty
import CgTailCall	( tailCallBusiness, performReturn )
import CgUsages		-- and even more
import CLabelInfo	-- bunches of things...
import ClosureInfo	{-( blackHoleClosureInfo, mkConLFInfo, mkLFArgument,
			  layOutDynCon
			)-}
import CmdLineOpts	( GlobalSwitch(..) )
import CostCentre	( useCurrentCostCentre, CostCentre )
import BasicLit		( kindOfBasicLit )
import Id		( getDataConTag, getIdKind, fIRST_TAG, isDataCon,
			  toplevelishId, getInstantiatedDataConSig,
			  ConTag(..), DataCon(..)
			)
import Maybes		( catMaybes, Maybe(..) )
import PrimKind		( getKindSize, isFollowableKind, retKindSize, PrimKind(..) )
import UniqSet		-- ( uniqSetToList, UniqSet(..) )
import Util
\end{code}

\begin{code}
data GCFlag
  = GCMayHappen	-- The scrutinee may involve GC, so everything must be
		-- tidy before the code for the scrutinee.

  | NoGC	-- The scrutinee is a primitive value, or a call to a
		-- primitive op which does no GC.  Hence the case can
		-- be done inline, without tidying up first.
\end{code}

It is quite interesting to decide whether to put a heap-check
at the start of each alternative.  Of course we certainly have
to do so if the case forces an evaluation, or if there is a primitive
op which can trigger GC.  

A more interesting situation is this:

\begin{verbatim}
	!A!;
	...A...
	case x# of
	  0#      -> !B!; ...B...
	  default -> !C!; ...C...
\end{verbatim}

where \tr{!x!} indicates a possible heap-check point. The heap checks
in the alternatives {\em can} be omitted, in which case the topmost
heapcheck will take their worst case into account.

In favour of omitting \tr{!B!}, \tr{!C!}:

\begin{itemize}
\item
{\em May} save a heap overflow test, 
	if ...A... allocates anything.  The other advantage
	of this is that we can use relative addressing
	from a single Hp to get at all the closures so allocated.
\item
 No need to save volatile vars etc across the case
\end{itemize}

Against:
	
\begin{itemize}
\item
   May do more allocation than reqd.  This sometimes bites us
	badly.  For example, nfib (ha!)  allocates about 30\% more space if the
	worst-casing is done, because many many calls to nfib are leaf calls
	which don't need to allocate anything.

	This never hurts us if there is only one alternative.
\end{itemize}


*** NOT YET DONE ***  The difficulty is that \tr{!B!}, \tr{!C!} need
to take account of what is live, and that includes all live volatile
variables, even if they also have stable analogues.  Furthermore, the
stack pointers must be lined up properly so that GC sees tidy stacks.
If these things are done, then the heap checks can be done at \tr{!B!} and
\tr{!C!} without a full save-volatile-vars sequence.

\begin{code}
cgCase	:: PlainStgExpr
	-> PlainStgLiveVars
	-> PlainStgLiveVars
	-> Unique
	-> PlainStgCaseAlternatives
	-> Code
\end{code}

Several special cases for primitive operations.

******* TO DO TO DO: fix what follows

Special case for

	case (op x1 ... xn) of
	  y -> e

where the type of the case scrutinee is a multi-constuctor algebraic type.
Then we simply compile code for

	let y = op x1 ... xn
	in
	e

In this case:

	case (op x1 ... xn) of
	   C a b -> ...
	   y     -> e

where the type of the case scrutinee is a multi-constuctor algebraic type.
we just bomb out at the moment. It never happens in practice.

**** END OF TO DO TO DO

\begin{code}
cgCase scrut@(StgPrimApp op args _) live_in_whole_case live_in_alts uniq 
       (StgAlgAlts _ alts (StgBindDefault id _ deflt_rhs))
  = if not (null alts) then
    	panic "cgCase: case on PrimOp with default *and* alts\n"
	-- For now, die if alts are non-empty
    else
#if 0
	pprTrace "cgCase:prim app returning alg data type: bad code!" (ppr PprDebug scrut) $
	-- See above TO DO TO DO
#endif
	cgExpr (StgLet (StgNonRec id scrut_rhs) deflt_rhs)
  where
    scrut_rhs       = StgRhsClosure useCurrentCostCentre stgArgOcc{-safe-} scrut_free_vars
				Updatable [] scrut
    scrut_free_vars = [ fv | StgVarAtom fv <- args, not (toplevelishId fv) ]
			-- Hack, hack
\end{code}


\begin{code}
cgCase (StgPrimApp op args _) live_in_whole_case live_in_alts uniq alts
  | not (primOpCanTriggerGC op)
  =
	-- Get amodes for the arguments and results
    getPrimOpArgAmodes op args			`thenFC` \ arg_amodes -> 
    let
	result_amodes = getPrimAppResultAmodes uniq alts
	liveness_mask = panic "cgCase: liveness of non-GC-ing primop touched\n"
    in
	-- Perform the operation
    getVolatileRegs live_in_alts		        `thenFC` \ vol_regs ->

    profCtrC SLIT("SET_ACTIVITY") [CLitLit SLIT("ACT_PRIM") IntKind]  `thenC`

    absC (COpStmt result_amodes op
		 arg_amodes -- note: no liveness arg
		 liveness_mask vol_regs) 		`thenC`

    profCtrC SLIT("SET_ACTIVITY") [CLitLit SLIT("ACT_PRIM_STOP") IntKind]  `thenC`

	-- Scrutinise the result
    cgInlineAlts NoGC uniq alts

  | otherwise	-- *Can* trigger GC
  = getPrimOpArgAmodes op args		`thenFC` \ arg_amodes ->

   	-- Get amodes for the arguments and results, and assign to regs
	-- (Can-trigger-gc primops guarantee to have their (nonRobust)
	--  args in regs)
    let
	op_result_regs = assignPrimOpResultRegs op

    	op_result_amodes = map CReg op_result_regs

	(op_arg_amodes, liveness_mask, arg_assts) 
	  = makePrimOpArgsRobust op arg_amodes

	liveness_arg  = mkIntCLit liveness_mask
    in
	-- Tidy up in case GC happens...

	-- Nota Bene the use of live_in_whole_case in nukeDeadBindings.
	-- Reason: the arg_assts computed above may refer to some stack slots
	-- which are not live in the alts.  So we mustn't use those slots
	-- to save volatile vars in!
    nukeDeadBindings live_in_whole_case	`thenC`
    saveVolatileVars live_in_alts	`thenFC` \ volatile_var_save_assts ->

    getEndOfBlockInfo                 	`thenFC` \ eob_info ->
    forkEval eob_info nopC 
	     (getAbsC (cgInlineAlts GCMayHappen uniq alts) `thenFC` \ abs_c ->
              absC (CRetUnVector vtbl_label (CLabelledCode return_label abs_c))
    	    	    	    	    	`thenC`
	      returnFC (CaseAlts (CUnVecLbl return_label vtbl_label) 
                                 Nothing{-no semi-tagging-}))
	    `thenFC` \ new_eob_info ->

	-- Record the continuation info
    setEndOfBlockInfo new_eob_info (

	-- Now "return" to the inline alternatives; this will get 
	-- compiled to a fall-through.
    let
	simultaneous_assts = arg_assts `mkAbsCStmts` volatile_var_save_assts
	
	-- do_op_and_continue will be passed an amode for the continuation
	do_op_and_continue sequel
          = profCtrC SLIT("SET_ACTIVITY") [CLitLit SLIT("ACT_PRIM") IntKind]  `thenC`

	    absC (COpStmt op_result_amodes
			  op
			  (pin_liveness op liveness_arg op_arg_amodes)
			  liveness_mask
			  [{-no vol_regs-}])
    	    	    	    	    	`thenC`

	    profCtrC SLIT("SET_ACTIVITY") [CLitLit SLIT("ACT_PRIM_STOP") IntKind]  `thenC`

            sequelToAmode sequel        `thenFC` \ dest_amode ->
            absC (CReturn dest_amode DirectReturn)

		-- Note: we CJump even for algebraic data types,
		-- because cgInlineAlts always generates code, never a
		-- vector.
    in
    performReturn simultaneous_assts do_op_and_continue live_in_alts
    )
  where
    -- for all PrimOps except ccalls, we pin the liveness info
    -- on as the first "argument"
    -- ToDo: un-duplicate?

    pin_liveness (CCallOp _ _ _ _ _) _ args = args
    pin_liveness other_op liveness_arg args
      = liveness_arg :args

    vtbl_label = mkVecTblLabel uniq
    return_label = mkReturnPtLabel uniq

\end{code}

Another special case: scrutinising a primitive-typed variable.	No
evaluation required.  We don't save volatile variables, nor do we do a
heap-check in the alternatives.	 Instead, the heap usage of the
alternatives is worst-cased and passed upstream.  This can result in
allocating more heap than strictly necessary, but it will sometimes
eliminate a heap check altogether.

\begin{code}
cgCase (StgApp v [] _) live_in_whole_case live_in_alts uniq (StgPrimAlts ty alts deflt)
  = getAtomAmode v		`thenFC` \ amode ->
    cgPrimAltsGivenScrutinee NoGC amode alts deflt
\end{code}

Special case: scrutinising a non-primitive variable.
This can be done a little better than the general case, because
we can reuse/trim the stack slot holding the variable (if it is in one).

\begin{code}
cgCase (StgApp (StgVarAtom fun) args _ {-lvs must be same as live_in_alts-}) 
        live_in_whole_case live_in_alts uniq alts@(StgAlgAlts _ _ _)
  =
    getCAddrModeAndInfo fun		`thenFC` \ (fun_amode, lf_info) ->
    getAtomAmodes args			`thenFC` \ arg_amodes ->

	-- Squish the environment
    nukeDeadBindings live_in_alts	`thenC`
    saveVolatileVarsAndRegs live_in_alts 
    	    	    	`thenFC` \ (save_assts, alts_eob_info, maybe_cc_slot) ->

    forkEval alts_eob_info
    	     nopC (cgEvalAlts maybe_cc_slot uniq alts) `thenFC` \ scrut_eob_info ->
    setEndOfBlockInfo scrut_eob_info  (
      tailCallBusiness fun fun_amode lf_info arg_amodes live_in_alts save_assts
    )

\end{code}

Finally, here is the general case.

\begin{code}
cgCase expr live_in_whole_case live_in_alts uniq alts
  =	-- Figure out what volatile variables to save
    nukeDeadBindings live_in_whole_case	`thenC`
    saveVolatileVarsAndRegs live_in_alts
    	    	    	`thenFC` \ (save_assts, alts_eob_info, maybe_cc_slot) ->

	-- Save those variables right now!	
    absC save_assts 	    	    	`thenC`

    forkEval alts_eob_info 
    	(nukeDeadBindings live_in_alts)
	(cgEvalAlts maybe_cc_slot uniq alts) `thenFC` \ scrut_eob_info ->

    setEndOfBlockInfo scrut_eob_info (cgExpr expr)
\end{code}

%************************************************************************
%*									*
\subsection[CgCase-primops]{Primitive applications}
%*									*
%************************************************************************

Get result amodes for a primitive operation, in the case wher GC can't happen.
The  amodes are returned in canonical order, ready for the prim-op!

	Alg case: temporaries named as in the alternatives,
		  plus (CTemp u) for the tag (if needed)
	Prim case: (CTemp u)

This is all disgusting, because these amodes must be consistent with those
invented by CgAlgAlts.

\begin{code}
getPrimAppResultAmodes
	:: Unique
	-> PlainStgCaseAlternatives
	-> [CAddrMode]
\end{code}

\begin{code}
-- If there's an StgBindDefault which does use the bound
-- variable, then we can only handle it if the type involved is
-- an enumeration type.   That's important in the case
-- of comparisions:
--
--	case x ># y of
--	  r -> f r
--
-- The only reason for the restriction to *enumeration* types is our
-- inability to invent suitable temporaries to hold the results;
-- Elaborating the CTemp addr mode to have a second uniq field
-- (which would simply count from 1) would solve the problem.
-- Anyway, cgInlineAlts is now capable of handling all cases;
-- it's only this function which is being wimpish.

getPrimAppResultAmodes uniq (StgAlgAlts ty alts (StgBindDefault _ True {- used -} _))
  | isEnumerationTyCon spec_tycon = [tag_amode]
  | otherwise		          = panic "getPrimAppResultAmodes: non-enumeration algebraic alternatives with default"
  where
    -- A temporary variable to hold the tag; this is unaffected by GC because
    -- the heap-checks in the branches occur after the switch
    tag_amode     = CTemp uniq IntKind
    (spec_tycon, _, _) = getUniDataSpecTyCon ty

getPrimAppResultAmodes uniq (StgAlgAlts ty alts other_default)
	-- Default is either StgNoDefault or StgBindDefault with unused binder
  = case alts of
	[_]	-> arg_amodes			-- No need for a tag
	other	-> tag_amode : arg_amodes
  where
    -- A temporary variable to hold the tag; this is unaffected by GC because
    -- the heap-checks in the branches occur after the switch
    tag_amode = CTemp uniq IntKind

    -- Sort alternatives into canonical order; there must be a complete
    -- set because there's no default case.
    sorted_alts = sortLt lt alts
    (con1,_,_,_) `lt` (con2,_,_,_) = getDataConTag con1 < getDataConTag con2

    arg_amodes :: [CAddrMode]

    -- Turn them into amodes
    arg_amodes = concat (map mk_amodes sorted_alts)
    mk_amodes (con, args, use_mask, rhs)
      = [ CTemp (getTheUnique arg) (getIdKind arg) | arg <- args ]
\end{code}

The situation is simpler for primitive
results, because there is only one!

\begin{code}
getPrimAppResultAmodes uniq (StgPrimAlts ty _ _)
  = [CTemp uniq kind]
  where
    kind = kindFromType ty
\end{code}


%************************************************************************
%*									*
\subsection[CgCase-alts]{Alternatives}
%*									*
%************************************************************************

@cgEvalAlts@ returns an addressing mode for a continuation for the
alternatives of a @case@, used in a context when there
is some evaluation to be done.

\begin{code}
cgEvalAlts :: Maybe VirtualSpBOffset	-- Offset of cost-centre to be restored, if any
	   -> Unique
	   -> PlainStgCaseAlternatives
	   -> FCode Sequel		-- Any addr modes inside are guaranteed to be a label
					-- so that we can duplicate it without risk of
					-- duplicating code

cgEvalAlts cc_slot uniq (StgAlgAlts ty alts deflt)
  = 	-- Generate the instruction to restore cost centre, if any
    restoreCurrentCostCentre cc_slot 	`thenFC` \ cc_restore ->

	-- Generate sequel info for use downstream
	-- At the moment, we only do it if the type is vector-returnable.
	-- Reason: if not, then it costs extra to label the
	-- alternatives, because we'd get return code like:
	--
	--	switch TagReg { 0 : JMP(alt_1); 1 : JMP(alt_2) ..etc }
	--
	-- which is worse than having the alt code in the switch statement

    let
	(spec_tycon, _, _) = getUniDataSpecTyCon ty

	use_labelled_alts 
	  = case ctrlReturnConvAlg spec_tycon of
	      VectoredReturn _ -> True
	      _	    	       -> False

	semi_tagged_stuff
    	  = if not use_labelled_alts then
		Nothing -- no semi-tagging info
	    else
		cgSemiTaggedAlts uniq alts deflt -- Just <something>
    in
    cgAlgAlts GCMayHappen uniq cc_restore use_labelled_alts ty alts deflt
					`thenFC` \ (tagged_alt_absCs, deflt_absC) ->

    mkReturnVector uniq ty tagged_alt_absCs deflt_absC `thenFC` \ return_vec ->

    returnFC (CaseAlts return_vec semi_tagged_stuff)

cgEvalAlts cc_slot uniq (StgPrimAlts ty alts deflt)
  =	-- Generate the instruction to restore cost centre, if any
    restoreCurrentCostCentre cc_slot 			 `thenFC` \ cc_restore ->

	-- Generate the switch
    getAbsC (cgPrimAlts GCMayHappen uniq ty alts deflt)  `thenFC` \ abs_c ->

	-- Generate the labelled block, starting with restore-cost-centre
    absC (CRetUnVector vtbl_label 
         (CLabelledCode return_label (cc_restore `mkAbsCStmts` abs_c)))
    	    	    	    	    	    	    	 `thenC`
	-- Return an amode for the block
    returnFC (CaseAlts (CUnVecLbl return_label vtbl_label) Nothing{-no semi-tagging-})
  where
    vtbl_label = mkVecTblLabel uniq
    return_label = mkReturnPtLabel uniq
\end{code}


\begin{code}
cgInlineAlts :: GCFlag -> Unique
    	     -> PlainStgCaseAlternatives
    	     -> Code
\end{code}

First case: algebraic case, exactly one alternative, no default.
In this case the primitive op will not have set a temporary to the
tag, so we shouldn't generate a switch statment.  Instead we just
do the right thing.

\begin{code}
cgInlineAlts gc_flag uniq (StgAlgAlts ty [alt@(con,args,use_mask,rhs)] StgNoDefault)
  = cgAlgAltRhs gc_flag con args use_mask rhs
\end{code}

Second case: algebraic case, several alternatives.
Tag is held in a temporary.

\begin{code}
cgInlineAlts gc_flag uniq (StgAlgAlts ty alts deflt)
  = cgAlgAlts gc_flag uniq AbsCNop{-restore_cc-} False{-no semi-tagging-}
		ty alts deflt	`thenFC` \ (tagged_alts, deflt_c) ->

	-- Do the switch
    absC (mkAlgAltsCSwitch tag_amode tagged_alts deflt_c)
 where
    -- A temporary variable to hold the tag; this is unaffected by GC because
    -- the heap-checks in the branches occur after the switch
    tag_amode = CTemp uniq IntKind
\end{code}

=========== OLD: we *can* now handle this case ================

Next, a case we can't deal with: an algebraic case with no evaluation
required (so it is in-line), and a default case as well.  In this case
we require all the alternatives written out, so that we can invent
suitable binders to pass to the PrimOp. A default case defeats this.
Could be fixed, but probably isn't worth it.

\begin{code}
{- ============= OLD
cgInlineAlts gc_flag uniq (StgAlgAlts ty alts other_default)
  = panic "cgInlineAlts: alg alts with default"
================= END OF OLD -}
\end{code}

Third (real) case: primitive result type.

\begin{code}
cgInlineAlts gc_flag uniq (StgPrimAlts ty alts deflt)
  = cgPrimAlts gc_flag uniq ty alts deflt
\end{code}


%************************************************************************
%*									*
\subsection[CgCase-alg-alts]{Algebraic alternatives}
%*									*
%************************************************************************

In @cgAlgAlts@, none of the binders in the alternatives are
assumed to be yet bound.

\begin{code}
cgAlgAlts :: GCFlag
	  -> Unique
	  -> AbstractC				-- Restore-cost-centre instruction
	  -> Bool				-- True <=> branches must be labelled
	  -> UniType	    	    	    	-- From the case statement
	  -> [(Id, [Id], [Bool], PlainStgExpr)]	-- The alternatives
	  -> PlainStgCaseDefault		-- The default
	  -> FCode ([(ConTag, AbstractC)],	-- The branches
		    AbstractC			-- The default case
	     )
\end{code}

The case with a default which has a binder is different.  We need to
pick all the constructors which aren't handled explicitly by an
alternative, and which return their results in registers, allocate
them explicitly in the heap, and jump to a join point for the default
case.

OLD:  All of this only works if a heap-check is required anyway, because
otherwise it isn't safe to allocate. 

NEW (July 94): now false!  It should work regardless of gc_flag,
because of the extra_branches argument now added to forkAlts.

We put a heap-check at the join point, for the benefit of constructors
which don't need to do allocation. This means that ones which do need
to allocate may end up doing two heap-checks; but that's just too bad.
(We'd need two join labels otherwise.  ToDo.)

It's all pretty turgid anyway.

\begin{code}
cgAlgAlts gc_flag uniq restore_cc semi_tagging
	ty alts deflt@(StgBindDefault binder True{-used-} _)
  = forkAlts (map (cgAlgAlt gc_flag uniq restore_cc semi_tagging) alts)
	     extra_branches
	     (cgAlgDefault  gc_flag uniq restore_cc must_label_default deflt)
  where
    extra_branches :: [FCode (ConTag, AbstractC)]
    extra_branches = catMaybes (map mk_extra_branch default_cons)

    must_label_default = semi_tagging || not (null extra_branches)

    default_join_lbl = mkDefaultLabel uniq
    jump_instruction = CJump (CLbl default_join_lbl CodePtrKind)

    (spec_tycon, _, spec_cons)
      = -- trace ("cgCase:tycon:"++(ppShow 80 (ppAboves [
	--	ppr PprDebug uniq,
	--	ppr PprDebug ty,
	--	ppr PprShowAll binder
	--	]))) (
	getUniDataSpecTyCon ty
	-- )

    alt_cons = [ con | (con,_,_,_) <- alts ]

    default_cons  = [ spec_con | spec_con <- spec_cons,	-- In this type
			         spec_con `not_elem` alt_cons ]	-- Not handled explicitly
	where
	  not_elem = isn'tIn "cgAlgAlts"

    -- (mk_extra_branch con) returns the a maybe for the extra branch for con.
    -- The "maybe" is because con may return in heap, in which case there is
    -- nothing to do. Otherwise, we have a special case for a nullary constructor,
    -- but in the general case we do an allocation and heap-check.

    mk_extra_branch :: DataCon -> (Maybe (FCode (ConTag, AbstractC)))

    mk_extra_branch con
      = ASSERT(isDataCon con)
	case dataReturnConvAlg con of
	  ReturnInHeap	  -> Nothing
	  ReturnInRegs rs -> Just (getAbsC (alloc_code rs) `thenFC` \ abs_c ->
				   returnFC (tag, abs_c)
				  )
      where
	lf_info		= mkConLFInfo con
	tag		= getDataConTag con
    	closure_lbl 	= mkClosureLabel con

	-- alloc_code generates code to allocate constructor con, whose args are
	-- in the arguments to alloc_code, assigning the result to Node.
	alloc_code :: [MagicId] -> Code

	alloc_code regs
	  = possibleHeapCheck gc_flag regs False (
		buildDynCon binder useCurrentCostCentre con
				(map CReg regs) (all zero_size regs)
						`thenFC` \ idinfo ->
		idInfoToAmode PtrKind idinfo	`thenFC` \ amode ->

		absC (CAssign (CReg node) amode) `thenC`
		absC jump_instruction
	    )
	  where
	    zero_size reg = getKindSize (kindFromMagicId reg) == 0
\end{code}

Now comes the general case

\begin{code}
cgAlgAlts gc_flag uniq restore_cc must_label_branches ty alts deflt 
	{- The deflt is either StgNoDefault or a BindDefault which doesn't use the binder -}
  = forkAlts (map (cgAlgAlt gc_flag uniq restore_cc must_label_branches) alts)
	     [{- No "extra branches" -}]
	     (cgAlgDefault gc_flag uniq restore_cc must_label_branches deflt)
\end{code}

\begin{code}
cgAlgDefault :: GCFlag
	     -> Unique -> AbstractC -> Bool -- turgid state...
	     -> PlainStgCaseDefault	    -- input
	     -> FCode AbstractC		    -- output

cgAlgDefault gc_flag uniq restore_cc must_label_branch
	     StgNoDefault
  = returnFC AbsCNop

cgAlgDefault gc_flag uniq restore_cc must_label_branch
	     (StgBindDefault _ False{-binder not used-} rhs)

  = getAbsC (absC restore_cc `thenC`
	     possibleHeapCheck gc_flag [] False (cgExpr rhs)) `thenFC` \ abs_c ->
    let
	final_abs_c | must_label_branch = CJump (CLabelledCode lbl abs_c)
		    | otherwise	        = abs_c
    in
    returnFC final_abs_c
  where
    lbl = mkDefaultLabel uniq


cgAlgDefault gc_flag uniq restore_cc must_label_branch
	     (StgBindDefault binder True{-binder used-} rhs)

  = 	-- We have arranged that Node points to the thing, even
    	-- even if we return in registers
    bindNewToReg binder node mkLFArgument `thenC`
    getAbsC (absC restore_cc `thenC`
	     possibleHeapCheck gc_flag [node] False (cgExpr rhs)
	-- Node is live, but doesn't need to point at the thing itself;
	-- it's ok for Node to point to an indirection or FETCH_ME
	-- Hence no need to re-enter Node.
    )					`thenFC` \ abs_c ->

    let
	final_abs_c | must_label_branch = CJump (CLabelledCode lbl abs_c)
		    | otherwise	        = abs_c
    in
    returnFC final_abs_c
  where
    lbl = mkDefaultLabel uniq


cgAlgAlt :: GCFlag
	 -> Unique -> AbstractC -> Bool		-- turgid state
	 -> (Id, [Id], [Bool], PlainStgExpr)
	 -> FCode (ConTag, AbstractC)

cgAlgAlt gc_flag uniq restore_cc must_label_branch (con, args, use_mask, rhs)
  = getAbsC (absC restore_cc `thenC`
	     cgAlgAltRhs gc_flag con args use_mask rhs) `thenFC` \ abs_c -> 
    let
	final_abs_c | must_label_branch = CJump (CLabelledCode lbl abs_c)
		    | otherwise	        = abs_c
    in
    returnFC (tag, final_abs_c)
  where
    tag	= getDataConTag con
    lbl = mkAltLabel uniq tag

cgAlgAltRhs :: GCFlag -> Id -> [Id] -> [Bool] -> PlainStgExpr -> Code

cgAlgAltRhs gc_flag con args use_mask rhs
  = let
      (live_regs, node_reqd)
	= case (dataReturnConvAlg con) of
	    ReturnInHeap      -> ([],						  True)
	    ReturnInRegs regs -> ([reg | (reg,True) <- regs `zipEqual` use_mask], False)
				-- Pick the live registers using the use_mask
				-- Doing so is IMPORTANT, because with semi-tagging
				-- enabled only the live registers will have valid
				-- pointers in them.
    in
    possibleHeapCheck gc_flag live_regs node_reqd (
    (case gc_flag of
        NoGC   	    -> mapFCs bindNewToTemp args `thenFC` \ _ ->
		       nopC
    	GCMayHappen -> bindConArgs con args
    )	`thenC`
    cgExpr rhs 
    )
\end{code}

%************************************************************************
%*									*
\subsection[CgCase-semi-tagged-alts]{The code to deal with sem-tagging}
%*									*
%************************************************************************

Turgid-but-non-monadic code to conjure up the required info from
algebraic case alternatives for semi-tagging.

\begin{code}
cgSemiTaggedAlts :: Unique
		 -> [(Id, [Id], [Bool], PlainStgExpr)]
		 -> StgCaseDefault Id Id
		 -> SemiTaggingStuff

cgSemiTaggedAlts uniq alts deflt
  = Just (map st_alt alts, st_deflt deflt)
  where
    st_deflt StgNoDefault = Nothing

    st_deflt (StgBindDefault binder binder_used _)
      = Just (if binder_used then Just binder else Nothing,
	      (CCallProfCtrMacro SLIT("RET_SEMI_BY_DEFAULT") [], -- ToDo: monadise?
	       mkDefaultLabel uniq)
	     )

    st_alt (con, args, use_mask, _)
      = case (dataReturnConvAlg con) of

	  ReturnInHeap ->
	    -- Ha!  Nothing to do; Node already points to the thing
	    (con_tag,
	     (CCallProfCtrMacro SLIT("RET_SEMI_IN_HEAP") [], -- ToDo: monadise?
	     join_label)
	    )

	  ReturnInRegs regs ->
	    -- We have to load the live registers from the constructor
	    -- pointed to by Node.
	    let
		(_, regs_w_offsets) = layOutDynCon con kindFromMagicId regs

		used_regs = selectByMask use_mask regs

		used_regs_w_offsets = [ ro | ro@(reg,offset) <- regs_w_offsets, 
					     reg `is_elem` used_regs]

		is_elem = isIn "cgSemiTaggedAlts"
	    in
	    (con_tag,
	     (mkAbstractCs [
		CCallProfCtrMacro SLIT("RET_SEMI_IN_REGS") [], -- ToDo: macroise?
		CSimultaneous (mkAbstractCs (map move_to_reg used_regs_w_offsets))],
	      join_label))
      where
	con_tag	    = getDataConTag con
	join_label  = mkAltLabel uniq con_tag

    move_to_reg :: (MagicId, VirtualHeapOffset {-from Node-}) -> AbstractC
    move_to_reg (reg, offset)
      = CAssign (CReg reg) (CVal (NodeRel offset) (kindFromMagicId reg))

\end{code}

%************************************************************************
%*									*
\subsection[CgCase-prim-alts]{Primitive alternatives}
%*									*
%************************************************************************

@cgPrimAlts@ generates a suitable @CSwitch@ for dealing with the
alternatives of a primitive @case@, given an addressing mode for the
thing to scrutinise.  It also keeps track of the maximum stack depth
encountered down any branch.

As usual, no binders in the alternatives are yet bound.

\begin{code}
cgPrimAlts :: GCFlag
	   -> Unique
    	   -> UniType	
	   -> [(BasicLit, PlainStgExpr)]	-- Alternatives
	   -> PlainStgCaseDefault		-- Default
	   -> Code

cgPrimAlts gc_flag uniq ty alts deflt
  = cgPrimAltsGivenScrutinee gc_flag scrutinee alts deflt
 where
    -- A temporary variable, or standard register, to hold the result
    scrutinee = case gc_flag of
		     NoGC	 -> CTemp uniq kind
		     GCMayHappen -> CReg (dataReturnConvPrim kind)

    kind = kindFromType ty


cgPrimAltsGivenScrutinee gc_flag scrutinee alts deflt
  = forkAlts (map (cgPrimAlt gc_flag) alts)
	     [{- No "extra branches" -}]
	     (cgPrimDefault gc_flag scrutinee deflt) `thenFC` \ (alt_absCs, deflt_absC) ->
    absC (CSwitch scrutinee alt_absCs deflt_absC)
	  -- CSwitch does sensible things with one or zero alternatives


cgPrimAlt :: GCFlag
	  -> (BasicLit, PlainStgExpr)    -- The alternative
	  -> FCode (BasicLit, AbstractC) -- Its compiled form

cgPrimAlt gc_flag (lit, rhs)
  = getAbsC rhs_code	 `thenFC` \ absC ->
    returnFC (lit,absC)
  where
    rhs_code = possibleHeapCheck gc_flag [] False (cgExpr rhs )

cgPrimDefault :: GCFlag
	      -> CAddrMode		-- Scrutinee
	      -> PlainStgCaseDefault
	      -> FCode AbstractC

cgPrimDefault gc_flag scrutinee StgNoDefault
  = panic "cgPrimDefault: No default in prim case"

cgPrimDefault gc_flag scrutinee (StgBindDefault _ False{-binder not used-} rhs)
  = getAbsC (possibleHeapCheck gc_flag [] False (cgExpr rhs ))

cgPrimDefault gc_flag scrutinee (StgBindDefault binder True{-used-} rhs)
  = getAbsC (possibleHeapCheck gc_flag regs False rhs_code)
  where
    regs = if isFollowableKind (getAmodeKind scrutinee) then
	      [node] else []

    rhs_code = bindNewPrimToAmode binder scrutinee `thenC`
    	       cgExpr rhs
\end{code}


%************************************************************************
%*									*
\subsection[CgCase-tidy]{Code for tidying up prior to an eval}
%*									*
%************************************************************************

\begin{code}
saveVolatileVarsAndRegs
    :: PlainStgLiveVars               -- Vars which should be made safe
    -> FCode (AbstractC,              -- Assignments to do the saves
       EndOfBlockInfo,                -- New sequel, recording where the return
                                      -- address now is
       Maybe VirtualSpBOffset)        -- Slot for current cost centre


saveVolatileVarsAndRegs vars
  = saveVolatileVars vars     `thenFC` \ var_saves ->
    saveCurrentCostCentre     `thenFC` \ (maybe_cc_slot, cc_save) ->
    saveReturnAddress         `thenFC` \ (new_eob_info, ret_save) ->
    returnFC (mkAbstractCs [var_saves, cc_save, ret_save],
              new_eob_info,
              maybe_cc_slot)


saveVolatileVars :: PlainStgLiveVars	-- Vars which should be made safe
		 -> FCode AbstractC	-- Assignments to to the saves

saveVolatileVars vars
  = save_em (uniqSetToList vars)
  where
    save_em [] = returnFC AbsCNop

    save_em (var:vars)
      = getCAddrModeIfVolatile var `thenFC` \ v ->
	case v of
	    Nothing	    -> save_em vars -- Non-volatile, so carry on
			       

	    Just vol_amode  ->	-- Aha! It's volatile
			       save_var var vol_amode 	`thenFC` \ abs_c ->
			       save_em vars		`thenFC` \ abs_cs ->
			       returnFC (abs_c `mkAbsCStmts` abs_cs)

    save_var var vol_amode
      | isFollowableKind kind
      = allocAStack 			`thenFC` \ a_slot ->
	rebindToAStack var a_slot 	`thenC`
	getSpARelOffset a_slot		`thenFC` \ spa_rel ->
	returnFC (CAssign (CVal spa_rel kind) vol_amode)
      | otherwise
      = allocBStack (getKindSize kind) 	`thenFC` \ b_slot ->
	rebindToBStack var b_slot 	`thenC`
	getSpBRelOffset b_slot		`thenFC` \ spb_rel ->
	returnFC (CAssign (CVal spb_rel kind) vol_amode)
      where
        kind = getAmodeKind vol_amode

saveReturnAddress :: FCode (EndOfBlockInfo, AbstractC)
saveReturnAddress 
  = getEndOfBlockInfo                `thenFC` \ eob_info@(EndOfBlockInfo vA vB sequel) ->

      -- See if it is volatile
    case sequel of
      InRetReg ->     -- Yes, it's volatile
                   allocBStack retKindSize    `thenFC` \ b_slot ->
                   getSpBRelOffset b_slot      `thenFC` \ spb_rel ->

                   returnFC (EndOfBlockInfo vA vB (OnStack b_slot),
                             CAssign (CVal spb_rel RetKind) (CReg RetReg))

      UpdateCode _ ->   -- It's non-volatile all right, but we still need
			-- to allocate a B-stack slot for it, *solely* to make
			-- sure that update frames for different values do not
			-- appear adjacent on the B stack. This makes sure
			-- that B-stack squeezing works ok.
			-- See note below
                   allocBStack retKindSize    `thenFC` \ b_slot ->
	           returnFC (eob_info, AbsCNop)

      other ->     	 -- No, it's non-volatile, so do nothing
                   returnFC (eob_info, AbsCNop)
\end{code}

Note about B-stack squeezing.  Consider the following:`

	y = [...] \u [] -> ...
	x = [y]   \u [] -> case y of (a,b) -> a

The code for x will push an update frame, and then enter y.  The code
for y will push another update frame.  If the B-stack-squeezer then
wakes up, it will see two update frames right on top of each other,
and will combine them.  This is WRONG, of course, because x's value is
not the same as y's.

The fix implemented above makes sure that we allocate an (unused)
B-stack slot before entering y.  You can think of this as holding the
saved value of RetAddr, which (after pushing x's update frame will be
some update code ptr).  The compiler is clever enough to load the
static update code ptr into RetAddr before entering ~a~, but the slot
is still there to separate the update frames.

When we save the current cost centre (which is done for lexical
scoping), we allocate a free B-stack location, and return (a)~the
virtual offset of the location, to pass on to the alternatives, and
(b)~the assignment to do the save (just as for @saveVolatileVars@).

\begin{code}
saveCurrentCostCentre :: 
	FCode (Maybe VirtualSpBOffset,	-- Where we decide to store it
					--   Nothing if not lexical CCs
	       AbstractC)		-- Assignment to save it
					--   AbsCNop if not lexical CCs

saveCurrentCostCentre
  = isSwitchSetC SccProfilingOn		`thenFC` \ doing_profiling ->
    if not doing_profiling then
	returnFC (Nothing, AbsCNop)
    else
	allocBStack (getKindSize CostCentreKind) `thenFC` \ b_slot ->
	getSpBRelOffset b_slot		     	 `thenFC` \ spb_rel ->
	returnFC (Just b_slot,
		  CAssign (CVal spb_rel CostCentreKind) (CReg CurCostCentre))

restoreCurrentCostCentre :: Maybe VirtualSpBOffset -> FCode AbstractC

restoreCurrentCostCentre Nothing 
 = returnFC AbsCNop
restoreCurrentCostCentre (Just b_slot) 
 = getSpBRelOffset b_slot			 `thenFC` \ spb_rel ->
   freeBStkSlot b_slot				 `thenC`
   returnFC (CCallProfCCMacro SLIT("RESTORE_CCC") [CVal spb_rel CostCentreKind])
    -- we use the RESTORE_CCC macro, rather than just
    -- assigning into CurCostCentre, in case RESTORE_CCC
    -- has some sanity-checking in it.
\end{code}


%************************************************************************
%*									*
\subsection[CgCase-return-vec]{Building a return vector}
%*									*
%************************************************************************

Build a return vector, and return a suitable label addressing
mode for it.

\begin{code}
mkReturnVector :: Unique
	       -> UniType
	       -> [(ConTag, AbstractC)] -- Branch codes
	       -> AbstractC		-- Default case
	       -> FCode CAddrMode

mkReturnVector uniq ty tagged_alt_absCs deflt_absC
  = let
     (return_vec_amode, vtbl_body) = case (ctrlReturnConvAlg spec_tycon) of {

      UnvectoredReturn _ ->
    	(CUnVecLbl ret_label vtbl_label,
	 absC (CRetUnVector vtbl_label
	                    (CLabelledCode ret_label
    	    	    	    	    	   (mkAlgAltsCSwitch (CReg TagReg) 
    	    	    	    	    	    	    	     tagged_alt_absCs 
                                                             deflt_absC))));
      VectoredReturn table_size ->
    	(CLbl vtbl_label DataPtrKind,
	 absC (CRetVector vtbl_label
			-- must restore cc before each alt, if required
	                  (map mk_vector_entry [fIRST_TAG .. (table_size+fIRST_TAG-1)])
			  deflt_absC))

-- Leave nops and comments in for now; they are eliminated
-- lazily as it's printed.
--	                  (case (nonemptyAbsC deflt_absC) of
--		                Nothing  -> AbsCNop
--		                Just def -> def)

    } in
    vtbl_body    	    	    	    	    	    `thenC`
    returnFC return_vec_amode
    -- )
  where

    (spec_tycon,_,_) = case (getUniDataSpecTyCon_maybe ty) of -- *must* be a real "data" type constructor
	      Just xx -> xx
	      Nothing -> error ("ERROR: can't generate code for polymorphic case;\nprobably a mis-use of `seq' or `par';\nthe User's Guide has more details.\nOffending type: "++(ppShow 80 (ppr PprDebug ty)))

    vtbl_label = mkVecTblLabel uniq
    ret_label = mkReturnPtLabel uniq

    mk_vector_entry :: ConTag -> Maybe CAddrMode
    mk_vector_entry tag
      = case [ absC | (t, absC) <- tagged_alt_absCs, t == tag ] of
	     []     -> Nothing
	     [absC] -> Just (CCode absC)
	     _      -> panic "mkReturnVector: too many"
\end{code}

%************************************************************************
%*									*
\subsection[CgCase-utils]{Utilities for handling case expressions}
%*									*
%************************************************************************

@possibleHeapCheck@ tests a flag passed in to decide whether to
do a heap check or not.

\begin{code}
possibleHeapCheck :: GCFlag -> [MagicId] -> Bool -> Code -> Code

possibleHeapCheck GCMayHappen regs node_reqd code = heapCheck regs node_reqd code
possibleHeapCheck NoGC	      _    _         code = code
\end{code}

Select a restricted set of registers based on a usage mask.

\begin{code}
selectByMask []	    	[]	   = []
selectByMask (True:ms)  (x:xs) = x : selectByMask ms xs
selectByMask (False:ms) (x:xs) = selectByMask ms xs
\end{code}
