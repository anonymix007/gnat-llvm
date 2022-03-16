------------------------------------------------------------------------------
--                              C C G                                       --
--                                                                          --
--                     Copyright (C) 2020-2022, AdaCore                     --
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

with Interfaces.C;

with LLVM.Types; use LLVM.Types;

with Einfo;          use Einfo;
with Einfo.Entities; use Einfo.Entities;
with Einfo.Utils;    use Einfo.Utils;
with Namet;          use Namet;
with Types;          use Types;

with GNATLLVM; use GNATLLVM;

package CCG is

   subtype unsigned is Interfaces.C.unsigned;

   --  This package and its children generate C code from the LLVM IR
   --  generated by GNAT LLLVM.

   Typedef_Idx_Low_Bound      : constant := 100_000_000;
   Typedef_Idx_High_Bound     : constant := 199_999_999;
   type Typedef_Idx is
     range Typedef_Idx_Low_Bound .. Typedef_Idx_High_Bound;
   Typedef_Idx_Start          : constant Typedef_Idx     :=
     Typedef_Idx_Low_Bound + 1;

   Global_Decl_Idx_Low_Bound  : constant := 200_000_000;
   Global_Decl_Idx_High_Bound : constant := 299_999_999;
   type Global_Decl_Idx is
     range Global_Decl_Idx_Low_Bound .. Global_Decl_Idx_High_Bound;
   Global_Decl_Idx_Start      : constant Global_Decl_Idx :=
     Global_Decl_Idx_Low_Bound + 1;

   Local_Decl_Idx_Low_Bound   : constant := 300_000_000;
   Local_Decl_Idx_High_Bound  : constant := 399_999_999;
   type Local_Decl_Idx is
     range Local_Decl_Idx_Low_Bound .. Local_Decl_Idx_High_Bound;
   Empty_Local_Decl_Idx       : constant Local_Decl_Idx  :=
     Local_Decl_Idx_Low_Bound;

   Stmt_Idx_Low_Bound         : constant := 400_000_000;
   Stmt_Idx_High_Bound        : constant := 499_999_999;
   type Stmt_Idx is range Stmt_Idx_Low_Bound .. Stmt_Idx_High_Bound;
   Empty_Stmt_Idx             : constant Stmt_Idx        :=
     Stmt_Idx_Low_Bound;

   Flow_Idx_Low_Bound         : constant := 500_000_000;
   Flow_Idx_High_Bound        : constant := 599_999_999;
   type Flow_Idx is range Flow_Idx_Low_Bound .. Flow_Idx_High_Bound;
   Empty_Flow_Idx             : constant Flow_Idx := Flow_Idx_Low_Bound;

   --  Line_Idx is 6xx_xxx_xxx, Case_Idx is 7xx_xxx_xxx, and If_Idx is
   --  8xx_xxx_xxx (in ccg-flow.ads). Subprogram_Idx (in ccg-subprograms.adb)
   --  is 9xx_xxx_xxx.

   --  We output any typedefs at the time we decide that we need it and
   --  also output decls for any global variables at a similar time.
   --  However, we keep lists of subprograms and decls and statements for
   --  each and only write those after we've finished processing the module
   --  so that all typedefs and globals are written first.  These
   --  procedures manage those lists.

   function Present (Idx : Local_Decl_Idx)  return Boolean is
     (Idx /= Empty_Local_Decl_Idx);
   function Present (Idx : Stmt_Idx)        return Boolean is
     (Idx /= Empty_Stmt_Idx);
   function Present (Idx : Flow_Idx)        return Boolean is
    (Idx /= Empty_Flow_Idx);

   function No (Idx : Local_Decl_Idx)       return Boolean is
     (Idx = Empty_Local_Decl_Idx);
   function No (Idx : Stmt_Idx)             return Boolean is
     (Idx = Empty_Stmt_Idx);
   function No (Idx : Flow_Idx)             return Boolean is
     (Idx = Empty_Flow_Idx);

   procedure Initialize_C_Output;
   --  Do any initialization needed to output C.  This is always called after
   --  we've obtained target parameters.

   procedure Write_C_Code (Module : Module_T);
   --  The main procedure, which generates C code from the LLVM IR

   procedure C_Set_Field_Info
     (SID         : Struct_Id;
      Idx         : Nat;
      Name        : Name_Id          := No_Name;
      TE          : Opt_Type_Kind_Id := Empty;
      Is_Padding  : Boolean          := False;
      Is_Bitfield : Boolean          := False);
   --  Say what field Idx in the struct temporarily denoted by SID is used for

   procedure C_Set_Struct (SID : Struct_Id; T : Type_T)
     with Pre => Present (T), Inline;
   --  Indicate that the previous calls to Set_Field_Name_Info for SID
   --  were for LLVM struct type T.

   procedure C_Set_GNAT_Type  (V : Value_T; TE : Type_Kind_Id)
     with Pre => Present (V), Inline;
   --  Indicate that TE is the type of V

   procedure C_Set_Is_Variable (V : Value_T)
     with Pre => Present (V), Inline;
   --  Indicate that V is variable found in the source

   procedure Error_Msg (Msg : String);
   --  Post an error message via the GNAT errout mechanism.
   --  ??? For now, default to the First_Source_Ptr sloc. Will hopefully use a
   --  better source location in the future when we keep track of them for e.g.
   --  generating #line information.

   procedure Discard (B : Boolean) is null;
   --  Used to discard Boolean function results

   --  Define the sizes of all the basic C types.

   Char_Size      : Pos;
   Short_Size     : Pos;
   Int_Size       : Pos;
   Long_Size      : Pos;
   Long_Long_Size : Pos;

   Emit_C_Line    : Boolean := False;
   --  When generating C code, indicates that we want to generate #line
   --  directives. This corresponds to -g.

end CCG;
