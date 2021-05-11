------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2021, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Characters.Handling; use Ada.Characters.Handling;

with Output; use Output;
with Table;

with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Aggregates;   use CCG.Aggregates;
with CCG.Blocks;       use CCG.Blocks;
with CCG.Instructions; use CCG.Instructions;
with CCG.Output;       use CCG.Output;
with CCG.Subprograms;  use CCG.Subprograms;
with CCG.Tables;       use CCG.Tables;
with CCG.Utils;        use CCG.Utils;

package body CCG.Builtins is

   function Matches
     (S, Name : String; Exact : Boolean := False) return Boolean
   is
     (S'Length >= Name'Length + 5
        and then (not Exact or else S'Length = Name'Length + 5)
        and then S (S'First + 5 .. S'First + Name'Length + 4) = Name);
   --  True iff the string Name is present starting at position 5 of S
   --  (after "llvm."). If Exact is true, there must be nothing following
   --  Name in S.

   type Arithmetic_Operation is (Add, Subtract);
   --  For now only support Add/Sub for overflow builtin

   procedure Op_With_Overflow
     (V    : Value_T;
      Ops  : Value_Array;
      S    : String;
      Arit : Arithmetic_Operation)
     with Pre => Present (V);
   --  Handle an arithmetic operation with overflow

   Overflow_Declared : array (Arithmetic_Operation) of Boolean :=
     (others => False);

   procedure Process_Memory_Operation
     (V : Value_T; Ops : Value_Array; S : String)
     with Pre => Present (V);
   --  Process memcpy, memmove, and memset

   ----------------------
   -- Op_With_Overflow --
   ----------------------

   procedure Op_With_Overflow
     (V    : Value_T;
      Ops  : Value_Array;
      S    : String;
      Arit : Arithmetic_Operation)
   is
      Op1    : constant Value_T  := Ops (Ops'First);
      Op2    : constant Value_T  := Ops (Ops'First + 1);
      Subp : constant String :=
        "system__arith_64__" & To_Lower (Arit'Image) & "_with_ovflo_check64";
      Bits : constant unsigned := unsigned'Value (S (S'First + 25 .. S'Last));

   begin
      Maybe_Decl (V);

      if not Overflow_Declared (Arit) then
         Write_Str ("extern long long " & Subp & " (long long, long long);");
         Write_Eol;
         Overflow_Declared (Arit) := True;
      end if;

      --  Overflow builtins are only generated by the LLVM optimizer (see
      --  lib/Transforms/InstCombineCompares.cpp), but we still want to
      --  handle them by calling the routines in System.Arith_64 even if
      --  this is clearly inefficient.
      --  The LLVM builtin deals with a struct containing two fields: the
      --  first is the integer result, the second is the overflow bit.  If
      --  the Arith_64 routine succeeds (does not raise an exception), it
      --  means that no overflow occurred so always clear the second field.
      --  ??? The front end is able to convert some overflow operations to
      --  direct comparison. We ought to do the same here. And if we do
      --  that, then we can emit the builtins in all cases and allow the
      --  LLVM optimizer to see the builtins, which should allow it to do a
      --  better job. But this is for later work; we need to get a better
      --  idea of the tradeoffs here.

      Write_Copy (+V & ".ccg_field_0",
                  "(" & Int_String (Pos (Bits)) & ") " & Subp &
                    " ((long long) " & Op1 & ", (long long) " & Op2 & ")",
                  Int_Type (Bits));
      Write_Copy (+V & ".ccg_field_1", +"0", Int_Type (1));

   end Op_With_Overflow;

   ------------------------------
   -- Process_Memory_Operation --
   ------------------------------

   procedure Process_Memory_Operation
     (V : Value_T; Ops : Value_Array; S : String)
   is
      Op1    : constant Value_T  := Ops (Ops'First);
      Op2    : constant Value_T  := Ops (Ops'First + 1);
      Op3    : constant Value_T  := Ops (Ops'First + 2);
      Result : Str;

   begin
      Result := S & " (" & Op1 & ", " & Op2 & ", " & Op3 & ")";
      Process_Pending_Values;
      Output_Stmt (Result);
   end Process_Memory_Operation;

   ------------------
   -- Call_Builtin --
   ------------------

   function Call_Builtin
     (V : Value_T; S : String; Ops : Value_Array) return Boolean
   is
   begin
      --  We ignore lifetime start/end calls

      if Matches (S, "lifetime")

      --  Also ignore stackrestore/stacksave calls: these are generated by
      --  the optimizer and in many cases the stack usage is actually zero
      --  or very low.
      --  ??? Not clear that we can do better for now.

        or else Matches (S, "stackrestore", True)
        or else Matches (S, "stacksave", True)
      then
         null;

      --  Handle some overflow intrinsics

      elsif Matches (S, "sadd.with.overflow") then
         Op_With_Overflow (V, Ops, S, Add);

      elsif Matches (S, "ssub.with.overflow") then
         Op_With_Overflow (V, Ops, S, Subtract);

      --  We process memcpy, memmove, and memset by calling the corresponding
      --  C library function.

      elsif Matches (S, "memcpy") then
         Process_Memory_Operation (V, Ops, "memcpy");
      elsif Matches (S, "memmove") then
         Process_Memory_Operation (V, Ops, "memmove");
      elsif Matches (S, "memset") then
         Process_Memory_Operation (V, Ops, "memset");

      --  And we don't process the rest

      else
         return False;
      end if;

      return True;
   end Call_Builtin;

end CCG.Builtins;
