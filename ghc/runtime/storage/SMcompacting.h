# line 4 "storage/SMcompacting.lh"
extern void LinkRoots PROTO((P_ roots[], I_ rootno));
extern void LinkAStack PROTO((PP_ stackA, PP_ botA));
extern void LinkBStack PROTO((P_ stackB, P_ botB));
extern I_ CountCAFs PROTO((P_ CAFlist));

extern void LinkCAFs PROTO((P_ CAFlist));
