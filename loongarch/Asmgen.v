(* *********************************************************************)
(*                                                                     *)
(*              The Compcert verified compiler                         *)
(*                                                                     *)
(*          Xavier Leroy, INRIA Paris-Rocquencourt                     *)
(*           Prashanth Mundkur, SRI International                      *)
(*                                                                     *)
(*  Copyright Institut National de Recherche en Informatique et en     *)
(*  Automatique.  All rights reserved.  This file is distributed       *)
(*  under the terms of the INRIA Non-Commercial License Agreement.     *)
(*                                                                     *)
(*  The contributions by Prashanth Mundkur are reused and adapted      *)
(*  under the terms of a Contributor License Agreement between         *)
(*  SRI International and INRIA.                                       *)
(*                                                                     *)
(* *********************************************************************)

(** Translation from Mach to LoongArch assembly language *)

Require Archi.
Require Import Coqlib Errors.
Require Import AST Integers Floats Memdata.
Require Import Op Locations Mach Asm.

Local Open Scope string_scope.
Local Open Scope error_monad_scope.

(** The code generation functions take advantage of several
  characteristics of the [Mach] code generated by earlier passes of the
  compiler, mostly that argument and result registers are of the correct
  types.  These properties are true by construction, but it's easier to
  recheck them during code generation and fail if they do not hold. *)

(** Extracting integer or float registers. *)

Definition ireg_of (r: mreg) : res ireg :=
  match preg_of r with IR mr => OK mr | _ => Error(msg "Asmgen.ireg_of") end.

Definition freg_of (r: mreg) : res freg :=
  match preg_of r with FR mr => OK mr | _ => Error(msg "Asmgen.freg_of") end.

(** Decomposition of 32-bit integer constants.  They are split into either
  small signed immediates that fit in 12-bits, or, if they do not fit,
  into a (20-bit hi, 12-bit lo) pair where lo is sign-extended. *)

Inductive immed32 : Type :=
  | Imm32_single (imm: int)
  | Imm32_pair   (hi: int) (lo: int).

Definition make_immed32 (val: int) :=
  let lo := Int.sign_ext 12 val in
  if Int.eq val lo then
    Imm32_single val
  else
    let hi := Int.shru (Int.sub val lo) (Int.repr 12) in
    Imm32_pair hi lo.

(** Likewise, for 64-bit integer constants. *)

Inductive immed64 : Type :=
  | Imm64_single (imm: int64)
  | Imm64_pair   (hi: int64) (lo: int64)
  | Imm64_large  (imm: int64).


Definition make_immed64 (val: int64) :=
  let lo := Int64.sign_ext 12 val in
  if Int64.eq val lo then 
    Imm64_single lo 
  else
    let hi := Int64.sign_ext 20 (Int64.shru (Int64.sub val lo) (Int64.repr 12)) in
    if Int64.eq val (Int64.add (Int64.sign_ext 32 (Int64.shl hi (Int64.repr 12))) lo) then
      Imm64_pair hi lo
    else
      Imm64_large val.

(** Smart constructors for arithmetic operations involving
  a 32-bit or 64-bit integer constant.  Depending on whether the
  constant fits in 12 bits or not, one or several instructions
  are generated as required to perform the operation
  and prepended to the given instruction sequence [k]. *)
    
Definition load_hilo32 (r: ireg) (hi lo: int) k :=
  let n := Int.add (Int.shl hi (Int.repr 12)) lo in
  let lo12 := Int.zero_ext 12 n in
  let hi_ := Int.shru n (Int.repr 12) in
  let hi20 := Int.add hi_ (Int.shl (Int.shru (Int.shr n (Int.repr 12)) (Int.repr 20)) (Int.repr 20)) in
  if Int.eq lo12 Int.zero then Plu12iw r hi20 :: k
  else Plu12iw r hi20 :: Poriw r r lo12 :: k.
    
Definition loadimm32 (r: ireg) (n: int) (k: code) :=
  match make_immed32 n with
  | Imm32_single imm => Paddiw r R0 imm :: k
  | Imm32_pair hi lo => load_hilo32 r hi lo k
  end.

Definition opsi32 (op: ireg -> ireg0 -> ireg0 -> instruction)
                   (opimm: ireg -> ireg0 -> int -> instruction)
                   (rd rs: ireg) (n: int) (k: code) :=
  match make_immed32 n with
  | Imm32_single imm => opimm rd rs imm :: k
  | Imm32_pair hi lo => load_hilo32 R20 hi lo (op rd rs R20 :: k)
  end.

Definition opui32 (op: ireg -> ireg0 -> ireg0 -> instruction)
                   (opimm: ireg -> ireg0 -> int -> instruction)
                   (rd rs: ireg) (n: int) (k: code) :=
  if Int.eq n (Int.zero_ext 12 n) then
    opimm rd rs n :: k
  else
    loadimm32 R20 n (op rd rs R20 :: k).

Definition addimm32 := opsi32 Paddw Paddiw.
Definition andimm32 := opui32 Pandw Pandiw.
Definition orimm32  := opui32 Porw  Poriw.
Definition xorimm32 := opui32 Pxorw Pxoriw.
Definition sltimm32 := opsi32 Psltw Psltiw.
Definition sltuimm32 := opsi32 Psltwu Psltuiw.

Definition load_lolo64 (r: ireg) (lo20 lo12: int64) k :=
  if Int64.eq lo12 Int64.zero then
    Plu12id r lo20 :: k
  else if Int64.eq lo20 Int64.zero then
    Porid r R0 lo12 :: k
  else
    Plu12id r lo20 :: Porid r r lo12 :: k.
  
Definition load_hilo64 (r: ireg) (hi lo: int64) k :=
  if Int64.eq lo Int64.zero then Plu12id r hi :: k
  else Plu12id r hi :: Paddid r r lo :: k.

Definition loadimm64 (r: ireg) (n: int64) (k: code) :=
  match make_immed64 n with
  | Imm64_single imm => Paddid r R0 imm :: k
  | Imm64_pair hi lo => load_hilo64 r hi lo k
  | Imm64_large imm  => Ploadli r imm :: k
  end.

Definition opsi64 (op: ireg -> ireg0 -> ireg0 -> instruction)
                   (opimm: ireg -> ireg0 -> int64 -> instruction)
                   (rd rs: ireg) (n: int64) (k: code) :=
  match make_immed64 n with
  | Imm64_single imm => opimm rd rs imm :: k
  | Imm64_pair hi lo => load_hilo64 R20 hi lo (op rd rs R20 :: k)
  | Imm64_large imm  => Ploadli R20 imm :: op rd rs R20 :: k
  end.

Definition opui64 (op: ireg -> ireg0 -> ireg0 -> instruction)
                   (opimm: ireg -> ireg0 -> int64 -> instruction)
                   (rd rs: ireg) (n: int64) (k: code) :=
  if Int64.eq n (Int64.zero_ext 12 n) then
    opimm rd rs n :: k
  else
    loadimm64 R20 n (op rd rs R20 :: k).

Definition addimm64 := opsi64 Paddd Paddid.
Definition andimm64 := opui64 Pandd Pandid.
Definition orimm64  := opui64 Pord Porid.
Definition xorimm64 := opui64 Pxord Pxorid.
Definition sltimm64 := opsi64 Psltd Psltid.
Definition sltuimm64 := opsi64 Psltdu Psltuid.

Definition addptrofs (rd rs: ireg) (n: ptrofs) (k: code) :=
  if Ptrofs.eq_dec n Ptrofs.zero then
    Pmv rd rs :: k
  else
    if Archi.ptr64
    then addimm64 rd rs (Ptrofs.to_int64 n) k
    else addimm32 rd rs (Ptrofs.to_int n) k.
  
(** Translation of conditional branches. *)

Definition transl_cbranch_int32s (cmp: comparison) (r1 r2: ireg0) (lbl: label) :=
  match cmp with
  | Ceq => Pbeqw r1 r2 lbl
  | Cne => Pbnew r1 r2 lbl
  | Clt => Pbltw r1 r2 lbl
  | Cle => Pbgew r2 r1 lbl
  | Cgt => Pbltw r2 r1 lbl
  | Cge => Pbgew r1 r2 lbl
  end.

Definition transl_cbranch_int32u (cmp: comparison) (r1 r2: ireg0) (lbl: label) :=
  match cmp with
  | Ceq => Pbeqw  r1 r2 lbl
  | Cne => Pbnew  r1 r2 lbl
  | Clt => Pbltwu r1 r2 lbl
  | Cle => Pbgewu r2 r1 lbl
  | Cgt => Pbltwu r2 r1 lbl
  | Cge => Pbgewu r1 r2 lbl
  end.

Definition transl_cbranch_int64s (cmp: comparison) (r1 r2: ireg0) (lbl: label) :=
  match cmp with
  | Ceq => Pbeqd r1 r2 lbl
  | Cne => Pbned r1 r2 lbl
  | Clt => Pbltd r1 r2 lbl
  | Cle => Pbged r2 r1 lbl
  | Cgt => Pbltd r2 r1 lbl
  | Cge => Pbged r1 r2 lbl
  end.

Definition transl_cbranch_int64u (cmp: comparison) (r1 r2: ireg0) (lbl: label) :=
  match cmp with
  | Ceq => Pbeqd  r1 r2 lbl
  | Cne => Pbned  r1 r2 lbl
  | Clt => Pbltdu r1 r2 lbl
  | Cle => Pbgedu r2 r1 lbl
  | Cgt => Pbltdu r2 r1 lbl
  | Cge => Pbgedu r1 r2 lbl
  end.

Definition transl_cond_float (cmp: comparison) (cc: cfreg) (fs1 fs2: freg) :=
  match cmp with
  | Ceq => (Pfeqd cc fs1 fs2, true)
  | Cne => (Pfeqd cc fs1 fs2, false)
  | Clt => (Pfltd cc fs1 fs2, true)
  | Cle => (Pfled cc fs1 fs2, true)
  | Cgt => (Pfltd cc fs2 fs1, true)
  | Cge => (Pfled cc fs2 fs1, true)
  end.
  
Definition transl_cond_single (cmp: comparison) (cc: cfreg) (fs1 fs2: freg) :=
  match cmp with
  | Ceq => (Pfeqs cc fs1 fs2, true)
  | Cne => (Pfeqs cc fs1 fs2, false)
  | Clt => (Pflts cc fs1 fs2, true)
  | Cle => (Pfles cc fs1 fs2, true)
  | Cgt => (Pflts cc fs2 fs1, true)
  | Cge => (Pfles cc fs2 fs1, true)
  end.
  
Definition transl_cbranch
           (cond: condition) (args: list mreg) (lbl: label) (k: code) :=
  match cond, args with
  | Ccomp c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cbranch_int32s c r1 r2 lbl :: k)
  | Ccompu c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cbranch_int32u c r1 r2 lbl :: k)
  | Ccompimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if Int.eq n Int.zero then
            match c with
            | Ceq => Pbeqw r1 R0 lbl :: k
            | Cne => Pbnew r1 R0 lbl :: k
            | _ => transl_cbranch_int32s c r1 R0 lbl :: k
            end
          else
            loadimm32 R20 n (transl_cbranch_int32s c r1 R20 lbl :: k))
  | Ccompuimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if Int.eq n Int.zero then
            match c with
            | Ceq => Pbeqw r1 R0 lbl :: k
            | Cne => Pbnew r1 R0 lbl :: k
            | _ => transl_cbranch_int32u c r1 R0 lbl :: k
            end
          else
            loadimm32 R20 n (transl_cbranch_int32u c r1 R20 lbl :: k))
  | Ccompl c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cbranch_int64s c r1 r2 lbl :: k)
  | Ccomplu c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cbranch_int64u c r1 r2 lbl :: k)
  | Ccomplimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if Int64.eq n Int64.zero then
            match c with
            | Ceq => Pbeqd r1 R0 lbl :: k
            | Cne => Pbned r1 R0 lbl :: k
            | _ => transl_cbranch_int64s c r1 R0 lbl :: k
            end
          else
            loadimm64 R20 n (transl_cbranch_int64s c r1 R20 lbl :: k))
  | Ccompluimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (if Int64.eq n Int64.zero then
            match c with
            | Ceq => Pbeqd r1 R0 lbl :: k
            | Cne => Pbned r1 R0 lbl :: k
            | _ => transl_cbranch_int64u c r1 R0 lbl :: k
            end
          else
            loadimm64 R20 n (transl_cbranch_int64u c r1 R20 lbl :: k))
  | Ccompf c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_float c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr R20 FCC0 :: (if normal then Pbnew R20 R0 lbl else Pbeqw R20 R0 lbl) :: k)
  | Cnotcompf c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_float c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr R20 FCC0 :: (if normal then Pbeqw R20 R0 lbl else Pbnew R20 R0 lbl) :: k)
  | Ccompfs c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_single c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr R20 FCC0 :: (if normal then Pbnew R20 R0 lbl else Pbeqw R20 R0 lbl) :: k)
  | Cnotcompfs c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_single c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr R20 FCC0 :: (if normal then Pbeqw R20 R0 lbl else Pbnew R20 R0 lbl) :: k)
  | _, _ =>
      Error(msg "Asmgen.transl_cond_branch")
  end.

(** Translation of a condition operator.  The generated code sets the
  [rd] target register to 0 or 1 depending on the truth value of the
  condition. *)

Definition transl_cond_int32s (cmp: comparison) (rd: ireg) (r1 r2: ireg0) (k: code) :=
  match cmp with
  | Ceq => Pseqw rd r1 r2 :: k
  | Cne => Psnew rd r1 r2 :: k
  | Clt => Psltw rd r1 r2 :: k
  | Cle => Psltw rd r2 r1 :: Pxoriw rd rd Int.one :: k
  | Cgt => Psltw rd r2 r1 :: k
  | Cge => Psltw rd r1 r2 :: Pxoriw rd rd Int.one :: k
  end.

Definition transl_cond_int32u (cmp: comparison) (rd: ireg) (r1 r2: ireg0) (k: code) :=
  match cmp with
  | Ceq => Pseqw rd r1 r2 :: k
  | Cne => Psnew rd r1 r2 :: k
  | Clt => Psltwu rd r1 r2 :: k
  | Cle => Psltwu rd r2 r1 :: Pxoriw rd rd Int.one :: k
  | Cgt => Psltwu rd r2 r1 :: k
  | Cge => Psltwu rd r1 r2 :: Pxoriw rd rd Int.one :: k
  end.

Definition transl_cond_int64s (cmp: comparison) (rd: ireg) (r1 r2: ireg0) (k: code) :=
  match cmp with
  | Ceq => Pseqd rd r1 r2 :: k
  | Cne => Psned rd r1 r2 :: k
  | Clt => Psltd rd r1 r2 :: k
  | Cle => Psltd rd r2 r1 :: Pxoriw rd rd Int.one :: k
  | Cgt => Psltd rd r2 r1 :: k
  | Cge => Psltd rd r1 r2 :: Pxoriw rd rd Int.one :: k
  end.

Definition transl_cond_int64u (cmp: comparison) (rd: ireg) (r1 r2: ireg0) (k: code) :=
  match cmp with
  | Ceq => Pseqd rd r1 r2 :: k
  | Cne => Psned rd r1 r2 :: k
  | Clt => Psltdu rd r1 r2 :: k
  | Cle => Psltdu rd r2 r1 :: Pxoriw rd rd Int.one :: k
  | Cgt => Psltdu rd r2 r1 :: k
  | Cge => Psltdu rd r1 r2 :: Pxoriw rd rd Int.one :: k
  end.

Definition transl_condimm_int32s (cmp: comparison) (rd: ireg) (r1: ireg) (n: int) (k: code) :=
  if Int.eq n Int.zero then transl_cond_int32s cmp rd r1 R0 k else
  match cmp with
  | Ceq | Cne => xorimm32 rd r1 n (transl_cond_int32s cmp rd rd R0 k)
  | Clt => sltimm32 rd r1 n k
  | Cle => if Int.eq n (Int.repr Int.max_signed)
           then loadimm32 rd Int.one k
           else sltimm32 rd r1 (Int.add n Int.one) k
  | _   => loadimm32 R20 n (transl_cond_int32s cmp rd r1 R20 k)
  end.

Definition transl_condimm_int32u (cmp: comparison) (rd: ireg) (r1: ireg) (n: int) (k: code) :=
  if Int.eq n Int.zero then transl_cond_int32u cmp rd r1 R0 k else
  match cmp with
  | Clt => sltuimm32 rd r1 n k
  | _   => loadimm32 R20 n (transl_cond_int32u cmp rd r1 R20 k)
  end.

Definition transl_condimm_int64s (cmp: comparison) (rd: ireg) (r1: ireg) (n: int64) (k: code) :=
  if Int64.eq n Int64.zero then transl_cond_int64s cmp rd r1 R0 k else
  match cmp with
  | Ceq | Cne => xorimm64 rd r1 n (transl_cond_int64s cmp rd rd R0 k)
  | Clt => sltimm64 rd r1 n k
  | Cle => if Int64.eq n (Int64.repr Int64.max_signed)
           then loadimm32 rd Int.one k
           else sltimm64 rd r1 (Int64.add n Int64.one) k
  | _   => loadimm64 R20 n (transl_cond_int64s cmp rd r1 R20 k)
  end.

Definition transl_condimm_int64u (cmp: comparison) (rd: ireg) (r1: ireg) (n: int64) (k: code) :=
  if Int64.eq n Int64.zero then transl_cond_int64u cmp rd r1 R0 k else
  match cmp with
  | Clt => sltuimm64 rd r1 n k
  | _   => loadimm64 R20 n (transl_cond_int64u cmp rd r1 R20 k)
  end.

Definition transl_cond_op
           (cond: condition) (rd: ireg) (args: list mreg) (k: code) :=
  match cond, args with
  | Ccomp c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cond_int32s c rd r1 r2 k)
  | Ccompu c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cond_int32u c rd r1 r2 k)
  | Ccompimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (transl_condimm_int32s c rd r1 n k)
  | Ccompuimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (transl_condimm_int32u c rd r1 n k)
  | Ccompl c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cond_int64s c rd r1 r2 k)
  | Ccomplu c, a1 :: a2 :: nil =>
      do r1 <- ireg_of a1; do r2 <- ireg_of a2;
      OK (transl_cond_int64u c rd r1 r2 k)
  | Ccomplimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (transl_condimm_int64s c rd r1 n k)
  | Ccompluimm c n, a1 :: nil =>
      do r1 <- ireg_of a1;
      OK (transl_condimm_int64u c rd r1 n k)
  | Ccompf c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_float c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr rd FCC0 :: if normal then k else Pxoriw rd rd Int.one :: k)
  | Cnotcompf c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_float c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr rd FCC0 :: if normal then Pxoriw rd rd Int.one :: k else k)
  | Ccompfs c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_single c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr rd FCC0 :: if normal then k else Pxoriw rd rd Int.one :: k)
  | Cnotcompfs c, f1 :: f2 :: nil =>
      do r1 <- freg_of f1; do r2 <- freg_of f2;
      let (insn, normal) := transl_cond_single c FCC0 r1 r2 in
      OK (insn :: Pmovcf2gr rd FCC0 :: if normal then Pxoriw rd rd Int.one :: k else k)
  | _, _ =>
      Error(msg "Asmgen.transl_cond_op")
  end.

(** Translation of the arithmetic operation [r <- op(args)].
  The corresponding instructions are prepended to [k]. *)

Definition transl_op
              (op: operation) (args: list mreg) (res: mreg) (k: code) :=
  match op, args with
  | Omove, a1 :: nil =>
      match preg_of res, preg_of a1 with
      | IR r, IR a => OK (Pmv r a :: k)
      | FR r, FR a => OK (Pfmv r a :: k)
      |  _  ,  _   => Error(msg "Asmgen.Omove")
      end
  | Ointconst n, nil =>
      do rd <- ireg_of res;
      OK (loadimm32 rd n k)
  | Olongconst n, nil =>
      do rd <- ireg_of res;
      OK (loadimm64 rd n k)
  | Ofloatconst f, nil =>
      do rd <- freg_of res;
      OK (Ploadfi rd f :: k)
  | Osingleconst f, nil =>
      do rd <- freg_of res;
      OK (Ploadsi rd f :: k)
  | Oaddrsymbol s ofs, nil =>
      do rd <- ireg_of res;
      OK (Ploadsymbol rd s :: addptrofs rd rd ofs k)
  | Oaddrstack n, nil =>
      do rd <- ireg_of res;
      OK (addptrofs rd SP n k)

  | Ocast8signed, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Pslliw rd rs (Int.repr 24) :: Psraiw rd rd (Int.repr 24) :: k)
  | Ocast16signed, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Pslliw rd rs (Int.repr 16) :: Psraiw rd rd (Int.repr 16) :: k)
  | Oadd, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Paddw rd rs1 rs2 :: k)
  | Oaddimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (addimm32 rd rs n k)
  | Oneg, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (Psubw rd R0 rs :: k)
  | Osub, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psubw rd rs1 rs2 :: k)
  | Omul, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmulw rd rs1 rs2 :: k)
  | Omulhs, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmulhw rd rs1 rs2 :: k)
  | Omulhu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmulhwu rd rs1 rs2 :: k)
  | Odiv, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pdivw rd rs1 rs2 :: k)
  | Odivu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pdivwu rd rs1 rs2 :: k)
  | Omod, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmodw rd rs1 rs2 :: k)
  | Omodu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmodwu rd rs1 rs2 :: k)
  | Oand, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pandw rd rs1 rs2 :: k)
  | Oandimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (andimm32 rd rs n k)
  | Oor, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Porw rd rs1 rs2 :: k)
  | Oorimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (orimm32 rd rs n k)
  | Oxor, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pxorw rd rs1 rs2 :: k)
  | Oxorimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (xorimm32 rd rs n k)
  | Onot, a1 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1;
      OK (Pnorw rd R0 rs1 :: k)
  | Onor, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pnorw rd rs1 rs2 :: k)
  | Oandn, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pandnw rd rs1 rs2 :: k) 
  | Oorn, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pornw rd rs1 rs2 :: k) 
  | Oshl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psllw rd rs1 rs2 :: k)
  | Oshlimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Pslliw rd rs n :: k)
  | Oshr, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psraw rd rs1 rs2 :: k)
  | Oshrimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Psraiw rd rs n :: k)
  | Oshru, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psrlw rd rs1 rs2 :: k)
  | Oshruimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Psrliw rd rs n :: k)
  | Oshrximm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (if Int.eq n Int.zero then Pmv rd rs :: k else
          Psraiw R20 rs (Int.repr 31) ::
          Psrliw R20 R20 (Int.sub Int.iwordsize n) ::
          Paddw R20 rs R20 ::
          Psraiw rd R20 n :: k)  

  (* [Omakelong], [Ohighlong]  should not occur *)
  | Olowlong, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Pcvtl2w rd rs :: k)  
  | Ocast32signed, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      assertion (ireg_eq rd rs);
      OK (Pcvtw2l rd :: k)
  | Ocast32unsigned, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      assertion (ireg_eq rd rs);
      OK (Pcvtw2l rd :: Psllid rd rd (Int.repr 32) :: Psrlid rd rd (Int.repr 32) :: k)
  | Oaddl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Paddd rd rs1 rs2 :: k)
  | Oaddlimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (addimm64 rd rs n k)
  | Onegl, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (Psubd rd R0 rs :: k)
  | Osubl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psubd rd rs1 rs2 :: k)
  | Omull, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmuld rd rs1 rs2 :: k)
  | Omullhs, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmulhd rd rs1 rs2 :: k)
  | Omullhu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmulhdu rd rs1 rs2 :: k)
  | Odivl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pdivd rd rs1 rs2 :: k)
  | Odivlu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pdivdu rd rs1 rs2 :: k)
  | Omodl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmodd rd rs1 rs2 :: k)
  | Omodlu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pmoddu rd rs1 rs2 :: k)
  | Oandl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pandd rd rs1 rs2 :: k)
  | Oandlimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (andimm64 rd rs n k)
  | Oorl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pord rd rs1 rs2 :: k)
  | Oorlimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (orimm64 rd rs n k)
  | Oxorl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pxord rd rs1 rs2 :: k)
  | Oxorlimm n, a1 :: nil =>
      do rd  <- ireg_of res; do rs <- ireg_of a1;
      OK (xorimm64 rd rs n k)
  | Onotl, a1 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1;
      OK (Pnord rd R0 rs1 :: k)
  | Onorl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pnord rd rs1 rs2 :: k)
  | Oandnl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pandnd rd rs1 rs2 :: k) 
  | Oornl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pornd rd rs1 rs2 :: k)
  | Oshll, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Pslld rd rs1 rs2 :: k)
  | Oshllimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Psllid rd rs n :: k)
  | Oshrl, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psrad rd rs1 rs2 :: k)
  | Oshrlimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Psraid rd rs n :: k)
  | Oshrlu, a1 :: a2 :: nil =>
      do rd <- ireg_of res; do rs1 <- ireg_of a1; do rs2 <- ireg_of a2;
      OK (Psrld rd rs1 rs2 :: k)
  | Oshrluimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (Psrlid rd rs n :: k)
  | Oshrxlimm n, a1 :: nil =>
      do rd <- ireg_of res; do rs <- ireg_of a1;
      OK (if Int.eq n Int.zero then Pmv rd rs :: k else
          Psraid R20 rs (Int.repr 63) ::
          Psrlid R20 R20 (Int.sub Int64.iwordsize' n) ::
          Paddd R20 rs R20 ::
          Psraid rd R20 n :: k)  

  | Onegf, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfnegd rd rs :: k)
  | Oabsf, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfabsd rd rs :: k)
  | Oaddf, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfaddd rd rs1 rs2 :: k)
  | Osubf, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfsubd rd rs1 rs2 :: k)
  | Omulf, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfmuld rd rs1 rs2 :: k)
  | Odivf, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfdivd rd rs1 rs2 :: k)

  | Onegfs, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfnegs rd rs :: k)
  | Oabsfs, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfabss rd rs :: k)
  | Oaddfs, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfadds rd rs1 rs2 :: k)
  | Osubfs, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfsubs rd rs1 rs2 :: k)
  | Omulfs, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfmuls rd rs1 rs2 :: k)
  | Odivfs, a1 :: a2 :: nil =>
      do rd <- freg_of res; do rs1 <- freg_of a1; do rs2 <- freg_of a2;
      OK (Pfdivs rd rs1 rs2 :: k)

  | Osingleoffloat, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfcvtsd rd rs :: k)
  | Ofloatofsingle, a1 :: nil =>
      do rd <- freg_of res; do rs <- freg_of a1;
      OK (Pfcvtds rd rs :: k)

  | Ointoffloat, a1 :: nil =>
      do rd <- ireg_of res; do rs <- freg_of a1;
      OK (Pfcvtwd rd rs :: k)
  | Ofloatofint, a1 :: nil =>
      do rd <- freg_of res; do rs <- ireg_of a1;
      OK (Pfcvtdw rd rs :: k)
  | Ointofsingle, a1 :: nil =>
      do rd <- ireg_of res; do rs <- freg_of a1;
      OK (Pfcvtws rd rs :: k)
  | Osingleofint, a1 :: nil =>
      do rd <- freg_of res; do rs <- ireg_of a1;
      OK (Pfcvtsw rd rs :: k)

  | Olongoffloat, a1 :: nil =>
      do rd <- ireg_of res; do rs <- freg_of a1;
      OK (Pfcvtld rd rs :: k)
  | Ofloatoflong, a1 :: nil =>
      do rd <- freg_of res; do rs <- ireg_of a1;
      OK (Pfcvtdl rd rs :: k)
  | Olongofsingle, a1 :: nil =>
      do rd <- ireg_of res; do rs <- freg_of a1;
      OK (Pfcvtls rd rs :: k)
  | Osingleoflong, a1 :: nil =>
      do rd <- freg_of res; do rs <- ireg_of a1;
      OK (Pfcvtsl rd rs :: k)

  | Ocmp cmp, _ =>
      do rd <- ireg_of res;
      transl_cond_op cmp rd args k

  | _, _ =>
      Error(msg "Asmgen.transl_op")
  end.

(** Accessing data in the stack frame. *)

Definition indexed_memory_access
        (mk_instr: ireg -> offset -> instruction)
        (base: ireg) (ofs: ptrofs) (k: code) :=
  if Archi.ptr64 then
    match make_immed64 (Ptrofs.to_int64 ofs) with
    | Imm64_single imm =>
        mk_instr base (Ofsimm (Ptrofs.of_int64 imm)) :: k
    | Imm64_pair hi lo =>
        Plu12id R20 hi :: Paddd R20 base R20 :: mk_instr R20 (Ofsimm (Ptrofs.of_int64 lo)) :: k
    | Imm64_large imm =>
        Ploadli R20 imm :: Paddd R20 base R20 :: mk_instr R20 (Ofsimm Ptrofs.zero) :: k
    end
  else
    match make_immed32 (Ptrofs.to_int ofs) with
    | Imm32_single imm =>
        mk_instr base (Ofsimm (Ptrofs.of_int imm)) :: k
    | Imm32_pair hi lo =>
        Plu12iw R20 hi :: Paddw R20 base R20 :: mk_instr R20 (Ofsimm (Ptrofs.of_int lo)) :: k
    end.

Definition loadind (base: ireg) (ofs: ptrofs) (ty: typ) (dst: mreg) (k: code) :=
  match ty, preg_of dst with
  | Tint,    IR rd => OK (indexed_memory_access (Pldw rd) base ofs k)
  | Tlong,   IR rd => OK (indexed_memory_access (Pldd rd) base ofs k)
  | Tsingle, FR rd => OK (indexed_memory_access (Pflds rd) base ofs k)
  | Tfloat,  FR rd => OK (indexed_memory_access (Pfldd rd) base ofs k)
  | Tany32,  IR rd => OK (indexed_memory_access (Pldw_a rd) base ofs k)
  | Tany64,  IR rd => OK (indexed_memory_access (Pldd_a rd) base ofs k)
  | Tany64,  FR rd => OK (indexed_memory_access (Pfldd_a rd) base ofs k)
  | _, _           => Error (msg "Asmgen.loadind")
  end.

Definition storeind (src: mreg) (base: ireg) (ofs: ptrofs) (ty: typ) (k: code) :=
  match ty, preg_of src with
  | Tint,    IR rd => OK (indexed_memory_access (Pstw rd) base ofs k)
  | Tlong,   IR rd => OK (indexed_memory_access (Pstd rd) base ofs k)
  | Tsingle, FR rd => OK (indexed_memory_access (Pfsts rd) base ofs k)
  | Tfloat,  FR rd => OK (indexed_memory_access (Pfstd rd) base ofs k)
  | Tany32,  IR rd => OK (indexed_memory_access (Pstw_a rd) base ofs k)
  | Tany64,  IR rd => OK (indexed_memory_access (Pstd_a rd) base ofs k)
  | Tany64,  FR rd => OK (indexed_memory_access (Pfstd_a rd) base ofs k)
  | _, _           => Error (msg "Asmgen.storeind")
  end.

Definition loadind_ptr (base: ireg) (ofs: ptrofs) (dst: ireg) (k: code) :=
  indexed_memory_access (if Archi.ptr64 then Pldd dst else Pldw dst) base ofs k.

Definition storeind_ptr (src: ireg) (base: ireg) (ofs: ptrofs) (k: code) :=
  indexed_memory_access (if Archi.ptr64 then Pstd src else Pstw src) base ofs k.

(** Translation of memory accesses: loads, and stores. *)

Definition transl_memory_access
     (mk_instr: ireg -> offset -> instruction)
     (addr: addressing) (args: list mreg) (k: code) :=
  match addr, args with
  | Aindexed ofs, a1 :: nil =>
      do rs <- ireg_of a1;
      OK (indexed_memory_access mk_instr rs ofs k)
  | Aglobal id ofs, nil =>
      if Archi.ptr64 then
        match make_immed64 (Ptrofs.to_int64 ofs) with
        | Imm64_single imm => OK (Ploadsymbol R20 id :: mk_instr R20 (Ofsimm ofs) :: k)
        | Imm64_pair hi lo => OK (Ploadsymbol R20 id :: Plu12id R22 hi :: Paddd R20 R20 R22 ::
                                    mk_instr R20 (Ofsimm (Ptrofs.of_int64 lo)) :: k)
        | Imm64_large imm => OK (Ploadsymbol R20 id :: mk_instr R20 (Ofsimm ofs) :: k)
        end
      else
        match make_immed32 (Ptrofs.to_int ofs) with
        | Imm32_single imm => OK (Ploadsymbol R20 id :: mk_instr R20 (Ofsimm ofs) :: k)
        | Imm32_pair hi lo => OK (Ploadsymbol R20 id :: Plu12iw R22 hi :: Paddw R20 R20 R22 ::
                                    mk_instr R20 (Ofsimm (Ptrofs.of_int lo)) :: k)
        end
  | Ainstack ofs, nil =>
      OK (indexed_memory_access mk_instr SP ofs k)
  | _, _ =>
      Error(msg "Asmgen.transl_memory_access")
  end.

Definition transl_load (chunk: memory_chunk) (addr: addressing)
           (args: list mreg) (dst: mreg) (k: code) :=
  match chunk with
  | Mint8signed =>
      do r <- ireg_of dst;
      transl_memory_access (Pldb r)  addr args k
  | Mint8unsigned =>
      do r <- ireg_of dst;
      transl_memory_access (Pldbu r) addr args k
  | Mint16signed =>
      do r <- ireg_of dst;
      transl_memory_access (Pldh r)  addr args k
  | Mint16unsigned =>
      do r <- ireg_of dst;
      transl_memory_access (Pldhu r) addr args k
  | Mint32 =>
      do r <- ireg_of dst;
      transl_memory_access (Pldw r)  addr args k
  | Mint64 =>
      do r <- ireg_of dst;
      transl_memory_access (Pldd r)  addr args k
  | Mfloat32 =>
      do r <- freg_of dst;
      transl_memory_access (Pflds r) addr args k
  | Mfloat64 =>
      do r <- freg_of dst;
      transl_memory_access (Pfldd r) addr args k
  | _ =>
      Error (msg "Asmgen.transl_load")
  end.

Definition transl_store (chunk: memory_chunk) (addr: addressing)
           (args: list mreg) (src: mreg) (k: code) :=
  match chunk with
  | Mint8signed | Mint8unsigned =>
      do r <- ireg_of src;
      transl_memory_access (Pstb r)  addr args k
  | Mint16signed | Mint16unsigned =>
      do r <- ireg_of src;
      transl_memory_access (Psth r)  addr args k
  | Mint32 =>
      do r <- ireg_of src;
      transl_memory_access (Pstw r)  addr args k
  | Mint64 =>
      do r <- ireg_of src;
      transl_memory_access (Pstd r)  addr args k
  | Mfloat32 =>
      do r <- freg_of src;
      transl_memory_access (Pfsts r) addr args k
  | Mfloat64 =>
      do r <- freg_of src;
      transl_memory_access (Pfstd r) addr args k
  | _ =>
      Error (msg "Asmgen.transl_store")
  end.

(** Function epilogue *)

Definition make_epilogue (f: Mach.function) (k: code) :=
  loadind_ptr SP f.(fn_retaddr_ofs) RA
    (Pfreeframe f.(fn_stacksize) f.(fn_link_ofs) :: k).

(** Translation of a Mach instruction. *)

Definition transl_instr (f: Mach.function) (i: Mach.instruction)
                        (ep: bool) (k: code) :=
  match i with
  | Mgetstack ofs ty dst =>
      loadind SP ofs ty dst k
  | Msetstack src ofs ty =>
      storeind src SP ofs ty k
  | Mgetparam ofs ty dst =>
      (* load via the frame pointer if it is valid *)
      do c <- loadind R19 ofs ty dst k;
      OK (if ep then c
                else loadind_ptr SP f.(fn_link_ofs) R19 c)
  | Mop op args res =>
      transl_op op args res k
  | Mload chunk addr args dst =>
      transl_load chunk addr args dst k
  | Mstore chunk addr args src =>
      transl_store chunk addr args src k
  | Mcall sig (inl r) =>
      do r1 <- ireg_of r; OK (Pjal_r r1 sig :: k)
  | Mcall sig (inr symb) =>
      OK (Pjal_s symb sig :: k)
  | Mtailcall sig (inl r) =>
      do r1 <- ireg_of r;
      OK (make_epilogue f (Pj_r r1 sig :: k))
  | Mtailcall sig (inr symb) =>
      OK (make_epilogue f (Pj_s symb sig :: k))
  | Mbuiltin ef args res =>
      OK (Pbuiltin ef (List.map (map_builtin_arg preg_of) args) (map_builtin_res preg_of res) :: k)
  | Mlabel lbl =>
      OK (Plabel lbl :: k)
  | Mgoto lbl =>
      OK (Pj_l lbl :: k)
  | Mcond cond args lbl =>
      transl_cbranch cond args lbl k
  | Mjumptable arg tbl =>
      do r <- ireg_of arg;
      OK (Pbtbl r tbl :: k)
  | Mreturn =>
      OK (make_epilogue f (Pj_r RA f.(Mach.fn_sig) :: k))
  end.

(** Translation of a code sequence *)

Definition it1_is_parent (before: bool) (i: Mach.instruction) : bool :=
  match i with
  | Msetstack src ofs ty => before
  | Mgetparam ofs ty dst => negb (mreg_eq dst Machregs.R19)
  | Mop op args res => before && negb (mreg_eq res Machregs.R19)
  | _ => false
  end.

(** This is the naive definition that we no longer use because it
  is not tail-recursive.  It is kept as specification. *)

Fixpoint transl_code (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  match il with
  | nil => OK nil
  | i1 :: il' =>
      do k <- transl_code f il' (it1_is_parent it1p i1);
      transl_instr f i1 it1p k
  end.

(** This is an equivalent definition in continuation-passing style
  that runs in constant stack space. *)

Fixpoint transl_code_rec (f: Mach.function) (il: list Mach.instruction)
                         (it1p: bool) (k: code -> res code) :=
  match il with
  | nil => k nil
  | i1 :: il' =>
      transl_code_rec f il' (it1_is_parent it1p i1)
        (fun c1 => do c2 <- transl_instr f i1 it1p c1; k c2)
  end.

Definition transl_code' (f: Mach.function) (il: list Mach.instruction) (it1p: bool) :=
  transl_code_rec f il it1p (fun c => OK c).

(** Translation of a whole function.  Note that we must check
  that the generated code contains less than [2^32] instructions,
  otherwise the offset part of the [PC] code pointer could wrap
  around, leading to incorrect executions. *)

Definition transl_function (f: Mach.function) :=
  do c <- transl_code' f f.(Mach.fn_code) true;
  OK (mkfunction f.(Mach.fn_sig)
        (Pallocframe f.(fn_stacksize) f.(fn_link_ofs) ::
         storeind_ptr RA SP f.(fn_retaddr_ofs) c)).

Definition transf_function (f: Mach.function) : res Asm.function :=
  do tf <- transl_function f;
  if zlt Ptrofs.max_unsigned (list_length_z tf.(fn_code))
  then Error (msg "code size exceeded")
  else OK tf.

Definition transf_fundef (f: Mach.fundef) : res Asm.fundef :=
  transf_partial_fundef transf_function f.

Definition transf_program (p: Mach.program) : res Asm.program :=
  transform_partial_program transf_fundef p.