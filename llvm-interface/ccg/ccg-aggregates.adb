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

with Ada.Containers; use Ada.Containers;
with Ada.Containers.Hashed_Maps;

with Atree;  use Atree;
with Output; use Output;
with Table;

with GNATLLVM.Types;   use GNATLLVM.Types;
with GNATLLVM.Utils;   use GNATLLVM.Utils;
with GNATLLVM.Wrapper; use GNATLLVM.Wrapper;

with CCG.Environment;  use CCG.Environment;
with CCG.Instructions; use CCG.Instructions;
with CCG.Output;       use CCG.Output;
with CCG.Target;       use CCG.Target;
with CCG.Utils;        use CCG.Utils;

package body CCG.Aggregates is

   --  This package contains routines used to process aggregate data,
   --  which are arrays and structs.

   --  We want to record information about each field in an LLVM struct
   --  type corresponding to an Ada record or part thereof so we can use
   --  those names in the generated code. The following record is used
   --  to store information about fields.

   type Field_C_Info_Idx is new Nat;
   No_Field_C_Info_Idx : constant Field_C_Info_Idx := 0;

   function Present (F : Field_C_Info_Idx) return Boolean is
     (F /= No_Field_C_Info_Idx);

   type Field_C_Data is record
      T           : Type_T;
      --  LLVM "struct" type containing this field

      F_Number    : Nat;
      --  0-origin count of field in type

      Name        : Name_Id;
      --  If Present, the name of the field

      Entity      : Entity_Id;
      --  If Present, the GNAT entity for the field

      SID         : Struct_Id;
      --  The Struct_Id for the field; used only when initializing field info

      Next        : Field_C_Info_Idx;
      --  Index of next field entry for this type

      Is_Padding  : Boolean;
      --  True if this field is padding and doesn't correspond to any
      --  source-level field.

      Is_Bitfield : Boolean;
      --  True if this is a field that's used to store one or more bitfields

   end record;

   --  Define the table that records all of the field name info

   package Field_C_Info is new Table.Table
     (Table_Component_Type => Field_C_Data,
      Table_Index_Type     => Field_C_Info_Idx,
      Table_Low_Bound      => 1,
      Table_Initial        => 500,
      Table_Increment      => 100,
      Table_Name           => "Field_C_Info");

   --  We need two maps into the above table. One maps a Struct_Id into
   --  a table entry. This is used to track the initial setting of field info
   --  and is used when we set the struct type.  The second maps a
   --  (struct type, field index) pair into the name info for that field.

   function Hash (SID : Struct_Id) return Hash_Type is (Hash_Type (SID));

   package Entity_To_FCI_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => Struct_Id,
      Element_Type    => Field_C_Info_Idx,
      Hash            => Hash,
      Equivalent_Keys => "=");
   Entity_To_FCI_Map : Entity_To_FCI_Maps.Map;

   type FC_Key is record
      T   : Type_T;
      Idx : Nat;
   end record;

   function Hash (K : FC_Key) return Hash_Type is
     (Hash (K.T) + Hash_Type (K.Idx));

   package FCI_Maps is new Ada.Containers.Hashed_Maps
     (Key_Type        => FC_Key,
      Element_Type    => Field_C_Info_Idx,
      Hash            => Hash,
      Equivalent_Keys => "=");
   FCI_Map : FCI_Maps.Map;

   function Value_Piece (V : Value_T; T : in out Type_T; Idx : Nat) return Str
     with Pre  => Get_Opcode (V) in Op_Extract_Value | Op_Insert_Value
                  and then Is_Aggregate_Type (T),
          Post => Present (Value_Piece'Result) and then T /= T'Old;
   --  T is the type of a component of the aggregate in an extractvalue or
   --  insertvalue instruction V. Return an Str saying how to access that
   --  component and update T to be the type of that component.

   function Get_Field_Name (T : Type_T; Idx : Nat) return Str
     with Pre  => Get_Type_Kind (T) = Struct_Type_Kind,
          Post => Present (Get_Field_Name'Result);
   --  Return a name to use for field Idx of LLVM struct T

   ----------------------
   -- Set_Field_C_Info --
   ----------------------

   procedure Set_Field_C_Info
     (SID         : Struct_Id;
      Idx         : Nat;
      Name        : Name_Id   := No_Name;
      Entity      : Entity_Id := Empty;
      Is_Padding  : Boolean   := False;
      Is_Bitfield : Boolean   := False)
   is
      use Entity_To_FCI_Maps;
      Position : constant Cursor           := Find (Entity_To_FCI_Map, SID);
      F_Idx    : constant Field_C_Info_Idx :=
        (if   Has_Element (Position) then Element (Position)
         else No_Field_C_Info_Idx);

   begin
      --  Start by adding an entry to our table. Then either update the
      --  head of the chain or set a new head.

      Field_C_Info.Append ((T           => No_Type_T,
                            F_Number    => Idx,
                            Name        => Name,
                            Entity      => Entity,
                            SID         => SID,
                            Next        => F_Idx,
                            Is_Padding  => Is_Padding,
                            Is_Bitfield => Is_Bitfield));
      if Has_Element (Position) then
         Replace_Element (Entity_To_FCI_Map, Position,
                          Field_C_Info.Last);
      else
         Insert (Entity_To_FCI_Map, SID, Field_C_Info.Last);
      end if;

   end Set_Field_C_Info;

   ----------------
   -- Set_Struct --
   ----------------

   procedure Set_Struct (SID : Struct_Id; T : Type_T) is
      package EFM renames Entity_To_FCI_Maps;
      package TFM renames FCI_Maps;
      Position : constant EFM.Cursor := EFM.Find (Entity_To_FCI_Map, SID);
      F_Idx    : Field_C_Info_Idx;

   begin
      --  If we didn't make any entry in the Field Name Info table for
      --  this type, we don't have anything to do. This could have happened
      --  either if we weren't generating C or if SID denotes a null record.

      if not EFM.Has_Element (Position) then
         return;
      end if;

      --  Otherwise get the first entry we made and loop over all
      --  Field_Name_Info entries for SID, looking for entries where the
      --  LLVM type hasn't yet been set. For each, set the type and add the
      --  (LLVM type, field index) pair to the hash table, but if the type has
      --  no name, don't insert it into the table since it'll be a shared
      --  struct.

      F_Idx := EFM.Element (Position);
      while Present (F_Idx) loop
         declare
            FCI : Field_C_Data renames Field_C_Info.Table (F_Idx);
         begin
            if No (FCI.T) then
               FCI.T := T;

               if Has_Name (T) then
                  TFM.Insert (FCI_Map, (T, FCI.F_Number), F_Idx);
               end if;
            end if;

            F_Idx := FCI.Next;
         end;
      end loop;
   end Set_Struct;

   --------------------
   -- Get_Field_Name --
   --------------------

   function Get_Field_Name (T : Type_T; Idx : Nat) return Str is
      use FCI_Maps;
      Position : constant Cursor := Find (FCI_Map, (T, Idx));
      FCI      : Field_C_Data    :=
        (T, Idx, No_Name, Types.Empty, No_Struct_Id, No_Field_C_Info_Idx,
         False, False);

   begin
      --  If we have information for this field in our table (we should),
      --  replace the default above with that information.

      if Has_Element (Position) then
         FCI := Field_C_Info.Table (Element (Position));
      end if;

      --  Now create a name for the field, based on the saved information.
      --  We really shouldn't be requesting a padding field, but handle it
      --  anyway.

      if Present (FCI.Name) then
         return Get_Name_String (FCI.Name) + Name;
      elsif Present (FCI.Entity) then
         return Get_Ext_Name (FCI.Entity) + Name;
      elsif FCI.Is_Padding then
         return "ccg_pad_" & Idx;
      elsif FCI.Is_Bitfield then
         return "ccg_bits_" & Idx;
      else
         return "ccg_field_" & Idx;
      end if;
   end Get_Field_Name;

   ----------------------
   -- Get_Field_Entity --
   ----------------------

   function Get_Field_Entity (T : Type_T; Idx : Nat) return Entity_Id is
      use FCI_Maps;
      Position : constant Cursor := Find (FCI_Map, (T, Idx));

   begin
      return (if   Has_Element (Position)
              then Field_C_Info.Table (Element (Position)).Entity
              else Types.Empty);
   end Get_Field_Entity;

   ---------------------------
   -- Output_Struct_Typedef --
   ---------------------------

   procedure Output_Struct_Typedef (T : Type_T; Incomplete : Boolean := False)
   is
      Types : constant Nat := Count_Struct_Element_Types (T);

   begin
      --  Because this struct may contain a pointer to itself, we always have
      --  to write an incomplete struct. So we write, e.g.,
      --
      --       typedef struct foo foo;
      --       struct foo { ... full definition ..}

      if not Get_Is_Incomplete_Output (T) then
         Output_Decl ("typedef struct " & T & " " & T, Is_Typedef => True);
         Set_Is_Incomplete_Output (T);
      end if;

      --  If all we're to do is to output the incomplete definition,
      --  we're done.

      if Incomplete then
         return;
      end if;

      --  Before we output the typedef for this struct, make sure we've
      --  output any inner typedefs.

      for J in 0 .. Types - 1 loop
         Maybe_Output_Typedef (Struct_Get_Type_At_Index (T, J));
      end loop;

      --  Now that we know that all inner typedefs have been output,
      --  we output the struct definition.

      Output_Decl ("struct " & T, Semicolon => False, Is_Typedef => True);
      Start_Output_Block (Decl);
      for J in 0 .. Types - 1 loop

         declare
            ST : constant Type_T := Struct_Get_Type_At_Index (T, J);

         begin
            --  If the type of a field is a zero-length array, this can
            --  indicate either a variable-sized array (usually for the last
            --  field) or an instance of a variable-sized array where the
            --  size is zero.  In either case, if we write it as an array of
            --  length one, the size of the struct will be different than
            --  expected, but not all versions of C support 0-sized arrays.
            --  ??? We may want to adjust what we do here as we add
            --  functionality to support various different C compiler
            --  options.

            if not Is_Zero_Length_Array (ST) then
               declare
                  Name           : constant Str              :=
                    Get_Field_Name (T, J);
                  F              : constant Entity_Id        :=
                    Get_Field_Entity (T, J);
                  Maybe_Unsigned : constant Str              :=
                    +(if   Present (F)
                           and then Is_Unsigned_Type (Full_Etype (F))
                      then "unsigned " else "");

               begin
                  Output_Decl (Maybe_Unsigned & ST & " " & Name,
                               Is_Typedef => True);
               end;
            end if;
         end;
      end loop;

      --  If this is an empty struct, we need to add a dummy field since
      --  ISO C89 doesn't allow an empty struct.

      if Types = 0 then
         Output_Decl ("char dummy_for_null_recordC", Is_Typedef => True);
      end if;

      --  ??? We have many ways of handling packed, but don't worry about that
      --  in the initial support.

      Output_Decl ("}" &
                     (if    Is_Packed_Struct (T)
                      then " __attribute__ ((packed))" else ""),
                   Is_Typedef => True, End_Block => Decl);
   end Output_Struct_Typedef;

   -------------------------
   -- Write_Array_Typedef --
   -------------------------

   procedure Output_Array_Typedef (T : Type_T) is
      Elem_T : constant Type_T := Get_Element_Type (T);

   begin
      Maybe_Output_Typedef (Elem_T);
      Output_Decl ("typedef " & Elem_T & " " & T & "[" &
                   Effective_Array_Length (T) & "]", Is_Typedef => True);
   end Output_Array_Typedef;

   ---------------------------------------
   -- Maybe_Output_Array_Return_Typedef --
   ---------------------------------------

   procedure Maybe_Output_Array_Return_Typedef (T : Type_T) is
   begin
      --  If we haven't written this yet, first ensure that we've written
      --  the typedef for T since we reference it, then write the actual
      --  typedef, and mark it as written.

      if not Get_Is_Return_Typedef_Output (T) then
         Maybe_Output_Typedef (T);
         Output_Decl ("typedef struct " & T & "_R {" & T & " F;} " & T & "_R",
                      Is_Typedef => True);
         Set_Is_Return_Typedef_Output (T);
      end if;
   end Maybe_Output_Array_Return_Typedef;

   -----------------
   -- Value_Piece --
   -----------------

   function Value_Piece
     (V : Value_T; T : in out Type_T; Idx : Nat) return Str is
   begin
      return Result : Str do
         declare
            Ins_Idx : constant Nat := Get_Index (V, Idx);
         begin
            --  We know this is either a struct or an array

            if Get_Type_Kind (T) = Struct_Type_Kind then
               Result := "." & Get_Field_Name (T, Ins_Idx) + Component;
               T      := Struct_Get_Type_At_Index (T, Ins_Idx);
            else
               Result := " [" & Ins_Idx & "]" + Component;
               T      := Get_Element_Type (T);
            end if;
         end;
      end return;
   end Value_Piece;

   -------------------------------
   -- Extract_Value_Instruction --
   -------------------------------

   function Extract_Value_Instruction (V : Value_T; Op : Value_T) return Str is
      Idxs : constant Nat := Get_Num_Indices (V);
      T    : Type_T       := Type_Of (Op);
   begin
      return Result : Str := Op + Component do

         --  We process each index in turn, stripping off the reference.

         for J in 0 .. Idxs - 1 loop
            Result := Result & Value_Piece (V, T, J);
         end loop;
      end return;
   end Extract_Value_Instruction;

   ------------------------------
   -- Insert_Value_Instruction --
   ------------------------------

   procedure Insert_Value_Instruction (V, Aggr, Op : Value_T) is
      Idxs : constant Nat := Get_Num_Indices (V);
      T    : Type_T       := Type_Of (Aggr);
      Acc  : Str          := +V;

   begin
      --  If Aggr is undef, we don't need to do any copy. Otherwise, we
      --  first copy it to the result variable.

      Maybe_Decl (V);
      if Is_Undef (Aggr) then
         null;
      else
         Write_Copy (V, +Aggr, T);
      end if;

      --  Next we generate the string that represents the access of this
      --  instruction.

      for J in 0 .. Idxs - 1 loop
         Acc := Acc & Value_Piece (V, T, J);
      end loop;

      --  The resulting type must be that of Op and we emit the assignment

      pragma Assert (T = Type_Of (Op));
      Write_Copy (Acc, Op + Assign, T, V);
   end Insert_Value_Instruction;

   ---------------------
   -- GEP_Instruction --
   ---------------------

   procedure GEP_Instruction (V : Value_T; Ops : Value_Array) is
      Aggr   : constant Value_T := Ops (Ops'First);
      --  The pointer to aggregate that we're dereferencing

      Aggr_T : Type_T           := Get_Element_Type (Aggr);
      --  The type that Aggr, which is always a pointer, points to

      Is_LHS : Boolean          := Get_Is_LHS (Aggr);
      --  Whether our result so far is an LHS as opposed to a pointer.
      --  If it is, then we can use normal derefrence operations and we must
      --  take the address at the end of the instruction processing.

      Result : Str;
      --  The resulting operation so far

   begin
      --  The first operand is special in that it represents a value to be
      --  multiplied by the size of the type pointed to and added to the
      --  value of the pointer input. Normally, we have a GEP that either
      --  has a nonzero value for this operand and no others or that has a
      --  zero for this value, but those aren't requirements. However, it's
      --  very worth special-casing the zero case here because we have
      --  nothing to do in that case.

      if Is_A_Constant_Int (Ops (Ops'First + 1))
        and then Equals_Int (Ops (Ops'First + 1), 0)
      then
         Result := Aggr + LHS + Component;
      else
         Result := TP ("#1[#2]", Aggr, Ops (Ops'First + 1)) + Component;
         Is_LHS := True;
      end if;

      --  Now process any other operands, which must always dereference into
      --  an array or struct. When we make a component reference of an object,
      --  we must ensure that the actual type of the object, not just a pointer
      --  to that object, will have been fully defined and isn't an incomplete
      --  type.

      for Op of Ops (Ops'First + 2 .. Ops'Last) loop
         Maybe_Output_Typedef (Aggr_T);
         if Get_Type_Kind (Aggr_T) = Array_Type_Kind then

            --  If this isn't an LHS, we have to make it one, but not if
            --  this is a zero-size array, since we've written the pointer
            --  type as a pointer to the element.

            if not Is_LHS and then Get_Array_Length (Aggr_T) /= Nat (0) then
               Result := Deref (Result) + Component;
            end if;

            Result := Result & TP ("[#1]", Op) + Component;
            Aggr_T := Get_Element_Type (Aggr_T);
            Is_LHS := True;

         else
            pragma Assert (Get_Type_Kind (Aggr_T) = Struct_Type_Kind);

            declare
               Idx   : constant Nat    := Nat (Const_Int_Get_S_Ext_Value (Op));
               ST    : constant Type_T :=
                 Struct_Get_Type_At_Index (Aggr_T, Idx);
               Found : Boolean         := False;

            begin
               --  If this is a zero-length array, it doesn't actually
               --  exist, so convert this into a cast to char *, point past
               --  the end of a previous non-zero-length-array field (or at
               --  the start of the struct if none) and then cast to a
               --  pointer to the array's element type.

               if Is_Zero_Length_Array (ST) then
                  for Prev_Idx in reverse 0 .. Idx - 1 loop
                     declare
                        Prev_ST : constant Type_T :=
                          Struct_Get_Type_At_Index (Aggr_T, Prev_Idx);
                        Ref     : constant Str    :=
                          Result & (if Is_LHS then "." else "->") +
                            Component & Get_Field_Name (Aggr_T, Prev_Idx);

                     begin
                        --  If we found a previous non-zero-length array
                        --  field, point to the end of it.

                        if not Is_Zero_Length_Array (Prev_ST) then
                           Result := ("(char *) " & Addr_Of (Ref) &
                                        " + sizeof (" & Ref & ")");
                           Found  := True;
                           exit;
                        end if;
                     end;
                  end loop;

                  --  If we haven't found such a field, point to the beginning
                  --  of the object.

                  if not Found then
                     Result := "(char *) " &
                       (if Is_LHS then Addr_Of (Result) else Result);
                  end if;

                  --  Now cast to the desired type

                  Result :=
                    "((" & Get_Element_Type (ST) & " *) (" & Result & "))";
                  Is_LHS := False;

               --  Otherwise, just do a normal field reference

               else
                  Result :=
                    Result & (if Is_LHS then "." else "->") + Component &
                      Get_Field_Name (Aggr_T, Idx);
                  Is_LHS := True;
               end if;

               Aggr_T := ST;
            end;
         end if;
      end loop;

      --  If the input is a constant, mark the output as constant and
      --  as the value of V, mark as LHS if it is,a and we're done.

      if Get_Is_Constant (Aggr) then
         Set_Is_Constant (V);
         Set_Is_LHS (V, Is_LHS);
         Set_C_Value (V, Result);
         return;
      end if;

      --  If we ended up with a LHS, we set this as the value of V but mark
      --  it as an LHS. This is to avoid taking an address and then doing a
      --  dereference for nested GEP's.

      Set_Is_LHS (V, Is_LHS);
      if Is_LHS then
         Set_C_Value (V, Result);
      else
         Assignment (V, Result);
      end if;

   end GEP_Instruction;

end CCG.Aggregates;
